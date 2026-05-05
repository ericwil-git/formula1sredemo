// =============================================================================
// /health  — liveness + dependency probe.
// =============================================================================

namespace F1.FileGenerator.Endpoints;

public static class HealthEndpoints
{
    public static void Map(WebApplication app)
    {
        app.MapGet("/health", async (ISqlConnectionFactory db, IFileCache cache) =>
        {
            string sqlStatus;
            try
            {
                await using var conn = db.Create();
                await conn.OpenAsync();
                await using var cmd = conn.CreateCommand();
                cmd.CommandText = "SELECT 1";
                _ = await cmd.ExecuteScalarAsync();
                sqlStatus = "reachable";
            }
            catch (Exception ex)
            {
                sqlStatus = $"unreachable: {ex.GetType().Name}: {ex.Message}";
            }

            long sizeBytes = 0;
            try
            {
                if (Directory.Exists(cache.CacheDirectory))
                {
                    sizeBytes = new DirectoryInfo(cache.CacheDirectory)
                        .EnumerateFiles("*", SearchOption.AllDirectories)
                        .Sum(f => f.Length);
                }
            }
            catch { /* best-effort */ }

            return Results.Json(new
            {
                status = "ok",
                sqlServer = sqlStatus,
                cacheSizeMb = sizeBytes / 1024 / 1024
            });
        })
        .WithName("GetHealth");
    }
}
