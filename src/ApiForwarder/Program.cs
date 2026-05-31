using System.Net;
using System.Net.Sockets;
using System.Security.Claims;
using ApiForwarder.Models;
using ApiForwarder.Services;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Authentication.Cookies;
using Microsoft.AspNetCore.HttpOverrides;
using Yarp.ReverseProxy.Configuration;

var builder = WebApplication.CreateBuilder(args);

// ---------------------------------------------------------------------------
// Configuration / options
// ---------------------------------------------------------------------------
var adminUser = builder.Configuration["Admin:Username"] ?? "admin";
var adminPass = builder.Configuration["Admin:Password"] ?? "change-me";

// ---------------------------------------------------------------------------
// Services
// ---------------------------------------------------------------------------

// Behind Cloudflare + IIS the real client IP arrives in forwarded headers.
// We honour them so admin logging is accurate (this does NOT affect what the
// upstream sees — outbound requests always originate from this server).
builder.Services.Configure<ForwardedHeadersOptions>(o =>
{
    o.ForwardedHeaders = ForwardedHeaders.XForwardedFor | ForwardedHeaders.XForwardedProto;
    o.KnownNetworks.Clear();
    o.KnownProxies.Clear();
});

builder.Services.AddSingleton<ProxyConfigProvider>();
builder.Services.AddSingleton<IProxyConfigProvider>(sp => sp.GetRequiredService<ProxyConfigProvider>());
builder.Services.AddSingleton<RouteStore>();
builder.Services.AddHttpClient("outbound-ip");

builder.Services.AddReverseProxy();

builder.Services
    .AddAuthentication(CookieAuthenticationDefaults.AuthenticationScheme)
    .AddCookie(options =>
    {
        options.Cookie.Name = "apifwd.auth";
        options.Cookie.HttpOnly = true;
        options.Cookie.SameSite = SameSiteMode.Lax;
        options.Cookie.SecurePolicy = CookieSecurePolicy.SameAsRequest;
        options.ExpireTimeSpan = TimeSpan.FromHours(8);
        options.SlidingExpiration = true;
        options.LoginPath = "/admin/login.html";
        options.LogoutPath = "/admin/api/logout";

        // For API calls return 401/403 instead of redirecting to the login page.
        options.Events.OnRedirectToLogin = ctx =>
        {
            if (ctx.Request.Path.StartsWithSegments("/admin/api"))
            {
                ctx.Response.StatusCode = StatusCodes.Status401Unauthorized;
                return Task.CompletedTask;
            }
            ctx.Response.Redirect(ctx.RedirectUri);
            return Task.CompletedTask;
        };
        options.Events.OnRedirectToAccessDenied = ctx =>
        {
            ctx.Response.StatusCode = StatusCodes.Status403Forbidden;
            return Task.CompletedTask;
        };
    });

builder.Services.AddAuthorization();

var app = builder.Build();

// Eagerly build the store so saved rules are applied on startup.
app.Services.GetRequiredService<RouteStore>();

// ---------------------------------------------------------------------------
// Pipeline
// ---------------------------------------------------------------------------
app.UseForwardedHeaders();

// Serve the admin SPA assets from wwwroot (e.g. /admin/index.html).
app.UseDefaultFiles();
app.UseStaticFiles();

app.UseAuthentication();
app.UseAuthorization();

// Health probe (used by IIS / monitoring).
app.MapGet("/health", () => Results.Text("OK")).AllowAnonymous();

// ---------------------------------------------------------------------------
// Admin API
// ---------------------------------------------------------------------------
var admin = app.MapGroup("/admin/api");

admin.MapPost("/login", async (LoginRequest req, HttpContext ctx) =>
{
    if (!string.Equals(req.Username, adminUser, StringComparison.Ordinal) ||
        !string.Equals(req.Password, adminPass, StringComparison.Ordinal))
    {
        return Results.Json(new { error = "نام کاربری یا رمز عبور نادرست است" }, statusCode: 401);
    }

    var claims = new List<Claim> { new(ClaimTypes.Name, req.Username) };
    var identity = new ClaimsIdentity(claims, CookieAuthenticationDefaults.AuthenticationScheme);
    await ctx.SignInAsync(CookieAuthenticationDefaults.AuthenticationScheme, new ClaimsPrincipal(identity));
    return Results.Ok(new { username = req.Username });
}).AllowAnonymous();

