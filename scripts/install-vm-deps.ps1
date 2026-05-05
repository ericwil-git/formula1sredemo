<#
.SYNOPSIS
    Bootstrap the demo VM: Python 3.11, .NET 8 hosting bundle, ODBC Driver 18,
    windows_exporter, SQL Server 2022 Developer Edition (local data tier),
    SqlServer PowerShell module, and demo data folders.

.DESCRIPTION
    Designed to be invoked once via `az vm run-command invoke` after the VM is
    provisioned. Idempotent — re-runs are safe.

.PARAMETER SqlSaPassword
    sa password for the local SQL Server install. Pull from Key Vault before
    invoking, or pass via -SqlSaPassword on the command line.
#>

[CmdletBinding()]
param(
    [string] $PythonVersion         = '3.11.9',
    [string] $WindowsExporterVersion = '0.30.5',
    [Parameter(Mandatory = $true)]
    [string] $SqlSaPassword
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProgressPreference   = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# -------------------------------------------------------------------
# Folders
# -------------------------------------------------------------------
'D:\f1demo','D:\f1-files','D:\f1-files\logs','D:\fastf1-cache','D:\sqldata' | ForEach-Object {
    New-Item -ItemType Directory -Force -Path $_ | Out-Null
}

# -------------------------------------------------------------------
# Chocolatey (used as a one-shot package source for everything else)
# -------------------------------------------------------------------
if (-not (Get-Command choco.exe -ErrorAction SilentlyContinue)) {
    Write-Host 'Installing Chocolatey...'
    Set-ExecutionPolicy Bypass -Scope Process -Force
    Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
    $env:Path += ';C:\ProgramData\chocolatey\bin'
}

# -------------------------------------------------------------------
# Python 3.11, .NET 8 Hosting Bundle, ODBC Driver 18
# -------------------------------------------------------------------
choco install python --version=$PythonVersion -y --no-progress
choco install dotnet-8.0-windowshosting -y --no-progress
choco install sqlserver-odbcdriver -y --no-progress

# -------------------------------------------------------------------
# SQL Server 2022 Developer Edition (free, full-featured, no licensing).
# Choco installs the engine; we then enable mixed-mode auth, set the sa
# password, enable TCP on 1433, and start the service.
# -------------------------------------------------------------------
if (-not (Get-Service -Name MSSQLSERVER -ErrorAction SilentlyContinue)) {
    Write-Host 'Installing SQL Server 2022 Developer Edition (this can take 10-15 min)...'
    choco install sql-server-2022 --params="'/IgnorePendingReboot /SECURITYMODE=SQL /SAPWD=$SqlSaPassword /TCPENABLED=1 /SQLSVCACCOUNT=`"NT AUTHORITY\NETWORK SERVICE`" /SQLSYSADMINACCOUNTS=`"BUILTIN\Administrators`" /AGTSVCACCOUNT=`"NT AUTHORITY\NETWORK SERVICE`"'" -y --no-progress
}

# Ensure mixed-mode auth + sa enabled (idempotent in case the install above
# was already done previously).
$loginMode = 2  # 2 = mixed mode
$regPath = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL16.MSSQLSERVER\MSSQLServer'
if (Test-Path $regPath) {
    Set-ItemProperty -Path $regPath -Name LoginMode -Value $loginMode -Type DWord
}

# Enable TCP/IP on default instance port 1433.
$smoAssembly = [System.Reflection.Assembly]::LoadWithPartialName('Microsoft.SqlServer.SqlWmiManagement') 2>$null
if ($smoAssembly) {
    try {
        $wmi = New-Object 'Microsoft.SqlServer.Management.Smo.Wmi.ManagedComputer'
        $tcp = $wmi.ServerInstances['MSSQLSERVER'].ServerProtocols['Tcp']
        if ($tcp -and -not $tcp.IsEnabled) {
            $tcp.IsEnabled = $true
            $tcp.Alter()
        }
    } catch {
        Write-Warning "Could not enable TCP via SMO: $_"
    }
}

# Open SQL port + restart service so all changes apply.
New-NetFirewallRule -DisplayName 'SQL Server 1433' -Direction Inbound -Protocol TCP -LocalPort 1433 -Action Allow -ErrorAction SilentlyContinue | Out-Null
Restart-Service -Name MSSQLSERVER -Force -ErrorAction SilentlyContinue

# -------------------------------------------------------------------
# SqlServer PowerShell module (for Invoke-Sqlcmd in subsequent steps).
# -------------------------------------------------------------------
if (-not (Get-Module -ListAvailable -Name SqlServer)) {
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
    Install-Module SqlServer -Scope AllUsers -Force -AllowClobber
}
Import-Module SqlServer

# -------------------------------------------------------------------
# Apply the demo schema to a fresh f1demo database.
# -------------------------------------------------------------------
$schemaPath = 'D:\f1demo\schema.sql'
if (-not (Test-Path $schemaPath)) {
    Invoke-WebRequest `
        -Uri 'https://raw.githubusercontent.com/ericwil-git/formula1sredemo/main/db/schema.sql' `
        -OutFile $schemaPath -UseBasicParsing
}

$saSecure = ConvertTo-SecureString $SqlSaPassword -AsPlainText -Force
$saCred   = New-Object System.Management.Automation.PSCredential('sa', $saSecure)

# Wait up to 60s for SQL to be ready post-restart.
for ($i = 0; $i -lt 12; $i++) {
    try {
        Invoke-Sqlcmd -ServerInstance 'localhost' -Database master -Credential $saCred -TrustServerCertificate `
            -Query 'SELECT 1' -ErrorAction Stop | Out-Null
        break
    } catch {
        Start-Sleep -Seconds 5
    }
}

Invoke-Sqlcmd -ServerInstance 'localhost' -Database master -Credential $saCred -TrustServerCertificate `
    -InputFile $schemaPath

Write-Host 'Schema applied.'

# -------------------------------------------------------------------
# windows_exporter (Prometheus exporter for Windows)
# -------------------------------------------------------------------
$wexUrl  = "https://github.com/prometheus-community/windows_exporter/releases/download/v$WindowsExporterVersion/windows_exporter-$WindowsExporterVersion-amd64.msi"
$wexMsi  = Join-Path $env:TEMP "windows_exporter.msi"
if (-not (Get-Service -Name windows_exporter -ErrorAction SilentlyContinue)) {
    Write-Host "Downloading windows_exporter from $wexUrl"
    Invoke-WebRequest -Uri $wexUrl -OutFile $wexMsi -UseBasicParsing
    Start-Process msiexec.exe `
        -ArgumentList "/i `"$wexMsi`" /qn ENABLED_COLLECTORS=cpu,cs,logical_disk,net,os,system,memory,process,mssql LISTEN_PORT=9182" `
        -Wait
}

# Firewall rules. Bound to VNet via NSG so 0.0.0.0 here is safe.
New-NetFirewallRule -DisplayName 'windows_exporter 9182' -Direction Inbound -Protocol TCP -LocalPort 9182 -Action Allow -ErrorAction SilentlyContinue | Out-Null
New-NetFirewallRule -DisplayName 'FileGenerator 8443'   -Direction Inbound -Protocol TCP -LocalPort 8443 -Action Allow -ErrorAction SilentlyContinue | Out-Null
New-NetFirewallRule -DisplayName 'F1 Ingest /metrics 9101' -Direction Inbound -Protocol TCP -LocalPort 9101 -Action Allow -ErrorAction SilentlyContinue | Out-Null

# -------------------------------------------------------------------
# pip install the ingestion package (apps.yml copies it to D:\f1demo\ingestion)
# -------------------------------------------------------------------
$ingestionPath = 'D:\f1demo\ingestion'
if (Test-Path (Join-Path $ingestionPath 'pyproject.toml')) {
    py -3.11 -m pip install --upgrade pip
    py -3.11 -m pip install -e $ingestionPath
}

Write-Host 'install-vm-deps.ps1 finished.'
