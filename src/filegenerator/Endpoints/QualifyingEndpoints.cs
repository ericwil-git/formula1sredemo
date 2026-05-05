// =============================================================================
// /files/qualifying  — Q1/Q2/Q3 per driver with delta-to-pole.
// =============================================================================

using System.Text;
using Prometheus;

namespace F1.FileGenerator.Endpoints;

public static class QualifyingEndpoints
{
    // Pole = the lowest qualifying time across Q1/Q2/Q3 for the session.
    // We compute delta-to-pole at the SQL layer using a window function so the
    // client doesn't have to.
    private const string Sql = """
        WITH q AS (
            SELECT  d.Code        AS Driver,
                    d.FullName    AS FullName,
                    d.TeamName    AS Team,
                    qr.Position,
                    qr.Q1Ms,
                    qr.Q2Ms,
                    qr.Q3Ms,
                    -- best of Q1/Q2/Q3 for each driver
                    (SELECT MIN(v) FROM (VALUES (qr.Q1Ms), (qr.Q2Ms), (qr.Q3Ms)) x(v) WHERE v IS NOT NULL) AS BestMs
            FROM    dbo.QualiResults qr
            JOIN    dbo.Sessions s  ON s.SessionId = qr.SessionId
            JOIN    dbo.Events   e  ON e.EventId   = s.EventId
            JOIN    dbo.Seasons  se ON se.SeasonId = e.SeasonId
            JOIN    dbo.Drivers  d  ON d.DriverId  = qr.DriverId
            WHERE   se.[Year]      = @year
                AND e.Round        = @round
                AND s.SessionType  = 'Q'
        )
        SELECT  Driver, FullName, Team, Position, Q1Ms, Q2Ms, Q3Ms,
                BestMs - MIN(BestMs) OVER () AS DeltaToPoleMs
        FROM    q
        ORDER BY Position;
        """;

    public static void Map(WebApplication app)
    {
        app.MapGet("/files/qualifying", async (
            int year, int round, string? format,
            ISqlConnectionFactory db, IFileCache cache,
            CancellationToken ct) =>
        {
            format = (format ?? "csv").ToLowerInvariant();
            if (format != "csv" && format != "json")
            {
                return Results.Problem(statusCode: 400, title: "format must be csv or json");
            }

            var cacheKey = $"qualifying-{year}-{round}.{format}";
            if (cache.TryGetCachedPath(cacheKey, out var cached))
            {
                var bytes = await File.ReadAllBytesAsync(cached, ct);
                return Results.File(bytes, format == "csv" ? "text/csv" : "application/json");
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
                    Metrics.FilesGenerated.WithLabels("qualifying", "csv").Inc();
                    return Results.Text(csv, "text/csv", Encoding.UTF8);
                }
                else
                {
                    var rows = await SqlQueryHelpers.ExecuteJsonAsync(db, Sql, p =>
                    {
                        p.AddWithValue("@year", year);
                        p.AddWithValue("@round", round);
                    }, ct);
                    var json = System.Text.Json.JsonSerializer.Serialize(new { year, round, rows });
                    await cache.WriteAsync(cacheKey, "json",
                        new MemoryStream(Encoding.UTF8.GetBytes(json)), ct);
                    Metrics.FilesGenerated.WithLabels("qualifying", "json").Inc();
                    return Results.Text(json, "application/json", Encoding.UTF8);
                }
            }
            catch (Microsoft.Data.SqlClient.SqlException ex)
            {
                Metrics.SqlErrors.WithLabels("qualifying").Inc();
                return Results.Problem(
                    statusCode: 502,
                    title: "SQL Server unreachable",
                    detail: ex.Message);
            }
        })
        .WithName("GetQualifying");
    }
}
