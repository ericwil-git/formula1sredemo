<#
.SYNOPSIS
    Bootstrap the demo VM: Python 3.11, .NET 8 hosting bundle, ODBC Driver 18,
    windows_exporter, and the demo data folders.

.DESCRIPTION
    Designed to be invoked once via `az vm run-command invoke` after the VM is
    provisioned. Idempotent — re-runs are safe.
#>

[CmdletBinding()]
param(
    [string] $PythonVersion         = '3.11.9',
    [string] $WindowsExporterVersion = '0.30.5'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# -------------------------------------------------------------------
# Folders
# -------------------------------------------------------------------
'D:\f1demo','D:\f1-files','D:\f1-files\logs','D:\fastf1-cache' | ForEach-Object {
    New-Item -ItemType Directory -Force -Path $_ | Out-Null
}

# -------------------------------------------------------------------
# Chocolatey (used as a one-shot package source for everything else)
# -------------------------------------------------------------------
if (-not (Get-Command choco.exe -ErrorAction SilentlyContinue)) {
    Write-Host 'Installing Chocolatey...'
    Set-ExecutionPolicy Bypass -Scope Process -Force
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
    Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
    $env:Path += ';C:\ProgramData\chocolatey\bin'
}

# -------------------------------------------------------------------
# Python 3.11
# -------------------------------------------------------------------
choco install python --version=$PythonVersion -y --no-progress

# -------------------------------------------------------------------
# .NET 8 Hosting Bundle (runtime + IIS module — runtime is what the
# FileGenerator self-host uses)
# -------------------------------------------------------------------
choco install dotnet-8.0-windowshosting -y --no-progress

# -------------------------------------------------------------------
# Microsoft ODBC Driver 18 for SQL Server
# -------------------------------------------------------------------
choco install sqlserver-odbcdriver -y --no-progress

# -------------------------------------------------------------------
# windows_exporter (Prometheus exporter for Windows)
# -------------------------------------------------------------------
$wexUrl  = "https://github.com/prometheus-community/windows_exporter/releases/download/v$WindowsExporterVersion/windows_exporter-$WindowsExporterVersion-amd64.msi"
$wexMsi  = Join-Path $env:TEMP "windows_exporter.msi"
Write-Host "Downloading windows_exporter from $wexUrl"
Invoke-WebRequest -Uri $wexUrl -OutFile $wexMsi -UseBasicParsing
Start-Process msiexec.exe `
    -ArgumentList "/i `"$wexMsi`" /qn ENABLED_COLLECTORS=cpu,cs,logical_disk,net,os,system,memory,process,iis LISTEN_PORT=9182" `
    -Wait

# Open inbound 9182 for Prometheus scrape and 8443 for FileGenerator (only
# from inside the VNet thanks to the NSG rule).
New-NetFirewallRule -DisplayName 'windows_exporter 9182' -Direction Inbound -Protocol TCP -LocalPort 9182 -Action Allow -ErrorAction SilentlyContinue | Out-Null
New-NetFirewallRule -DisplayName 'FileGenerator 8443' -Direction Inbound -Protocol TCP -LocalPort 8443 -Action Allow -ErrorAction SilentlyContinue | Out-Null
New-NetFirewallRule -DisplayName 'F1 Ingest /metrics 9101' -Direction Inbound -Protocol TCP -LocalPort 9101 -Action Allow -ErrorAction SilentlyContinue | Out-Null

# -------------------------------------------------------------------
# pip install the ingestion package (apps.yml will copy it to D:\f1demo\ingestion)
# -------------------------------------------------------------------
$ingestionPath = 'D:\f1demo\ingestion'
if (Test-Path (Join-Path $ingestionPath 'pyproject.toml')) {
    py -3.11 -m pip install --upgrade pip
    py -3.11 -m pip install -e $ingestionPath
}

Write-Host 'install-vm-deps.ps1 finished.'
