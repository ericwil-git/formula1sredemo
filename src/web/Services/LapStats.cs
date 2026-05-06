// =============================================================================
// LapStats — compute min/Q1/median/Q3/max from a sorted set of lap times.
// =============================================================================

namespace F1.Web.Services;

public static class LapStats
{
    public sealed record FiveNumber(double Min, double Q1, double Median, double Q3, double Max, int Count);

    public static FiveNumber? Compute(IEnumerable<int> lapTimesMs)
    {
        var sorted = lapTimesMs.Where(v => v > 0).OrderBy(v => v).ToArray();
        if (sorted.Length == 0) return null;
        return new FiveNumber(
            Min:    sorted[0],
            Q1:     Percentile(sorted, 25),
            Median: Percentile(sorted, 50),
            Q3:     Percentile(sorted, 75),
            Max:    sorted[^1],
            Count:  sorted.Length);
    }

    private static double Percentile(int[] sorted, double p)
    {
        if (sorted.Length == 1) return sorted[0];
        var pos = (p / 100.0) * (sorted.Length - 1);
        var lo  = (int)Math.Floor(pos);
        var hi  = (int)Math.Ceiling(pos);
        if (lo == hi) return sorted[lo];
        return sorted[lo] + (pos - lo) * (sorted[hi] - sorted[lo]);
    }
}
