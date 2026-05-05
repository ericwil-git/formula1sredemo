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
# -------------------------------------------------------------------
# SQL Server 2022 Developer Edition — direct download + unattended install.
# Choco's `--params` quoting is unreliable across pwsh/cmd boundaries (it
# tokenizes "NT AUTHORITY\NETWORK SERVICE" as separate package names). We
# download the SQL bootstrapper, fetch the full media, then run setup.exe
# with a configuration file written to disk.
# -------------------------------------------------------------------
if (-not (Get-Service -Name MSSQLSERVER -ErrorAction SilentlyContinue)) {
    Write-Host 'Installing SQL Server 2022 Developer Edition (this can take 10-15 min)...'

    $sqlBootstrapper = 'D:\f1demo\SQL2022-SSEI-Dev.exe'
    $sqlMediaDir     = 'D:\f1demo\sqlmedia'
    $sqlExtractDir   = 'D:\f1demo\sqlextract'
    $sqlConfigFile   = 'D:\f1demo\sqlconfig.ini'

    if (-not (Test-Path $sqlBootstrapper)) {
        Write-Host '  downloading SSEI Developer bootstrapper...'
        Invoke-WebRequest -Uri 'https://go.microsoft.com/fwlink/?linkid=2215158' `
            -OutFile $sqlBootstrapper -UseBasicParsing
    }

    # Download full ISO/box media (no extraction yet)
    if (-not (Test-Path "$sqlMediaDir\SQLServer2022-x64-ENU-Dev.iso")) {
        Write-Host '  downloading SQL Server 2022 install media (~1.5 GB)...'
        New-Item -ItemType Directory -Force -Path $sqlMediaDir | Out-Null
        $p = Start-Process -FilePath $sqlBootstrapper `
            -ArgumentList @('/Action=Download', "/MediaPath=$sqlMediaDir", '/MediaType=ISO', '/Quiet') `
            -Wait -PassThru -NoNewWindow
        if ($p.ExitCode -ne 0) {
            throw "SSEI download failed with exit code $($p.ExitCode)"
        }
    }

    # Mount the ISO and extract setup.exe + payload
    if (-not (Test-Path "$sqlExtractDir\setup.exe")) {
        Write-Host '  mounting ISO + copying media...'
        $iso = Get-ChildItem "$sqlMediaDir\*.iso" | Select-Object -First 1
        $mount = Mount-DiskImage -ImagePath $iso.FullName -PassThru
        Start-Sleep -Seconds 2
        $vol = (Get-Volume -DiskImage $mount).DriveLetter
        New-Item -ItemType Directory -Force -Path $sqlExtractDir | Out-Null
        Copy-Item -Path "${vol}:\*" -Destination $sqlExtractDir -Recurse -Force
        Dismount-DiskImage -ImagePath $iso.FullName | Out-Null
    }

    # Build a setup ConfigurationFile.ini — values with spaces are quoted.
    $configIni = @"
[OPTIONS]
ACTION="Install"
QUIET="True"
QUIETSIMPLE="False"
IACCEPTSQLSERVERLICENSETERMS="True"
ENU="True"
UpdateEnabled="False"
SUPPRESSPRIVACYSTATEMENTNOTICE="True"
FEATURES=SQLENGINE
INSTANCENAME="MSSQLSERVER"
INSTANCEID="MSSQLSERVER"
SQLSVCACCOUNT="NT AUTHORITY\NETWORK SERVICE"
SQLSVCSTARTUPTYPE="Automatic"
AGTSVCACCOUNT="NT AUTHORITY\NETWORK SERVICE"
AGTSVCSTARTUPTYPE="Disabled"
SECURITYMODE="SQL"
SAPWD="$SqlSaPassword"
SQLSYSADMINACCOUNTS="BUILTIN\Administrators"
TCPENABLED="1"
NPENABLED="0"
INSTALLSQLDATADIR="D:\sqldata"
SQLBACKUPDIR="D:\sqldata\backup"
SQLUSERDBDIR="D:\sqldata\data"
SQLUSERDBLOGDIR="D:\sqldata\log"
SQLTEMPDBDIR="D:\sqldata\tempdb"
"@
    New-Item -ItemType Directory -Force -Path 'D:\sqldata\backup','D:\sqldata\data','D:\sqldata\log','D:\sqldata\tempdb' | Out-Null
    Set-Content -Path $sqlConfigFile -Value $configIni -Encoding ASCII

    Write-Host '  running setup.exe (5-15 min)...'
    $p = Start-Process -FilePath "$sqlExtractDir\setup.exe" `
        -ArgumentList @("/ConfigurationFile=$sqlConfigFile", '/IAcceptSQLServerLicenseTerms') `
        -Wait -PassThru -NoNewWindow
    if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) {
        throw "SQL Server setup failed with exit code $($p.ExitCode). See C:\Program Files\Microsoft SQL Server\160\Setup Bootstrap\Log\Summary.txt"
    }
    Write-Host "  setup.exe exit code: $($p.ExitCode) (3010 = success, reboot pending)"
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
