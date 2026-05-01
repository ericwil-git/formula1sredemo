// =============================================================================
// F1.FileGenerator — minimal API on the Windows Server middle tier.
// Endpoints implement the contract in docs/techspec.md §6.
// =============================================================================

using F1.FileGenerator;
using F1.FileGenerator.Endpoints;
using Prometheus;
using Serilog;

var builder = WebApplication.CreateBuilder(args);

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
// Kestrel — listen on :8443 with HTTPS (self-signed in dev, real cert in VM).
// ---------------------------------------------------------------------------
builder.WebHost.ConfigureKestrel(options =>
{
    options.ListenAnyIP(8443, listen =>
    {
        listen.UseHttps();
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

    public interface ISqlConnectionFactory
    {
        Microsoft.Data.SqlClient.SqlConnection Create();
    }

    public sealed class SqlConnectionFactory : ISqlConnectionFactory
    {
        private readonly string _connectionString;
        public SqlConnectionFactory(IConfiguration cfg)
        {
            _connectionString = cfg["FileGenerator:SqlConnectionString"]
                ?? "Server=localhost;Database=f1demo;Integrated Security=true;TrustServerCertificate=true;";
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
        public string CacheDirectory { get; }
        public DiskFileCache(IConfiguration cfg)
        {
            CacheDirectory = cfg["CacheDirectory"] ?? "D:\\f1-files";
            Directory.CreateDirectory(CacheDirectory);
        }

        public bool TryGetCachedPath(string key, out string path)
        {
            // TODO(spec §5.2): implement keyed cache lookup with expiry.
            path = Path.Combine(CacheDirectory, key);
            return File.Exists(path);
        }

        public async Task WriteAsync(string key, string extension, Stream content, CancellationToken ct)
        {
            var path = Path.Combine(CacheDirectory, $"{key}.{extension}");
            await using var fs = File.Create(path);
            await content.CopyToAsync(fs, ct);
        }
    }
}
