<#
.SYNOPSIS
    Deploy F1.FileGenerator on the VM as a Windows service.

.DESCRIPTION
    1. Ensures git + .NET 8 SDK are installed (via Chocolatey).
    2. Clones (or `git pull`s) the repo to D:\f1demo\repo.
    3. Publishes FileGenerator (Release, framework-dependent, win-x64) to
       D:\f1demo\filegenerator.
    4. Generates a self-signed PFX for Kestrel HTTPS at D:\f1demo\certs\filegen.pfx.
    5. Installs / replaces a Windows service "F1FileGenerator" running as
       LocalSystem (so it can use the VM's managed identity for KV access).
    6. Sets env vars on the service:
         KeyVault__Uri                — for the KV config provider
         Kestrel__CertificatePath     — PFX for HTTPS
         Kestrel__CertificatePassword — random per install
         ASPNETCORE_ENVIRONMENT       — Production
    7. Starts the service.

    Runs idempotently — re-invoking re-pulls and restarts.

.PARAMETER KeyVaultUri
    Full vault URI, e.g. https://kv-f1demo-wr4dcd.vault.azure.net/

.PARAMETER GitRepo
    HTTPS clone URL.

.PARAMETER GitBranch
    Branch to deploy. Default 'main'.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $KeyVaultUri,
    [string] $GitRepo   = 'https://github.com/ericwil-git/formula1sredemo.git',
    [string] $GitBranch = 'main'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference   = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ServiceName     = 'F1FileGenerator'
$AppDir          = 'D:\f1demo\filegenerator'
$RepoDir         = 'D:\f1demo\repo'
$CertDir         = 'D:\f1demo\certs'
$CertPath        = Join-Path $CertDir 'filegen.pfx'
$LogDir          = 'D:\f1-files\logs'
$ProjectRelative = 'src\filegenerator\FileGenerator.csproj'

New-Item -ItemType Directory -Force -Path $CertDir, $LogDir | Out-Null

# -------------------------------------------------------------------
# 1. Tooling: git + .NET 8 SDK
# -------------------------------------------------------------------
if (-not (Get-Command choco.exe -ErrorAction SilentlyContinue)) {
    throw 'Chocolatey is missing. Run install-vm-deps.ps1 first.'
}

if (-not (Get-Command git.exe -ErrorAction SilentlyContinue)) {
    Write-Host '[1/7] installing git...'
    choco install git -y --no-progress | Out-Null
    $env:Path += ';C:\Program Files\Git\cmd'
}

# .NET 8 SDK is needed to publish; the runtime is already installed by
# install-vm-deps.ps1. The SDK is ~700 MB; install once.
if (-not (& dotnet --list-sdks 2>$null | Select-String -SimpleMatch '8.')) {
    Write-Host '[1/7] installing .NET 8 SDK...'
    choco install dotnet-8.0-sdk -y --no-progress | Out-Null
    $env:Path += ';C:\Program Files\dotnet'
}
& dotnet --version | ForEach-Object { Write-Host "        SDK: $_" }

# -------------------------------------------------------------------
# 2. Clone / pull
# -------------------------------------------------------------------
Write-Host '[2/7] sync repo...'
if (Test-Path (Join-Path $RepoDir '.git')) {
    Push-Location $RepoDir
    & git fetch --all --quiet
    & git checkout $GitBranch --quiet
    & git reset --hard "origin/$GitBranch"
    Pop-Location
} else {
    & git clone --branch $GitBranch --depth 1 $GitRepo $RepoDir
}

# -------------------------------------------------------------------
# 3. Publish
# -------------------------------------------------------------------
Write-Host '[3/7] dotnet publish...'
$projectPath = Join-Path $RepoDir $ProjectRelative
& dotnet publish $projectPath `
    -c Release `
    -r win-x64 `
    --self-contained false `
    -o $AppDir `
    --nologo `
    -p:UseAppHost=true `
    | Out-String | ForEach-Object { Write-Host $_ }
if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed (exit $LASTEXITCODE)" }

# -------------------------------------------------------------------
# 4. Self-signed cert for Kestrel HTTPS
# -------------------------------------------------------------------
$certPwdRaw = -join ((1..32) | ForEach-Object { [char](Get-Random -Min 65 -Max 90) })
if (-not (Test-Path $CertPath)) {
    Write-Host '[4/7] generating self-signed cert...'
    $cert = New-SelfSignedCertificate `
        -DnsName 'filegenerator.f1demo.local', 'localhost' `
        -CertStoreLocation 'cert:\LocalMachine\My' `
        -NotAfter (Get-Date).AddYears(5) `
        -KeyExportPolicy Exportable `
        -KeyAlgorithm RSA `
        -KeyLength 2048
    $pwdSecure = ConvertTo-SecureString $certPwdRaw -AsPlainText -Force
    Export-PfxCertificate -Cert $cert -FilePath $CertPath -Password $pwdSecure | Out-Null
    # Persist the matching password next to the cert (root-readable only).
    $certPwdRaw | Set-Content -Path (Join-Path $CertDir 'filegen.pwd') -NoNewline -Encoding ASCII
    icacls $CertDir /inheritance:r /grant:r 'SYSTEM:(OI)(CI)F' 'Administrators:(OI)(CI)F' | Out-Null
} else {
    Write-Host '[4/7] reusing existing cert'
    $certPwdRaw = (Get-Content (Join-Path $CertDir 'filegen.pwd') -Raw)
}

# -------------------------------------------------------------------
# 5. Stop old service if present
# -------------------------------------------------------------------
$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($svc) {
    Write-Host '[5/7] stopping old service...'
    Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
    & sc.exe delete $ServiceName | Out-Null
    Start-Sleep -Seconds 2
}

# -------------------------------------------------------------------
# 6. Install + configure new service
# -------------------------------------------------------------------
$exe = Join-Path $AppDir 'F1.FileGenerator.exe'
if (-not (Test-Path $exe)) { throw "Published exe not found: $exe" }

Write-Host '[6/7] installing service...'
# binPath uses LocalSystem so DefaultAzureCredential -> ManagedIdentityCredential
# resolves the VM's system-assigned identity.
& sc.exe create $ServiceName `
    binPath= "`"$exe`"" `
    start= auto `
    obj= LocalSystem `
    DisplayName= 'F1 FileGenerator' | Out-Null
& sc.exe description $ServiceName 'F1 SRE demo middle-tier API' | Out-Null
# Recovery: restart on failure with a 30-second delay (reset window 1 day).
& sc.exe failure $ServiceName reset= 86400 actions= restart/30000/restart/30000/restart/60000 | Out-Null

# Service env vars. SetEnvironmentVariable with Machine target survives reboots
# AND is inherited by the service when LocalSystem starts it.
[Environment]::SetEnvironmentVariable('KeyVault__Uri',                $KeyVaultUri, 'Machine')
[Environment]::SetEnvironmentVariable('Kestrel__CertificatePath',     $CertPath,    'Machine')
[Environment]::SetEnvironmentVariable('Kestrel__CertificatePassword', $certPwdRaw,  'Machine')
[Environment]::SetEnvironmentVariable('ASPNETCORE_ENVIRONMENT',       'Production', 'Machine')

# Firewall rule (idempotent; install-vm-deps.ps1 already created it but
# re-creating is safe).
New-NetFirewallRule -DisplayName 'FileGenerator 8443' -Direction Inbound -Protocol TCP -LocalPort 8443 -Action Allow -ErrorAction SilentlyContinue | Out-Null

# -------------------------------------------------------------------
# 7. Start + smoke test
# -------------------------------------------------------------------
Write-Host '[7/7] starting service...'
Start-Service -Name $ServiceName

Start-Sleep -Seconds 8
$svc = Get-Service -Name $ServiceName
Write-Host "  service status: $($svc.Status)"

# Smoke test against /health (skips API-key middleware).
try {
    Add-Type @"
using System.Net;
using System.Net.Security;
public static class TrustAll {
    public static void Init() {
        ServicePointManager.ServerCertificateValidationCallback = (s,c,ch,e) => true;
    }
}
"@ -ErrorAction SilentlyContinue
    [TrustAll]::Init()
    $r = Invoke-RestMethod -Uri 'https://localhost:8443/health' -TimeoutSec 10
    Write-Host '  /health response:'
    $r | ConvertTo-Json -Depth 5
} catch {
    Write-Warning "  /health probe failed: $($_.Exception.Message)"
    Write-Host '  service log tail:'
    Get-ChildItem $LogDir -Filter 'filegen-*.log' | Sort-Object LastWriteTime -Desc | Select-Object -First 1 |
        Get-Content -Tail 30
}

Write-Host 'deploy-filegenerator.ps1 finished.'