admin.MapPost("/logout", async (HttpContext ctx) =>
{
    await ctx.SignOutAsync(CookieAuthenticationDefaults.AuthenticationScheme);
    return Results.Ok();
}).AllowAnonymous();

admin.MapGet("/session", (HttpContext ctx) =>
    ctx.User.Identity?.IsAuthenticated == true
        ? Results.Ok(new { authenticated = true, username = ctx.User.Identity!.Name })
        : Results.Ok(new { authenticated = false })
).AllowAnonymous();

admin.MapGet("/routes", (RouteStore store) => Results.Ok(store.GetAll()))
    .RequireAuthorization();

admin.MapGet("/routes/{id}", (string id, RouteStore store) =>
{
    var rule = store.Get(id);
    return rule is null ? Results.NotFound() : Results.Ok(rule);
}).RequireAuthorization();

admin.MapPost("/routes", (RouteRule rule, RouteStore store) =>
{
    var error = Validate(rule);
    if (error is not null) return Results.BadRequest(new { error });
    var created = store.Add(rule);
    return Results.Created($"/admin/api/routes/{created.Id}", created);
}).RequireAuthorization();

admin.MapPut("/routes/{id}", (string id, RouteRule rule, RouteStore store) =>
{
    var error = Validate(rule);
    if (error is not null) return Results.BadRequest(new { error });
    return store.Update(id, rule) ? Results.Ok(rule) : Results.NotFound();
}).RequireAuthorization();

admin.MapDelete("/routes/{id}", (string id, RouteStore store) =>
    store.Delete(id) ? Results.NoContent() : Results.NotFound()
).RequireAuthorization();

// Shows the public IP that upstreams will see when this server calls them.
admin.MapGet("/server-info", async (IHttpClientFactory factory, HttpContext ctx, CancellationToken ct) =>
{
    string? outboundIp = null;
    try
    {
        var client = factory.CreateClient("outbound-ip");
        client.Timeout = TimeSpan.FromSeconds(5);
        outboundIp = (await client.GetStringAsync("https://api.ipify.org", ct)).Trim();
    }
    catch
    {
        // Network may be restricted; fall back to local addresses below.
    }

    var localIps = new List<string>();
    try
    {
        foreach (var ip in Dns.GetHostAddresses(Dns.GetHostName()))
            if (ip.AddressFamily == AddressFamily.InterNetwork)
                localIps.Add(ip.ToString());
    }
    catch { /* ignore */ }

    return Results.Ok(new
    {
        outboundIp,
        localIps,
        machineName = Environment.MachineName,
        callerIp = ctx.Connection.RemoteIpAddress?.ToString()
    });
}).RequireAuthorization();

// ---------------------------------------------------------------------------
// Reverse proxy (must be last so admin/static routes take precedence)
// ---------------------------------------------------------------------------
app.MapReverseProxy();

app.Run();

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
static string? Validate(RouteRule rule)
{
    if (string.IsNullOrWhiteSpace(rule.Name)) return "نام الزامی است";
    if (string.IsNullOrWhiteSpace(rule.PathPrefix)) return "مسیر عمومی (Path) الزامی است";
    if (string.IsNullOrWhiteSpace(rule.Destination)) return "آدرس مقصد الزامی است";
    if (!Uri.TryCreate(rule.Destination.TrimEnd('/'), UriKind.Absolute, out var uri) ||
        (uri.Scheme != Uri.UriSchemeHttp && uri.Scheme != Uri.UriSchemeHttps))
        return "آدرس مقصد باید یک URL کامل (http/https) باشد";
    return null;
}

public record LoginRequest(string Username, string Password);
