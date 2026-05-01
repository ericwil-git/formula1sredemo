// =============================================================================
// F1 Insights Web — ASP.NET Core 8 Blazor Server (anonymous).
// =============================================================================

using F1.Web;
using F1.Web.Services;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddRazorPages();
builder.Services.AddServerSideBlazor();
builder.Services.AddApplicationInsightsTelemetry();

// Strongly-typed FileGenerator client. ApiKey + BaseUrl come from Key Vault
// references on App Service (FileGenerator__BaseUrl, FileGenerator__ApiKey).
builder.Services.Configure<FileGeneratorOptions>(builder.Configuration.GetSection("FileGenerator"));
builder.Services.AddHttpClient<FileGeneratorClient>()
    .ConfigurePrimaryHttpMessageHandler(() => new HttpClientHandler
    {
        // FileGenerator uses a self-signed cert on the VM. Trust it; the
        // request never leaves the VNet.
        ServerCertificateCustomValidationCallback = HttpClientHandler.DangerousAcceptAnyServerCertificateValidator
    });

var app = builder.Build();

if (!app.Environment.IsDevelopment())
{
    app.UseExceptionHandler("/Error");
    app.UseHsts();
}

app.UseHttpsRedirection();
app.UseStaticFiles();
app.UseRouting();

app.MapBlazorHub();
app.MapFallbackToPage("/_Host");

app.Run();

namespace F1.Web
{
    public sealed class FileGeneratorOptions
    {
        public string BaseUrl { get; set; } = "";
        public string ApiKey  { get; set; } = "";
    }
}
