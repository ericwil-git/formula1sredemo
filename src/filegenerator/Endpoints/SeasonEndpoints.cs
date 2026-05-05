// =============================================================================
// /files/season  — event calendar with rounds, dates, locations.
// =============================================================================

using System.Text;
using Prometheus;

namespace F1.FileGenerator.Endpoints;

public static class SeasonEndpoints
{
    private const string Sql = """
        SELECT  e.Round,
                e.Country,
                e.Location,
                e.EventName,
                e.EventDate
        FROM    dbo.Events  e
        JOIN    dbo.Seasons s ON s.SeasonId = e.SeasonId
        WHERE   s.[Year] = @year
        ORDER BY e.Round;
        """;

    public static void Map(WebApplication app)
    {
        app.MapGet("/files/season", async (
            int year, string? format,
            ISqlConnectionFactory db, IFileCache cache,
            CancellationToken ct) =>
        {
            format = (format ?? "csv").ToLowerInvariant();
            if (format != "csv" && format != "json")
            {
                return Results.Problem(statusCode: 400, title: "format must be csv or json");
            }

            var cacheKey = $"season-{year}.{format}";
            if (cache.TryGetCachedPath(cacheKey, out var cached))
            {
                var bytes = await File.ReadAllBytesAsync(cached, ct);
                return Results.File(bytes, format == "csv" ? "text/csv" : "application/json");
            }

            try
            {
                if (format == "csv")
                {
                    var csv = await SqlQueryHelpers.ExecuteCsvAsync(db, Sql,
                        p => p.AddWithValue("@year", year), ct);
                    await cache.WriteAsync(cacheKey, "csv",
                        new MemoryStream(Encoding.UTF8.GetBytes(csv)), ct);
                    Metrics.FilesGenerated.WithLabels("season", "csv").Inc();
                    return Results.Text(csv, "text/csv", Encoding.UTF8);
                }
                else
                {
                    var rows = await SqlQueryHelpers.ExecuteJsonAsync(db, Sql,
                        p => p.AddWithValue("@year", year), ct);
                    var json = System.Text.Json.JsonSerializer.Serialize(new { year, rows });
                    await cache.WriteAsync(cacheKey, "json",
                        new MemoryStream(Encoding.UTF8.GetBytes(json)), ct);
                    Metrics.FilesGenerated.WithLabels("season", "json").Inc();
                    return Results.Text(json, "application/json", Encoding.UTF8);
                }
            }
            catch (Microsoft.Data.SqlClient.SqlException ex)
            {
                Metrics.SqlErrors.WithLabels("season").Inc();
                return Results.Problem(
                    statusCode: 502,
                    title: "SQL Server unreachable",
                    detail: ex.Message);
            }
        })
        .WithName("GetSeason");
    }
}
