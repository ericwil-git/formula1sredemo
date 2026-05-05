// =============================================================================
// /files/race  — lap-by-lap race results (CSV or JSON).
// =============================================================================

using System.Text;
using Prometheus;

namespace F1.FileGenerator.Endpoints;

public static class RaceEndpoints
{
    private const string Sql = """
        SELECT  d.Code        AS Driver,
                d.FullName    AS FullName,
                d.TeamName    AS Team,
                l.LapNumber,
                l.LapTimeMs,
                l.Sector1Ms,
                l.Sector2Ms,
                l.Sector3Ms,
                l.Compound,
                l.Position,
                l.IsPersonalBest
        FROM    dbo.Sessions s
        JOIN    dbo.Events   e  ON e.EventId  = s.EventId
        JOIN    dbo.Seasons  se ON se.SeasonId = e.SeasonId
        JOIN    dbo.Laps     l  ON l.SessionId = s.SessionId
        JOIN    dbo.Drivers  d  ON d.DriverId  = l.DriverId
        WHERE   se.[Year]      = @year
            AND e.Round        = @round
            AND s.SessionType  = 'R'
        ORDER BY l.LapNumber, l.Position;
        """;

    public static void Map(WebApplication app)
    {
        app.MapGet("/files/race", async (
            int year, int round, string? format,
            ISqlConnectionFactory db, IFileCache cache,
            CancellationToken ct) =>
        {
            format = (format ?? "csv").ToLowerInvariant();
            if (format != "csv" && format != "json")
            {
                return Results.Problem(statusCode: 400, title: "format must be csv or json");
            }

            var cacheKey = $"race-{year}-{round}.{format}";
            if (cache.TryGetCachedPath(cacheKey, out var cached))
            {
                return await ServeCachedAsync(cached, format, ct);
            }

            try
            {
                if (format == "csv")
                {
                    var csv = await SqlQueryHelpers.ExecuteCsvAsync(db, Sql, p =>
                    {
                        p.AddWithValue("@year", year);
                        p.AddWithValue("@round", round);
                    }, ct);
                    await cache.WriteAsync(cacheKey, "csv",
                        new MemoryStream(Encoding.UTF8.GetBytes(csv)), ct);
                    Metrics.FilesGenerated.WithLabels("race", "csv").Inc();
                    return Results.Text(csv, "text/csv", Encoding.UTF8);
                }
                else
                {
                    var rows = await SqlQueryHelpers.ExecuteJsonAsync(db, Sql, p =>
                    {
                        p.AddWithValue("@year", year);
                        p.AddWithValue("@round", round);
                    }, ct);
                    var payload = new { year, round, rows };
                    var json = System.Text.Json.JsonSerializer.Serialize(payload);
                    await cache.WriteAsync(cacheKey, "json",
                        new MemoryStream(Encoding.UTF8.GetBytes(json)), ct);
                    Metrics.FilesGenerated.WithLabels("race", "json").Inc();
                    return Results.Text(json, "application/json", Encoding.UTF8);
                }
            }
            catch (Microsoft.Data.SqlClient.SqlException ex)
            {
                return Results.Problem(
                    statusCode: 502,
                    title: "SQL Server unreachable",
                    detail: ex.Message);
            }
        })
        .WithName("GetRace");
    }

    private static async Task<IResult> ServeCachedAsync(string path, string format, CancellationToken ct)
    {
        var contentType = format == "csv" ? "text/csv" : "application/json";
        var bytes = await File.ReadAllBytesAsync(path, ct);
        return Results.File(bytes, contentType);
    }
}
