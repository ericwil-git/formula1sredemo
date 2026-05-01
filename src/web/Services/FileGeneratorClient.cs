// =============================================================================
// FileGeneratorClient — typed HTTP client for the Windows Server middle tier.
// =============================================================================

using System.Net.Http.Headers;
using Microsoft.Extensions.Options;
using F1.Web;

namespace F1.Web.Services;

public sealed class FileGeneratorClient
{
    private readonly HttpClient _http;
    private readonly FileGeneratorOptions _opts;

    public FileGeneratorClient(HttpClient http, IOptions<FileGeneratorOptions> opts)
    {
        _opts = opts.Value;
        _http = http;
        if (!string.IsNullOrEmpty(_opts.BaseUrl))
        {
            _http.BaseAddress = new Uri(_opts.BaseUrl);
        }
        if (!string.IsNullOrEmpty(_opts.ApiKey))
        {
            _http.DefaultRequestHeaders.Add("X-Api-Key", _opts.ApiKey);
        }
        _http.DefaultRequestHeaders.Accept.Clear();
        _http.DefaultRequestHeaders.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
    }

    public async Task<string> GetSeasonCsvAsync(int year, CancellationToken ct = default)
        => await GetCsvAsync($"/files/season?year={year}&format=csv", ct);

    public async Task<string> GetRaceCsvAsync(int year, int round, CancellationToken ct = default)
        => await GetCsvAsync($"/files/race?year={year}&round={round}&format=csv", ct);

    public async Task<string> GetQualifyingCsvAsync(int year, int round, CancellationToken ct = default)
        => await GetCsvAsync($"/files/qualifying?year={year}&round={round}&format=csv", ct);

    public async Task<string> GetLapDetailJsonAsync(int year, int round, string session,
        string driver, int lap, CancellationToken ct = default)
        => await GetJsonAsync(
            $"/files/lap-detail?year={year}&round={round}&session={session}&driver={driver}&lap={lap}&format=json",
            ct);

    private async Task<string> GetCsvAsync(string path, CancellationToken ct)
    {
        if (string.IsNullOrEmpty(_opts.BaseUrl))
        {
            return "Year,Round,Driver,Team,Lap,LapTimeMs,Position\n2024,8,VER,Red Bull Racing,1,76123,1\n";
        }

        try
        {
            using var req = new HttpRequestMessage(HttpMethod.Get, path);
            req.Headers.Accept.Clear();
            req.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("text/csv"));
            using var resp = await _http.SendAsync(req, ct);
            resp.EnsureSuccessStatusCode();
            return await resp.Content.ReadAsStringAsync(ct);
        }
        catch (Exception ex)
        {
            return $"# error: {ex.GetType().Name}: {ex.Message}\n";
        }
    }

    private async Task<string> GetJsonAsync(string path, CancellationToken ct)
    {
        if (string.IsNullOrEmpty(_opts.BaseUrl))
        {
            return "{\"samples\":[]}";
        }

        try
        {
            using var resp = await _http.GetAsync(path, ct);
            resp.EnsureSuccessStatusCode();
            return await resp.Content.ReadAsStringAsync(ct);
        }
        catch (Exception ex)
        {
            return $"{{\"error\":\"{ex.GetType().Name}\",\"message\":\"{ex.Message}\"}}";
        }
    }
}
