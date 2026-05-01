<#
.SYNOPSIS
    Run the F1 ingestion service against a year/event set.

.DESCRIPTION
    Wraps the f1-ingest CLI installed by `pip install -e .` from the
    /src/ingestion folder. Designed to be invoked from the Windows Task
    Scheduler on the demo VM.

.EXAMPLE
    .\run-ingest.ps1 -Year 2024 -Events all -Telemetry $true
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [int]    $Year,
    [Parameter()]                  [string] $Events    = 'all',
    [Parameter()]                  [bool]   $Telemetry = $true,
    [Parameter()]                  [string] $CacheDir  = 'D:\fastf1-cache',
    [Parameter()]                  [string] $LogDir    = 'D:\f1-files\logs'
)

$ErrorActionPreference = 'Stop'

if (-not $env:F1_SQL_CONNECTION_STRING) {
    throw 'Set $env:F1_SQL_CONNECTION_STRING before running. (Pull it from Key Vault using az keyvault secret show.)'
}

New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null
New-Item -ItemType Directory -Force -Path $LogDir   | Out-Null

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$logPath   = Join-Path $LogDir "ingest-$timestamp.log"

Write-Host "Ingesting year=$Year events=$Events telemetry=$Telemetry"
Write-Host "Logging to $logPath"

& f1-ingest `
    --year $Year `
    --events $Events `
    --telemetry $Telemetry `
    --cache-dir $CacheDir 2>&1 |
    Tee-Object -FilePath $logPath

exit $LASTEXITCODE
