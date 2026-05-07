<#
.SYNOPSIS
    Publish + service-install F1.FileGenerator on the VM.

.DESCRIPTION
    Run AFTER the source tree is on disk (manual zip-extract or git clone).

    1. dotnet publish -> D:\f1demo\filegenerator
    2. Generate self-signed PFX -> D:\f1demo\certs\filegen.pfx
    3. Install/replace Windows service "F1FileGenerator" running as LocalSystem
    4. Set machine env vars: KeyVault__Uri, Kestrel__CertificatePath/Password,
       ASPNETCORE_ENVIRONMENT
    5. Start service + smoke test https://localhost:8443/health

.PARAMETER KeyVaultUri
    Full vault URI, e.g. https://kv-f1demo-wr4dcd.vault.azure.net/

.PARAMETER RepoRoot
    Path to the directory containing the FileGenerator.csproj's parent tree.
    Default: D:\f1demo\repo\formula1sredemo-main\formula1sredemo-main
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $KeyVaultUri,
    [string] $RepoRoot = 'D:\f1demo\repo\formula1sredemo-main\formula1sredemo-main'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference   = 'SilentlyContinue'

$ServiceName = 'F1FileGenerator'
$DotnetExe   = 'D:\f1demo\tools\dotnet\dotnet.exe'
$AppDir      = 'D:\f1demo\filegenerator'
$CertDir     = 'D:\f1demo\certs'
$CertPath    = Join-Path $CertDir 'filegen.pfx'
$LogDir      = 'D:\f1-files\logs'
$ProjectPath = Join-Path $RepoRoot 'src\filegenerator\FileGenerator.csproj'

New-Item -ItemType Directory -Force -Path $CertDir, $LogDir | Out-Null

if (-not (Test-Path $DotnetExe)) { throw "dotnet not found at $DotnetExe" }
if (-not (Test-Path $ProjectPath)) { throw "csproj not found at $ProjectPath" }

# -------------------------------------------------------------------
# 1. Publish
# -------------------------------------------------------------------
Write-Host '[1/5] dotnet publish (~3-5 min on first run)...'

# NuGet sources can be missing on a fresh SDK install; ensure nuget.org
# is registered before restore. Also: MCAPS subscriptions sometimes block
# outbound HTTPS — fail fast with a clear message if so.
$nugetCfg = "$env:APPDATA\NuGet\NuGet.Config"
if (-not (Test-Path $nugetCfg) -or -not (Select-String -Path $nugetCfg -Pattern 'nuget.org' -Quiet -ErrorAction SilentlyContinue)) {
    Write-Host '       adding nuget.org source...'
    & $DotnetExe nuget add source https://api.nuget.org/v3/index.json --name nuget.org 2>&1 |
        ForEach-Object { Write-Host "       $_" }
}

# Probe outbound connectivity to nuget.org so we get a clear error before
# wasting 5 minutes on retry/backoff.
try {
    $resp = Invoke-WebRequest -Uri 'https://api.nuget.org/v3/index.json' -TimeoutSec 10 -UseBasicParsing
    Write-Host "       nuget.org reachable (HTTP $($resp.StatusCode))"
} catch {
    throw "       Cannot reach https://api.nuget.org from VM: $($_.Exception.Message). Check NSG/firewall outbound rules."
}

& $DotnetExe publish $ProjectPath `
    -c Release `
    -r win-x64 `
    --self-contained false `
    -o $AppDir `
    --nologo `
    -p:UseAppHost=true `
    | ForEach-Object { Write-Host "       $_" }
if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed (exit $LASTEXITCODE)" }

$exe = Join-Path $AppDir 'F1.FileGenerator.exe'
if (-not (Test-Path $exe)) { throw "Published exe not found: $exe" }

# -------------------------------------------------------------------
# 2. Self-signed cert for Kestrel HTTPS
# -------------------------------------------------------------------
$certPwdFile = Join-Path $CertDir 'filegen.pwd'
if (Test-Path $CertPath) {
    Write-Host '[2/5] reusing existing cert'
    $certPwdRaw = (Get-Content $certPwdFile -Raw)
} else {
    Write-Host '[2/5] generating self-signed cert...'
    $certPwdRaw = -join ((1..32) | ForEach-Object { [char](Get-Random -Min 65 -Max 90) })
    $cert = New-SelfSignedCertificate `
        -DnsName 'filegenerator.f1demo.local', 'localhost' `
        -CertStoreLocation 'cert:\LocalMachine\My' `
        -NotAfter (Get-Date).AddYears(5) `
        -KeyExportPolicy Exportable `
        -KeyAlgorithm RSA `
        -KeyLength 2048
    $pwdSecure = ConvertTo-SecureString $certPwdRaw -AsPlainText -Force
    Export-PfxCertificate -Cert $cert -FilePath $CertPath -Password $pwdSecure | Out-Null
    $certPwdRaw | Set-Content -Path $certPwdFile -NoNewline -Encoding ASCII
    icacls $CertDir /inheritance:r /grant:r 'SYSTEM:(OI)(CI)F' 'Administrators:(OI)(CI)F' | Out-Null
}

# -------------------------------------------------------------------
# 3. Stop old service if present
# -------------------------------------------------------------------
$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($svc) {
    Write-Host '[3a/5] stopping old service...'
    Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
    & sc.exe delete $ServiceName | Out-Null
    Start-Sleep -Seconds 2
}

# -------------------------------------------------------------------
# 4. Install service + env vars
# -------------------------------------------------------------------
Write-Host '[3b/5] installing service...'
& sc.exe create $ServiceName `
    binPath= "`"$exe`"" `
    start= auto `
    obj= LocalSystem `
    DisplayName= 'F1 FileGenerator' | Out-Null
