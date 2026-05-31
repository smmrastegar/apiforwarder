using System.ComponentModel.DataAnnotations;

namespace ApiForwarder.Models;

/// <summary>
/// A single forwarding rule. The public client only ever sees the
/// <see cref="PathPrefix"/> on the public host (e.g. https://api.lto.bz/github),
/// while the real upstream <see cref="Destination"/> stays server-side and is
/// never exposed in responses.
/// </summary>
public class RouteRule
{
    public string Id { get; set; } = Guid.NewGuid().ToString("n");

    /// <summary>Friendly name shown in the UI.</summary>
    [Required]
    public string Name { get; set; } = string.Empty;

    /// <summary>Whether this rule is active.</summary>
    public bool Enabled { get; set; } = true;

    /// <summary>
    /// Public path prefix that callers use, e.g. "/github".
    /// Everything after the prefix is forwarded to the destination.
    /// </summary>
    [Required]
    public string PathPrefix { get; set; } = "/";

    /// <summary>
    /// The real (hidden) upstream base URL, e.g. "https://api.github.com".
    /// </summary>
    [Required]
    public string Destination { get; set; } = string.Empty;

    /// <summary>
    /// Remove <see cref="PathPrefix"/> from the path before forwarding.
    /// e.g. /github/users -> https://api.github.com/users
    /// </summary>
    public bool StripPrefix { get; set; } = true;

    /// <summary>
    /// Hide the original caller from the upstream: strip X-Forwarded-* headers
    /// so the upstream only ever sees this server's IP address.
    /// </summary>
    public bool HideOrigin { get; set; } = true;

    /// <summary>
    /// Send the upstream's own host name in the Host header (recommended for
    /// most public APIs that route on Host / use SNI/virtual hosting).
    /// </summary>
    public bool UseDestinationHostHeader { get; set; } = true;

    /// <summary>Extra request headers to add/override when forwarding.</summary>
    public Dictionary<string, string> AddRequestHeaders { get; set; } = new();

    /// <summary>Optional: only forward these HTTP methods (empty = all).</summary>
    public List<string> Methods { get; set; } = new();
}
