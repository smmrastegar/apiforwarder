using System.Text.Json;
using ApiForwarder.Models;

namespace ApiForwarder.Services;

/// <summary>
/// Persists forwarding rules to a JSON file under App_Data and keeps an
/// in-memory copy. Thread-safe for the simple read/write patterns used here.
/// On every change it rebuilds the live YARP configuration.
/// </summary>
public class RouteStore
{
    private readonly string _filePath;
    private readonly ProxyConfigProvider _configProvider;
    private readonly ILogger<RouteStore> _logger;
    private readonly object _gate = new();
    private readonly JsonSerializerOptions _json = new() { WriteIndented = true };

    private List<RouteRule> _rules = new();

    public RouteStore(IWebHostEnvironment env, ProxyConfigProvider configProvider, ILogger<RouteStore> logger)
    {
        _configProvider = configProvider;
        _logger = logger;

        var dataDir = Path.Combine(env.ContentRootPath, "App_Data");
        Directory.CreateDirectory(dataDir);
        _filePath = Path.Combine(dataDir, "routes.json");

        Load();
        Reconfigure();
    }

    public IReadOnlyList<RouteRule> GetAll()
    {
        lock (_gate)
        {
            return _rules.Select(Clone).ToList();
        }
    }

    public RouteRule? Get(string id)
    {
        lock (_gate)
        {
            var r = _rules.FirstOrDefault(x => x.Id == id);
            return r is null ? null : Clone(r);
        }
    }

    public RouteRule Add(RouteRule rule)
    {
        lock (_gate)
        {
            rule.Id = Guid.NewGuid().ToString("n");
            Normalize(rule);
            _rules.Add(rule);
            Save();
        }
        Reconfigure();
        return Clone(rule);
    }

    public bool Update(string id, RouteRule incoming)
    {
        lock (_gate)
        {
            var existing = _rules.FirstOrDefault(x => x.Id == id);
            if (existing is null) return false;

            incoming.Id = id;
            Normalize(incoming);
            var index = _rules.IndexOf(existing);
            _rules[index] = incoming;
            Save();
        }
        Reconfigure();
        return true;
    }

    public bool Delete(string id)
    {
        bool removed;
        lock (_gate)
        {
            removed = _rules.RemoveAll(x => x.Id == id) > 0;
            if (removed) Save();
        }
        if (removed) Reconfigure();
        return removed;
    }

    private void Load()
    {
        try
        {
            if (File.Exists(_filePath))
            {
                var json = File.ReadAllText(_filePath);
                _rules = JsonSerializer.Deserialize<List<RouteRule>>(json) ?? new();
            }
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to load routes from {File}; starting empty.", _filePath);
            _rules = new();
        }
    }

    private void Save()
    {
        try
        {
            var json = JsonSerializer.Serialize(_rules, _json);
            File.WriteAllText(_filePath, json);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to save routes to {File}.", _filePath);
        }
    }

    private void Reconfigure()
    {
        List<RouteRule> snapshot;
        lock (_gate)
        {
            snapshot = _rules.Select(Clone).ToList();
        }
        _configProvider.Apply(snapshot);
        _logger.LogInformation("Applied {Count} forwarding rule(s).", snapshot.Count);
    }

    private static void Normalize(RouteRule rule)
    {
        rule.PathPrefix = NormalizePrefix(rule.PathPrefix);
        rule.Destination = rule.Destination?.Trim().TrimEnd('/') ?? string.Empty;
        rule.Methods = rule.Methods?
            .Where(m => !string.IsNullOrWhiteSpace(m))
            .Select(m => m.Trim().ToUpperInvariant())
            .Distinct()
            .ToList() ?? new();
        rule.AddRequestHeaders ??= new();
    }

    private static string NormalizePrefix(string? prefix)
    {
        if (string.IsNullOrWhiteSpace(prefix)) return "/";
        prefix = prefix.Trim();
        if (!prefix.StartsWith('/')) prefix = "/" + prefix;
        if (prefix.Length > 1) prefix = prefix.TrimEnd('/');
        return prefix;
    }

    private static RouteRule Clone(RouteRule r) => new()
    {
        Id = r.Id,
        Name = r.Name,
        Enabled = r.Enabled,
        PathPrefix = r.PathPrefix,
        Destination = r.Destination,
        StripPrefix = r.StripPrefix,
        HideOrigin = r.HideOrigin,
        UseDestinationHostHeader = r.UseDestinationHostHeader,
        AddRequestHeaders = new Dictionary<string, string>(r.AddRequestHeaders),
        Methods = new List<string>(r.Methods),
    };
}
