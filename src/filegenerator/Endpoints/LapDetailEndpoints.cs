// =============================================================================
// /files/lap-detail  — telemetry samples for a single lap.
// =============================================================================

using System.Text;
using Prometheus;

namespace F1.FileGenerator.Endpoints;

public static class LapDetailEndpoints
{
    private const string Sql = """
        SELECT  t.SampleTimeMs,
                t.SpeedKph,
                t.RPM,
                t.Throttle,
                CONVERT(int, t.Brake)  AS Brake,
                t.Gear,
                t.DRS
        FROM    dbo.Telemetry t
        JOIN    dbo.Laps     l  ON l.LapId      = t.LapId
        JOIN    dbo.Sessions s  ON s.SessionId  = l.SessionId
        JOIN    dbo.Events   e  ON e.EventId    = s.EventId
        JOIN    dbo.Seasons  se ON se.SeasonId  = e.SeasonId
        JOIN    dbo.Drivers  d  ON d.DriverId   = l.DriverId
        WHERE   se.[Year]      = @year
            AND e.Round        = @round
            AND s.SessionType  = @session
            AND d.Code         = @driver
            AND l.LapNumber    = @lap
        ORDER BY t.SampleTimeMs;
        """;

    public static void Map(WebApplication app)
    {
        app.MapGet("/files/lap-detail", async (
            int year, int round, string session, string driver, int lap, string? format,
            ISqlConnectionFactory db, IFileCache cache,
            CancellationToken ct) =>
        {
            format = (format ?? "json").ToLowerInvariant();
            if (format != "csv" && format != "json")
            {
                return Results.Problem(statusCode: 400, title: "format must be csv or json");
            }

            var cacheKey = $"lap-{year}-{round}-{session}-{driver}-{lap}.{format}";
            if (cache.TryGetCachedPath(cacheKey, out var cached))
            {
                Metrics.RecordCacheHit("lap-detail");
                var bytes = await File.ReadAllBytesAsync(cached, ct);
                return Results.File(bytes, format == "csv" ? "text/csv" : "application/json");
            }
            Metrics.RecordCacheMiss("lap-detail");

            void Bind(Microsoft.Data.SqlClient.SqlParameterCollection p)
            {
                p.AddWithValue("@year", year);
                p.AddWithValue("@round", round);
                p.AddWithValue("@session", session);
                p.AddWithValue("@driver", driver);
                p.AddWithValue("@lap", lap);
            }

            try
            {
                if (format == "csv")
                {
                    var csv = await SqlQueryHelpers.ExecuteCsvAsync(db, Sql, Bind, ct);
                    await cache.WriteAsync(cacheKey, "csv",
                        new MemoryStream(Encoding.UTF8.GetBytes(csv)), ct);
                    Metrics.RecordFileGenerated("lap-detail", "csv");
                    return Results.Text(csv, "text/csv", Encoding.UTF8);
                }
                else
                {
                    var samples = await SqlQueryHelpers.ExecuteJsonAsync(db, Sql, Bind, ct);
                    var payload = new { year, round, session, driver, lap, samples };
                    var json = System.Text.Json.JsonSerializer.Serialize(payload);
                    await cache.WriteAsync(cacheKey, "json",
                        new MemoryStream(Encoding.UTF8.GetBytes(json)), ct);
                    Metrics.RecordFileGenerated("lap-detail", "json");
                    return Results.Text(json, "application/json", Encoding.UTF8);
                }
            }
            catch (Microsoft.Data.SqlClient.SqlException ex)
            {
                Metrics.RecordSqlError("lap-detail");
                return Results.Problem(
                    statusCode: 502,
                    title: "SQL Server unreachable",
                    detail: ex.Message);
            }
        })
        .WithName("GetLapDetail");
    }
}
