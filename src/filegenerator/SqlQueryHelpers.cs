// =============================================================================
// SqlQueryHelpers — shared helpers to run a parameterized SELECT and serialize
// the resulting rows to CSV or JSON. Streams to a Response so we don't buffer
// the entire result set in memory (telemetry can be 200+ rows per lap, and
// race results across drivers/laps can be ~1200 rows per race).
// =============================================================================

using System.Globalization;
using System.Text;
using System.Text.Json;
using Microsoft.Data.SqlClient;

namespace F1.FileGenerator;

public static class SqlQueryHelpers
{
    /// <summary>
    /// Execute a parameterized SELECT and return the rows as a CSV string.
    /// Header row uses column names from the reader.
    /// </summary>
    public static async Task<string> ExecuteCsvAsync(
        ISqlConnectionFactory factory,
        string sql,
        Action<SqlParameterCollection>? bindParams,
        CancellationToken ct)
    {
        await using var conn = factory.Create();
        await conn.OpenAsync(ct);
        await using var cmd = conn.CreateCommand();
        cmd.CommandText = sql;
        bindParams?.Invoke(cmd.Parameters);

        await using var reader = await cmd.ExecuteReaderAsync(ct);
        var sb = new StringBuilder();

        // Header
        for (var i = 0; i < reader.FieldCount; i++)
        {
            if (i > 0) sb.Append(',');
            sb.Append(EscapeCsv(reader.GetName(i)));
        }
        sb.Append('\n');

        // Rows
        while (await reader.ReadAsync(ct))
        {
            for (var i = 0; i < reader.FieldCount; i++)
            {
                if (i > 0) sb.Append(',');
                if (await reader.IsDBNullAsync(i, ct)) continue;
                var v = reader.GetValue(i);
                sb.Append(EscapeCsv(Convert.ToString(v, CultureInfo.InvariantCulture) ?? ""));
            }
            sb.Append('\n');
        }

        return sb.ToString();
    }

    /// <summary>
    /// Execute a parameterized SELECT and return rows as a JSON-serialized list
    /// of objects keyed by column name.
    /// </summary>
    public static async Task<List<Dictionary<string, object?>>> ExecuteJsonAsync(
        ISqlConnectionFactory factory,
        string sql,
        Action<SqlParameterCollection>? bindParams,
        CancellationToken ct)
    {
        await using var conn = factory.Create();
        await conn.OpenAsync(ct);
        await using var cmd = conn.CreateCommand();
        cmd.CommandText = sql;
        bindParams?.Invoke(cmd.Parameters);

        await using var reader = await cmd.ExecuteReaderAsync(ct);
        var rows = new List<Dictionary<string, object?>>();
        while (await reader.ReadAsync(ct))
        {
            var row = new Dictionary<string, object?>(reader.FieldCount);
            for (var i = 0; i < reader.FieldCount; i++)
            {
                row[reader.GetName(i)] = await reader.IsDBNullAsync(i, ct) ? null : reader.GetValue(i);
            }
            rows.Add(row);
        }
        return rows;
    }

    private static string EscapeCsv(string s)
    {
        if (s.IndexOfAny(new[] { ',', '"', '\n', '\r' }) < 0) return s;
        return "\"" + s.Replace("\"", "\"\"") + "\"";
    }
}
