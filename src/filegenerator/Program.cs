// =============================================================================
// F1.FileGenerator — minimal API on the Windows Server middle tier.
// Endpoints implement the contract in docs/techspec.md §6.
// =============================================================================

using Azure.Extensions.AspNetCore.Configuration.Secrets;
using Azure.Identity;
using Azure.Monitor.OpenTelemetry.AspNetCore;
using Azure.Security.KeyVault.Secrets;
using F1.FileGenerator;
using F1.FileGenerator.Endpoints;
using OpenTelemetry.Logs;
using OpenTelemetry.Resources;
using Prometheus;
using Serilog;

var builder = WebApplication.CreateBuilder(args);

// Run as a Windows service when launched by SCM. No-op when run interactively
// (`dotnet run`), so local dev is unchanged.
builder.Host.UseWindowsService(options =>
{
    options.ServiceName = "F1 FileGenerator";
});

// ---------------------------------------------------------------------------
// Key Vault config provider (optional). When KeyVault:Uri is set, the VM's
// managed identity reads secrets and aliases them to the FileGenerator
// config shape:
//   fileGeneratorApiKey               -> FileGenerator:ApiKey
//   sqlConnectionString               -> FileGenerator:SqlConnectionString
//   applicationInsightsConnectionString -> ApplicationInsights:ConnectionString
// ---------------------------------------------------------------------------
var kvUri = builder.Configuration["KeyVault:Uri"];
if (!string.IsNullOrWhiteSpace(kvUri))
{
    builder.Configuration.AddAzureKeyVault(
        new SecretClient(new Uri(kvUri), new DefaultAzureCredential()),
        new F1KvSecretManager());
}

// ---------------------------------------------------------------------------
// OpenTelemetry / Azure Monitor distro (Phase 1 of the SRE roadmap).
// Auto-instruments ASP.NET Core, HttpClient, and Microsoft.Data.SqlClient,
// so every web request shows up as a Web -> FileGen -> SQL waterfall in
// Application Insights -> Transaction Search. The ConnectionString comes
// from KV (mapped above). When it is missing (e.g. local `dotnet run`
// without KV), we skip OTel entirely so startup still succeeds.
// ---------------------------------------------------------------------------
var aiConnectionString = builder.Configuration["ApplicationInsights:ConnectionString"];
if (!string.IsNullOrWhiteSpace(aiConnectionString))
{
    builder.Services
        .AddOpenTelemetry()
        .ConfigureResource(r => r.AddService(
            serviceName: "F1.FileGenerator",
            serviceVersion: typeof(Program).Assembly.GetName().Version?.ToString() ?? "1.0.0"))
        .UseAzureMonitor(o =>
        {
            o.ConnectionString = aiConnectionString;
        });

    // Capture log scopes + formatted message bodies so the App Insights
    // "traces" table is actually useful when correlating with spans.
    builder.Services.Configure<OpenTelemetryLoggerOptions>(o =>
    {
        o.IncludeFormattedMessage = true;
        o.IncludeScopes = true;
    });
}

// ---------------------------------------------------------------------------
// Logging — structured JSON to console + rolling file picked up by AMA.
// ---------------------------------------------------------------------------
var logDir = builder.Configuration["LogDirectory"] ?? "D:\\f1-files\\logs";
Directory.CreateDirectory(logDir);
Log.Logger = new LoggerConfiguration()
    .Enrich.FromLogContext()
    .WriteTo.Console(new Serilog.Formatting.Json.JsonFormatter())
    .WriteTo.File(
        formatter: new Serilog.Formatting.Json.JsonFormatter(),
        path: Path.Combine(logDir, "filegen-.log"),
        rollingInterval: RollingInterval.Day,
        retainedFileCountLimit: 14)
    .CreateLogger();
builder.Host.UseSerilog();

// ---------------------------------------------------------------------------
// Kestrel — listen on :8443 with HTTPS. In production (Windows service on the
// VM) load the PFX from `Kestrel:CertificatePath`. Locally (`dotnet run`) fall
// back to the ASP.NET dev cert.
// ---------------------------------------------------------------------------
builder.WebHost.ConfigureKestrel(options =>
{
    var certPath = builder.Configuration["Kestrel:CertificatePath"];
    var certPassword = builder.Configuration["Kestrel:CertificatePassword"];

    options.ListenAnyIP(8443, listen =>
    {
        if (!string.IsNullOrWhiteSpace(certPath) && File.Exists(certPath))
        {
            listen.UseHttps(certPath, certPassword);
        }
        else
        {
            listen.UseHttps();
        }
    });
});

// ---------------------------------------------------------------------------
// Services
// ---------------------------------------------------------------------------
builder.Services.AddSingleton<ISqlConnectionFactory, SqlConnectionFactory>();
builder.Services.AddSingleton<IFileCache, DiskFileCache>();
builder.Services.AddSingleton<ApiKeyOptions>(sp =>
    new ApiKeyOptions(builder.Configuration["FileGenerator:ApiKey"] ?? ""));
builder.Services.AddProblemDetails();

var app = builder.Build();

