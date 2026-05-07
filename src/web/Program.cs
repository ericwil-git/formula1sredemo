// =============================================================================
// F1 Insights Web — ASP.NET Core 8 Blazor Server (anonymous).
// =============================================================================

using F1.Web;
using F1.Web.Services;
using Microsoft.ApplicationInsights.Channel;
using Microsoft.ApplicationInsights.Extensibility;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddRazorPages();
builder.Services.AddServerSideBlazor();
builder.Services.AddApplicationInsightsTelemetry();
// Make this app show up as "F1.Web" on the App Insights Application Map
// (otherwise it defaults to the App Service site name, e.g.
// "app-f1demo-wr4dcd"). Pairs with cloud_RoleName="F1.FileGenerator" set
// by the OTel distro on the VM tier so the map shows the two nodes
// connected by an arrow.
builder.Services.AddSingleton<ITelemetryInitializer, CloudRoleNameInitializer>();

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

    /// <summary>
    /// Stamps every telemetry item with a stable cloud role name so the
    /// Application Insights Application Map labels this app "F1.Web".
    /// </summary>
    internal sealed class CloudRoleNameInitializer : ITelemetryInitializer
    {
        private const string RoleName = "F1.Web";
        public void Initialize(ITelemetry telemetry)
        {
            if (string.IsNullOrEmpty(telemetry.Context.Cloud.RoleName))
            {
                telemetry.Context.Cloud.RoleName = RoleName;
            }
        }
    }
}
