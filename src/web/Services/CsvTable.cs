// =============================================================================
// CsvTable — naive CSV parser (no quoted-comma handling needed; FileGenerator
// values never contain commas/newlines).
// =============================================================================

namespace F1.Web.Services;

public static class CsvTable
{
    public sealed record Table(IReadOnlyList<string> Headers, IReadOnlyList<IReadOnlyList<string>> Rows);

    public static Table Parse(string csv)
    {
        if (string.IsNullOrWhiteSpace(csv))
        {
            return new Table(Array.Empty<string>(), Array.Empty<IReadOnlyList<string>>());
        }

        var lines = csv.Replace("\r\n", "\n").TrimEnd('\n').Split('\n');
        var headers = lines[0].Split(',');
        var rows = new List<IReadOnlyList<string>>(lines.Length - 1);
        for (var i = 1; i < lines.Length; i++)
        {
            var raw = lines[i];
            if (string.IsNullOrEmpty(raw)) continue;
            // Simple split — FileGenerator escapes only when value contains a
            // comma; for our F1 columns (numbers, codes, single-token names),
            // raw split is safe.
            var cells = raw.Split(',');
            // Pad short rows so renderers can index by header position.
            if (cells.Length < headers.Length)
            {
                Array.Resize(ref cells, headers.Length);
            }
            rows.Add(cells);
        }
        return new Table(headers, rows);
    }

    public static int IndexOf(IReadOnlyList<string> headers, string name)
    {
        for (var i = 0; i < headers.Count; i++)
        {
            if (string.Equals(headers[i], name, StringComparison.OrdinalIgnoreCase)) return i;
        }
        return -1;
    }
}
