<#
.SYNOPSIS
    Deploy F1.FileGenerator on the VM as a Windows service.

.DESCRIPTION
    Self-contained: downloads .NET 8 SDK (user-local) and PortableGit if not
    already present (no admin elevation, no Chocolatey dependency). Then:

    1. git clone / pull the repo to D:\f1demo\repo.
    2. dotnet publish to D:\f1demo\filegenerator (framework-dependent).
    3. Generate a self-signed PFX at D:\f1demo\certs\filegen.pfx.
    4. Install/replace Windows service "F1FileGenerator" running as
       LocalSystem (so DefaultAzureCredential resolves the VM's MI for KV).
    5. Set machine env vars consumed by the service:
         KeyVault__Uri, Kestrel__CertificatePath, Kestrel__CertificatePassword,
         ASPNETCORE_ENVIRONMENT.
    6. Start the service and smoke test https://localhost:8443/health.

    Idempotent: re-running pulls latest main and restarts.

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

$ServiceName = 'F1FileGenerator'
$RootDir     = 'D:\f1demo'
$ToolsDir    = Join-Path $RootDir 'tools'
$DotnetDir   = Join-Path $ToolsDir 'dotnet'
$GitDir      = Join-Path $ToolsDir 'git'
$AppDir      = Join-Path $RootDir 'filegenerator'
$RepoDir     = Join-Path $RootDir 'repo'
$CertDir     = Join-Path $RootDir 'certs'
$CertPath    = Join-Path $CertDir 'filegen.pfx'
$LogDir      = 'D:\f1-files\logs'
$ProjectRel  = 'src\filegenerator\FileGenerator.csproj'

New-Item -ItemType Directory -Force -Path $ToolsDir, $CertDir, $LogDir | Out-Null

# -------------------------------------------------------------------
# 1a. .NET 8 SDK (user-local via dotnet-install.ps1, no admin needed)
# -------------------------------------------------------------------
$dotnetExe = Join-Path $DotnetDir 'dotnet.exe'
if (-not (Test-Path $dotnetExe)) {
    Write-Host '[1/7] downloading dotnet-install.ps1...'
    $script = Join-Path $env:TEMP 'dotnet-install.ps1'
    Invoke-WebRequest -Uri 'https://dot.net/v1/dotnet-install.ps1' -OutFile $script -UseBasicParsing
    Write-Host '       installing .NET 8 SDK to D:\f1demo\tools\dotnet (~5 min)...'
    & $script -Channel 8.0 -InstallDir $DotnetDir -NoPath | Out-Null
}
if (-not (Test-Path $dotnetExe)) { throw 'dotnet SDK install failed.' }
& $dotnetExe --version | ForEach-Object { Write-Host "       SDK: $_" }

# -------------------------------------------------------------------
# 1b. PortableGit (no admin)
# -------------------------------------------------------------------
$gitExe = Join-Path $GitDir 'cmd\git.exe'
if (-not (Test-Path $gitExe)) {
    Write-Host '[2/7] downloading PortableGit (~50 MB)...'
    $url = 'https://github.com/git-for-windows/git/releases/download/v2.45.2.windows.1/PortableGit-2.45.2-64-bit.7z.exe'
    $tmp = Join-Path $env:TEMP 'PortableGit.7z.exe'
    Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing
    Write-Host '       extracting...'
    if (Test-Path $GitDir) { Remove-Item $GitDir -Recurse -Force }
    & $tmp -y -o"$GitDir" -gm2 | Out-Null
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
}
if (-not (Test-Path $gitExe)) { throw 'PortableGit install failed.' }

# -------------------------------------------------------------------
# 2. Clone / pull
# -------------------------------------------------------------------
Write-Host '[3/7] sync repo...'
if (Test-Path (Join-Path $RepoDir '.git')) {
    Push-Location $RepoDir
    & $gitExe fetch --all --quiet
    & $gitExe checkout $GitBranch --quiet
    & $gitExe reset --hard "origin/$GitBranch"
    Pop-Location
} else {
    & $gitExe clone --branch $GitBranch --depth 1 $GitRepo $RepoDir
}
if (-not (Test-Path (Join-Path $RepoDir '.git'))) { throw 'git clone/pull failed.' }

# -------------------------------------------------------------------
# 3. Publish
# -------------------------------------------------------------------
Write-Host '[4/7] dotnet publish (~3-5 min on first run)...'
$projectPath = Join-Path $RepoDir $ProjectRel
& $dotnetExe publish $projectPath `
    -c Release `
    -r win-x64 `
    --self-contained false `
    -o $AppDir `
    --nologo `
    -p:UseAppHost=true `
    | ForEach-Object { Write-Host "       $_" }
if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed (exit $LASTEXITCODE)" }

# -------------------------------------------------------------------
# 4. Self-signed cert for Kestrel HTTPS
# -------------------------------------------------------------------
$certPwdRaw = -join ((1..32) | ForEach-Object { [char](Get-Random -Min 65 -Max 90) })
if (-not (Test-Path $CertPath)) {
    Write-Host '[5/7] generating self-signed cert...'
    $cert = New-SelfSignedCertificate `
        -DnsName 'filegenerator.f1demo.local', 'localhost' `
        -CertStoreLocation 'cert:\LocalMachine\My' `
        -NotAfter (Get-Date).AddYears(5) `
        -KeyExportPolicy Exportable `
        -KeyAlgorithm RSA `
        -KeyLength 2048
    $pwdSecure = ConvertTo-SecureString $certPwdRaw -AsPlainText -Force
    Export-PfxCertificate -Cert $cert -FilePath $CertPath -Password $pwdSecure | Out-Null
    $certPwdRaw | Set-Content -Path (Join-Path $CertDir 'filegen.pwd') -NoNewline -Encoding ASCII
    icacls $CertDir /inheritance:r /grant:r 'SYSTEM:(OI)(CI)F' 'Administrators:(OI)(CI)F' | Out-Null
} else {
    Write-Host '[5/7] reusing existing cert'
    $certPwdRaw = (Get-Content (Join-Path $CertDir 'filegen.pwd') -Raw)
}

# -------------------------------------------------------------------
# 5. Stop old service if present
# -------------------------------------------------------------------
$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($svc) {
    Write-Host '[6a/7] stopping old service...'
    Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
    & sc.exe delete $ServiceName | Out-Null
    Start-Sleep -Seconds 2
}

# -------------------------------------------------------------------
# 6. Install + configure new service
# -------------------------------------------------------------------
$exe = Join-Path $AppDir 'F1.FileGenerator.exe'
if (-not (Test-Path $exe)) { throw "Published exe not found: $exe" }

Write-Host '[6b/7] installing service...'
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

New-NetFirewallRule -DisplayName 'FileGenerator 8443' -Direction Inbound -Protocol TCP -LocalPort 8443 -Action Allow -ErrorAction SilentlyContinue | Out-Null

# -------------------------------------------------------------------
# 7. Start + smoke test
# -------------------------------------------------------------------
Write-Host '[7/7] starting service...'
Start-Service -Name $ServiceName

Start-Sleep -Seconds 8
$svc = Get-Service -Name $ServiceName
Write-Host "       service status: $($svc.Status)"

try {
    Add-Type @"
using System.Net;
public static class TrustAll {
    public static void Init() {
        ServicePointManager.ServerCertificateValidationCallback = (s,c,ch,e) => true;
    }
}
"@ -ErrorAction SilentlyContinue
    [TrustAll]::Init()
    $r = Invoke-RestMethod -Uri 'https://localhost:8443/health' -TimeoutSec 10
    Write-Host '       /health response:'
    $r | ConvertTo-Json -Depth 5
} catch {
    Write-Warning "       /health probe failed: $($_.Exception.Message)"
    Write-Host '       service log tail:'
    Get-ChildItem $LogDir -Filter 'filegen-*.log' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Desc | Select-Object -First 1 |
        Get-Content -Tail 30
}

Write-Host 'deploy-filegenerator.ps1 finished.'
