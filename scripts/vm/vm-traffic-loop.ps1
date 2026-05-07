# =============================================================================
# vm-traffic-loop.ps1 — synthetic browse loop, runs on the demo VM under
# Windows Task Scheduler. This is the PowerShell port of
# scripts/generate-traffic.sh (sustained mode), tailored for unattended
# execution under SYSTEM.
#
# Behavior:
#   - Loops for $DurationMinutes (default 180), then exits cleanly.
#   - Maintains $UserCount concurrent fake-user runspaces.
#   - Per-user delay = $UserCount / $TargetRps.
#   - Logs to D:\f1demo\traffic\logs\traffic-<UTC>.log so you can audit
#     after the demo (and a tail visible from RDP).
#   - Health-checks the target on startup; if it's already 5xx for 3 in
#     a row, exit immediately so we don't pollute App Insights with
#     synthetic 5xx noise during a real outage.
# =============================================================================

[CmdletBinding()]
param(
    [string] $BaseUrl         = 'https://app-f1demo-wr4dcd.azurewebsites.net',
    [int]    $DurationMinutes = 180,
    [double] $TargetRps       = 1.0,
    [int]    $UserCount       = 4,
    [string] $LogDir          = 'D:\f1demo\traffic\logs'
)

$ErrorActionPreference = 'Continue'
$ProgressPreference   = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$startUtc = (Get-Date).ToUniversalTime()
$logPath  = Join-Path $LogDir ("traffic-{0:yyyyMMdd-HHmmss}.log" -f $startUtc)

function Write-Log {
    param([string]$msg)
    $line = "{0:yyyy-MM-ddTHH:mm:ss}Z  $msg" -f (Get-Date).ToUniversalTime()
    Add-Content -Path $logPath -Value $line
}

Write-Log "starting: BaseUrl=$BaseUrl Duration=${DurationMinutes}m Rps=$TargetRps Users=$UserCount"

# ---- realistic page mix (mirrors scripts/generate-traffic.sh) ---------------
$pages = @(
    '/', '/', '/',
    '/race/2026/1', '/race/2026/2', '/race/2026/3', '/race/2026/3',
    '/qualifying/2026/1', '/qualifying/2026/3',
    '/lap-explorer', '/lap-explorer',
    '/compare'
)

# ---- pre-flight health check ------------------------------------------------
$healthFailures = 0
for ($i = 0; $i -lt 3; $i++) {
    try {
        $r = Invoke-WebRequest -Uri "$BaseUrl/" -UseBasicParsing -TimeoutSec 15
        if ([int]$r.StatusCode -ge 500) { $healthFailures++ }
    } catch {
        $healthFailures++
    }
}
if ($healthFailures -ge 3) {
    Write-Log "ABORT: target appears down (3/3 5xx or unreachable). Exiting without sending traffic."
    exit 1
}
Write-Log "health OK; commencing loop"

# ---- per-user delay ---------------------------------------------------------
$delaySeconds = [math]::Max(0.05, $UserCount / $TargetRps)
Write-Log "per-user delay: ${delaySeconds}s"

# ---- spawn $UserCount runspaces, each looping until $endUtc -----------------
$endUtc = $startUtc.AddMinutes($DurationMinutes)
$pool = [runspacefactory]::CreateRunspacePool(1, [math]::Max($UserCount, 4))
$pool.Open()
$jobs = @()

$userScript = {
    param($baseUrl, $pages, $delaySeconds, $endUtc, $logPath, $userId)

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $rng = New-Object System.Random ([Environment]::TickCount + $userId)

    while ((Get-Date).ToUniversalTime() -lt $endUtc) {
        $page = $pages[$rng.Next(0, $pages.Length)]
        $url  = "$baseUrl$page"
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $code = 0
        try {
            $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 30 `
                -UserAgent "F1SREDemo-SyntheticUser/$userId"
            $code = [int]$resp.StatusCode
        } catch {
            $code = -1
        }
        $sw.Stop()
        # Per-hit log line is intentionally terse so the file stays scannable.
        $line = "{0:yyyy-MM-ddTHH:mm:ss}Z  user=$userId  $code  $($sw.ElapsedMilliseconds)ms  $page" `
                    -f (Get-Date).ToUniversalTime()
        try { Add-Content -Path $logPath -Value $line } catch { }
        Start-Sleep -Seconds $delaySeconds
    }
}

for ($u = 1; $u -le $UserCount; $u++) {
    $ps = [powershell]::Create()
    $ps.RunspacePool = $pool
    [void]$ps.AddScript($userScript).
        AddArgument($BaseUrl).
        AddArgument($pages).
        AddArgument($delaySeconds).
        AddArgument($endUtc).
        AddArgument($logPath).
        AddArgument($u)
    $jobs += [pscustomobject]@{ Pipe = $ps; Handle = $ps.BeginInvoke() }
    Write-Log "spawned user $u"
}

# ---- wait for all users to finish -------------------------------------------
foreach ($j in $jobs) {
    try { $j.Pipe.EndInvoke($j.Handle) } catch { }
    $j.Pipe.Dispose()
}
$pool.Close(); $pool.Dispose()

$endActual = (Get-Date).ToUniversalTime()
$ranFor = ($endActual - $startUtc).TotalMinutes
Write-Log ("done. ran for {0:N1}m. log: $logPath" -f $ranFor)