& sc.exe description $ServiceName 'F1 SRE demo middle-tier API' | Out-Null
& sc.exe failure $ServiceName reset= 86400 actions= restart/30000/restart/30000/restart/60000 | Out-Null

[Environment]::SetEnvironmentVariable('KeyVault__Uri',                $KeyVaultUri, 'Machine')
[Environment]::SetEnvironmentVariable('Kestrel__CertificatePath',     $CertPath,    'Machine')
[Environment]::SetEnvironmentVariable('Kestrel__CertificatePassword', $certPwdRaw,  'Machine')
[Environment]::SetEnvironmentVariable('ASPNETCORE_ENVIRONMENT',       'Production', 'Machine')

# Pull the App Insights connection string from KV via the VM MI and stamp it
# as a machine env var. FileGen itself reads it via the KV config provider on
# startup, but the Python ingestion job (run via Task Scheduler / run-ingest.ps1)
# picks it up from the env so its OTel exporter knows where to send the
# f1_ingest_runs heartbeat.
try {
    $tokenJson = Invoke-RestMethod -Headers @{ Metadata = 'true' } -Uri 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net' -TimeoutSec 5
    $vaultBase = $KeyVaultUri.TrimEnd('/')
    $aiSecret = Invoke-RestMethod -Headers @{ Authorization = "Bearer $($tokenJson.access_token)" } -Uri "$vaultBase/secrets/applicationInsightsConnectionString?api-version=7.4" -TimeoutSec 10
    if ($aiSecret -and $aiSecret.value) {
        [Environment]::SetEnvironmentVariable('APPLICATIONINSIGHTS_CONNECTION_STRING', $aiSecret.value, 'Machine')
        Write-Host '       APPLICATIONINSIGHTS_CONNECTION_STRING env var set (machine scope).'
    }
} catch {
    Write-Warning "       Could not fetch AI conn string from KV via MI: $($_.Exception.Message). Ingestion will skip App Insights export."
}

New-NetFirewallRule -DisplayName 'FileGenerator 8443' -Direction Inbound -Protocol TCP -LocalPort 8443 -Action Allow -ErrorAction SilentlyContinue | Out-Null

# -------------------------------------------------------------------
# 5. Start + smoke test
# -------------------------------------------------------------------
Write-Host '[4/5] starting service...'
Start-Service -Name $ServiceName

Start-Sleep -Seconds 8
$svc = Get-Service -Name $ServiceName
Write-Host "       service status: $($svc.Status)"

Write-Host '[5/5] smoke testing /health...'
try {
    Add-Type -TypeDefinition @"
using System.Net;
public static class TrustAll {
    public static void Init() {
        ServicePointManager.ServerCertificateValidationCallback = (s,c,ch,e) => true;
    }
}
"@ -ErrorAction SilentlyContinue
    [TrustAll]::Init()
    $r = Invoke-RestMethod -Uri 'https://localhost:8443/health' -TimeoutSec 15
    Write-Host '       /health response:'
    $r | ConvertTo-Json -Depth 5 | ForEach-Object { Write-Host "       $_" }
} catch {
    Write-Warning "       /health probe failed: $($_.Exception.Message)"
    Write-Host '       service log tail:'
    Get-ChildItem $LogDir -Filter 'filegen-*.log' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Desc | Select-Object -First 1 |
        Get-Content -Tail 30 |
        ForEach-Object { Write-Host "       $_" }
}

Write-Host 'finish-deploy.ps1 done.'
