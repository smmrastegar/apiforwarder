using ApiForwarder.Models;
using Microsoft.Extensions.Primitives;
using Yarp.ReverseProxy.Configuration;

namespace ApiForwarder.Services;

/// <summary>
/// A hot-reloadable <see cref="IProxyConfigProvider"/>. The admin UI mutates
/// the <see cref="RouteStore"/>, which calls <see cref="Apply"/> to publish a
/// fresh YARP configuration without restarting the process.
/// </summary>
public class ProxyConfigProvider : IProxyConfigProvider
{
    // Public path prefixes that belong to this app and must never be proxied.
    private static readonly string[] ReservedPrefixes = { "/admin", "/assets", "/health" };

    private volatile InternalConfig _config = new(Array.Empty<RouteConfig>(), Array.Empty<ClusterConfig>());

    public IProxyConfig GetConfig() => _config;

    public void Apply(IReadOnlyList<RouteRule> rules)
    {
        var routes = new List<RouteConfig>();
        var clusters = new List<ClusterConfig>();

        foreach (var rule in rules)
        {
            if (!rule.Enabled) continue;
            if (string.IsNullOrWhiteSpace(rule.Destination)) continue;
            if (IsReserved(rule.PathPrefix)) continue;

            var clusterId = $"cluster_{rule.Id}";
            var routeId = $"route_{rule.Id}";

            clusters.Add(new ClusterConfig
            {
                ClusterId = clusterId,
                Destinations = new Dictionary<string, DestinationConfig>
                {
                    ["primary"] = new DestinationConfig { Address = rule.Destination }
                }
            });

            var matchPath = rule.PathPrefix == "/"
                ? "/{**catch-all}"
                : $"{rule.PathPrefix}/{{**catch-all}}";

            routes.Add(new RouteConfig
            {
                RouteId = routeId,
                ClusterId = clusterId,
                // Lower order = higher priority; longer prefixes win first.
                Order = -rule.PathPrefix.Length,
                Match = new RouteMatch
                {
                    Path = matchPath,
                    Methods = rule.Methods.Count > 0 ? rule.Methods : null
                },
                Transforms = BuildTransforms(rule)
            });
        }

        var old = _config;
        _config = new InternalConfig(routes, clusters);
        old.SignalChange();
    }

    private static IReadOnlyList<IReadOnlyDictionary<string, string>> BuildTransforms(RouteRule rule)
    {
        var transforms = new List<IReadOnlyDictionary<string, string>>();

        if (rule.StripPrefix && rule.PathPrefix != "/")
            transforms.Add(new Dictionary<string, string> { ["PathRemovePrefix"] = rule.PathPrefix });

        if (rule.HideOrigin)
        {
            // Do not append/forward any client identity to the upstream:
            // the upstream sees only this server's IP and a clean request.
            transforms.Add(new Dictionary<string, string> { ["X-Forwarded"] = "Remove" });
            transforms.Add(new Dictionary<string, string> { ["RequestHeader"] = "X-Real-IP", ["Set"] = "" });
            transforms.Add(new Dictionary<string, string> { ["RequestHeader"] = "Forwarded", ["Set"] = "" });
            transforms.Add(new Dictionary<string, string> { ["RequestHeader"] = "Via", ["Set"] = "" });
        }
        else
        {
            transforms.Add(new Dictionary<string, string> { ["X-Forwarded"] = "Set" });
        }

        // Host header sent to the upstream.
        transforms.Add(new Dictionary<string, string>
        {
            ["RequestHeaderOriginalHost"] = rule.UseDestinationHostHeader ? "false" : "true"
        });

        foreach (var kv in rule.AddRequestHeaders)
        {
            if (string.IsNullOrWhiteSpace(kv.Key)) continue;
            transforms.Add(new Dictionary<string, string>
            {
                ["RequestHeader"] = kv.Key,
                ["Set"] = kv.Value ?? string.Empty
            });
        }

        return transforms;
    }

    private static bool IsReserved(string prefix)
    {
        if (prefix == "/") return false; // root catch-all is allowed; reserved endpoints win by routing precedence
        return ReservedPrefixes.Any(r =>
            prefix.Equals(r, StringComparison.OrdinalIgnoreCase) ||
            prefix.StartsWith(r + "/", StringComparison.OrdinalIgnoreCase));
    }

    private sealed class InternalConfig : IProxyConfig
    {
        private readonly CancellationTokenSource _cts = new();

        public InternalConfig(IReadOnlyList<RouteConfig> routes, IReadOnlyList<ClusterConfig> clusters)
        {
            Routes = routes;
            Clusters = clusters;
            ChangeToken = new CancellationChangeToken(_cts.Token);
        }

        public IReadOnlyList<RouteConfig> Routes { get; }
        public IReadOnlyList<ClusterConfig> Clusters { get; }
        public IChangeToken ChangeToken { get; }

        public void SignalChange() => _cts.Cancel();
    }
}