// ---------------------------------------------------------------------------
// Pipeline
// ---------------------------------------------------------------------------
app.UseSerilogRequestLogging();
app.UseHttpMetrics();

// API-key middleware (skipped for /health and /metrics).
app.Use(async (ctx, next) =>
{
    var path = ctx.Request.Path.Value ?? "";
    if (path.StartsWith("/health", StringComparison.OrdinalIgnoreCase) ||
        path.StartsWith("/metrics", StringComparison.OrdinalIgnoreCase))
    {
        await next();
        return;
    }

    var expected = ctx.RequestServices.GetRequiredService<ApiKeyOptions>().Value;
    if (!ctx.Request.Headers.TryGetValue("X-Api-Key", out var provided) ||
        string.IsNullOrEmpty(expected) ||
        !string.Equals(provided.ToString(), expected, StringComparison.Ordinal))
    {
        ctx.Response.StatusCode = StatusCodes.Status401Unauthorized;
        await ctx.Response.WriteAsJsonAsync(new { type = "about:blank", title = "Unauthorized", status = 401 });
        return;
    }

    await next();
});

// ---------------------------------------------------------------------------
// Endpoints
// ---------------------------------------------------------------------------
app.MapMetrics();   // /metrics
HealthEndpoints.Map(app);
RaceEndpoints.Map(app);
QualifyingEndpoints.Map(app);
LapDetailEndpoints.Map(app);
SeasonEndpoints.Map(app);

app.Run();

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

namespace F1.FileGenerator
{
    public sealed record ApiKeyOptions(string Value);

    /// <summary>
    /// Maps Key Vault secret names to the .NET configuration shape this app
    /// expects. KV secret names are flat (no colons), and they're stored as
    /// camelCase by Bicep, so we explicitly translate the ones we care about.
    /// Any other secret in the vault is ignored to avoid surprise surface area.
    /// </summary>
    public sealed class F1KvSecretManager : Azure.Extensions.AspNetCore.Configuration.Secrets.KeyVaultSecretManager
    {
        public override bool Load(Azure.Security.KeyVault.Secrets.SecretProperties secret)
            => secret.Name is "fileGeneratorApiKey"
                           or "sqlConnectionString"
                           or "applicationInsightsConnectionString";

        public override string GetKey(Azure.Security.KeyVault.Secrets.KeyVaultSecret secret) => secret.Name switch
        {
            "fileGeneratorApiKey"               => "FileGenerator:ApiKey",
            "sqlConnectionString"               => "FileGenerator:SqlConnectionString",
            "applicationInsightsConnectionString" => "ApplicationInsights:ConnectionString",
            _ => secret.Name
        };
    }

    public interface ISqlConnectionFactory
    {
        Microsoft.Data.SqlClient.SqlConnection Create();
    }

    public sealed class SqlConnectionFactory : ISqlConnectionFactory
    {
        private readonly string _connectionString;
        public SqlConnectionFactory(IConfiguration cfg, ILogger<SqlConnectionFactory> log)
        {
            _connectionString = cfg["FileGenerator:SqlConnectionString"]
                ?? "Server=localhost,1433;Database=f1demo;Integrated Security=true;TrustServerCertificate=true;";
            // Log a sanitized form so we can confirm config without leaking the password.
            var b = new Microsoft.Data.SqlClient.SqlConnectionStringBuilder(_connectionString);
            log.LogInformation("SQL target: {server}/{db} (auth={auth})",
                b.DataSource, b.InitialCatalog,
                string.IsNullOrEmpty(b.UserID) ? "Integrated" : $"User={b.UserID}");
        }

        public Microsoft.Data.SqlClient.SqlConnection Create()
            => new Microsoft.Data.SqlClient.SqlConnection(_connectionString);
    }

    public interface IFileCache
    {
        string CacheDirectory { get; }
        bool TryGetCachedPath(string key, out string path);
        Task WriteAsync(string key, string extension, Stream content, CancellationToken ct);
    }

    public sealed class DiskFileCache : IFileCache
    {
        private static readonly TimeSpan CacheTtl = TimeSpan.FromHours(1);
        public string CacheDirectory { get; }
        public DiskFileCache(IConfiguration cfg)
        {
            CacheDirectory = cfg["CacheDirectory"] ?? "D:\\f1-files";
            Directory.CreateDirectory(CacheDirectory);
        }

        public bool TryGetCachedPath(string key, out string path)
        {
            path = Path.Combine(CacheDirectory, key);
            if (!File.Exists(path)) return false;
            var age = DateTime.UtcNow - File.GetLastWriteTimeUtc(path);
            return age < CacheTtl;
        }

        public async Task WriteAsync(string key, string extension, Stream content, CancellationToken ct)
        {
            // Cache key already includes the extension (e.g. "race-2024-8.csv").
            // Honor that and only append if missing, so reads + writes use the
            // same path.
            var fileName = key.EndsWith($".{extension}", StringComparison.OrdinalIgnoreCase)
                ? key
                : $"{key}.{extension}";
            var path = Path.Combine(CacheDirectory, fileName);
            await using var fs = File.Create(path);
            await content.CopyToAsync(fs, ct);
        }
    }
}
