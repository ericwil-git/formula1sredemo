#!/usr/bin/env bash
# =============================================================================
# schedule-traffic.sh — install + schedule a one-shot Windows Task on the
# demo VM that runs vm-traffic-loop.ps1 at a future UTC time and stops itself
# after $DURATION_MINUTES.
#
# Usage:
#   scripts/schedule-traffic.sh \
#       --start-utc 2026-05-08T13:00:00Z \
#       --duration-minutes 180 \
#       [--rps 1] [--users 4] [--task-name F1DemoTraffic]
#
# Convenience: prints "X EDT/PST/etc" interpretation of the UTC time so
# you can sanity-check before running.
#
# What this script does:
#   1. Uploads scripts/vm/vm-traffic-loop.ps1 to D:\f1demo\traffic\ on the
#      VM (via az vm run-command + Invoke-WebRequest from the public repo).
#   2. Registers a Windows Scheduled Task named --task-name that:
#        * triggers ONCE at --start-utc
#        * runs as SYSTEM (no user logon needed)
#        * invokes powershell.exe -File <path> with the configured args
#        * has its own execution time-limit slightly longer than --duration-minutes
#   3. Echoes a verification block so you can confirm the trigger time
#      lines up with what you intended.
#
# To cancel: scripts/schedule-traffic.sh --cancel  [--task-name F1DemoTraffic]
# To check:  scripts/schedule-traffic.sh --status  [--task-name F1DemoTraffic]
# =============================================================================
set -euo pipefail

RG=rg-f1demo-centeral
VM=vm-f1demo-win

# ---- defaults ---------------------------------------------------------------
START_UTC=""
DURATION_MIN=180
RPS=1
USERS=4
TASK_NAME="F1DemoTraffic"
ACTION="install"

# ---- parse args -------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --start-utc)         START_UTC="$2"; shift 2;;
        --duration-minutes)  DURATION_MIN="$2"; shift 2;;
        --rps)               RPS="$2"; shift 2;;
        --users)             USERS="$2"; shift 2;;
        --task-name)         TASK_NAME="$2"; shift 2;;
        --cancel)            ACTION="cancel"; shift;;
        --status)            ACTION="status"; shift;;
        -h|--help)
            sed -n '2,30p' "$0"; exit 0;;
        *)
            echo "unknown option: $1" >&2; exit 1;;
    esac
done

# ---- helpers ----------------------------------------------------------------
to_local() {
    # macOS BSD date: convert UTC ISO -> local TZ string
    date -j -f "%Y-%m-%dT%H:%M:%SZ" "$1" "+%Y-%m-%d %H:%M:%S %Z"
}

# ---- cancel -----------------------------------------------------------------
if [[ "$ACTION" == "cancel" ]]; then
    echo "[cancel] removing scheduled task '$TASK_NAME' on $VM ..."
    cat > /tmp/cancel-task.ps1 <<EOF
\$task = Get-ScheduledTask -TaskName '$TASK_NAME' -EA SilentlyContinue
if (\$task) {
    Stop-ScheduledTask -TaskName '$TASK_NAME' -EA SilentlyContinue
    Unregister-ScheduledTask -TaskName '$TASK_NAME' -Confirm:\$false
    Write-Output "Task '$TASK_NAME' removed."
} else {
    Write-Output "Task '$TASK_NAME' not found."
}
EOF
    az vm run-command invoke -g "$RG" -n "$VM" \
        --command-id RunPowerShellScript \
        --scripts @/tmp/cancel-task.ps1 \
        --query "value[].message" -o tsv
    exit 0
fi

# ---- status -----------------------------------------------------------------
if [[ "$ACTION" == "status" ]]; then
    echo "[status] inspecting scheduled task '$TASK_NAME' on $VM ..."
    cat > /tmp/status-task.ps1 <<EOF
\$task = Get-ScheduledTask -TaskName '$TASK_NAME' -EA SilentlyContinue
if (-not \$task) { Write-Output "Task '$TASK_NAME' not found."; exit 0 }
\$info = \$task | Get-ScheduledTaskInfo
Write-Output "Task:          $TASK_NAME"
Write-Output "State:         \$(\$task.State)"
Write-Output "LastRunTime:   \$(\$info.LastRunTime)"
Write-Output "LastResult:    \$(\$info.LastTaskResult)"
Write-Output "NextRunTime:   \$(\$info.NextRunTime)  [VM local = UTC]"
Write-Output "---"
Write-Output "Recent log files (last 5):"
Get-ChildItem 'D:\f1demo\traffic\logs' -Filter 'traffic-*.log' -EA SilentlyContinue |
    Sort-Object LastWriteTime -Desc | Select-Object -First 5 |
    ForEach-Object { Write-Output ("  {0}  {1,8} bytes" -f \$_.FullName, \$_.Length) }
\$latest = Get-ChildItem 'D:\f1demo\traffic\logs' -Filter 'traffic-*.log' -EA SilentlyContinue |
    Sort-Object LastWriteTime -Desc | Select-Object -First 1
if (\$latest) {
    Write-Output "---"
    Write-Output "Tail of latest log:"
    Get-Content \$latest.FullName -Tail 10 | ForEach-Object { Write-Output "  \$_" }
}
EOF
    az vm run-command invoke -g "$RG" -n "$VM" \
        --command-id RunPowerShellScript \
        --scripts @/tmp/status-task.ps1 \
        --query "value[].message" -o tsv
    exit 0
fi

# ---- install ----------------------------------------------------------------
if [[ -z "$START_UTC" ]]; then
    echo "ERROR: --start-utc is required for install." >&2
    echo "Example: $0 --start-utc 2026-05-08T13:00:00Z --duration-minutes 180" >&2
    exit 1
fi

# Sanity-check: refuse to schedule in the past.
NOW_UTC=$(date -u +%s)
START_UTC_EPOCH=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$START_UTC" +%s 2>/dev/null) || {
    echo "ERROR: --start-utc must be ISO-8601 like 2026-05-08T13:00:00Z" >&2; exit 1; }
if (( START_UTC_EPOCH <= NOW_UTC + 60 )); then
    echo "ERROR: --start-utc is in the past (or less than 60s away)." >&2
    echo "       now:    $(date -u +%Y-%m-%dT%H:%M:%SZ)" >&2
    echo "       start:  $START_UTC" >&2
    exit 1
fi

# Task time-limit slightly longer than the loop, so SCM doesn't kill it early.
TIMELIMIT_MIN=$((DURATION_MIN + 30))

cat <<EOF
[install] scheduling traffic task on $VM
  TaskName:          $TASK_NAME
  Start (UTC):       $START_UTC
  Start (your TZ):   $(to_local "$START_UTC")
  Duration:          ${DURATION_MIN}m  (~$(awk -v d=$DURATION_MIN 'BEGIN{printf "%.1f", d/60}')h)
  Target rate:       $RPS req/s across $USERS users
  Per-hit logs:      D:\\f1demo\\traffic\\logs\\traffic-<UTC>.log on the VM
EOF

cat > /tmp/install-traffic-task.ps1 <<EOF
param(
    [string] \$StartUtc        = '$START_UTC',
    [int]    \$DurationMinutes = $DURATION_MIN,
    [double] \$Rps             = $RPS,
    [int]    \$Users           = $USERS,
    [int]    \$TimeLimitMin    = $TIMELIMIT_MIN,
    [string] \$TaskName        = '$TASK_NAME'
)
\$ErrorActionPreference = 'Stop'
\$ProgressPreference   = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

\$ScriptDir = 'D:\f1demo\traffic'
New-Item -ItemType Directory -Force -Path \$ScriptDir | Out-Null
New-Item -ItemType Directory -Force -Path "\$ScriptDir\logs" | Out-Null

# 1. Pull the latest vm-traffic-loop.ps1 from main.
\$src = 'https://raw.githubusercontent.com/ericwil-git/formula1sredemo/main/scripts/vm/vm-traffic-loop.ps1'
\$dst = Join-Path \$ScriptDir 'vm-traffic-loop.ps1'
Invoke-WebRequest -Uri \$src -OutFile \$dst -UseBasicParsing
Write-Output ("[1/3] downloaded {0} ({1} bytes)" -f \$dst, (Get-Item \$dst).Length)

# 2. Compute the trigger datetime. VM is UTC, so just parse the ISO string.
\$trigger = New-ScheduledTaskTrigger -Once -At ([datetime]::Parse(\$StartUtc).ToUniversalTime())

# 3. Build the action: invoke vm-traffic-loop.ps1 with our parameters.
#    The script path has no spaces (D:\f1demo\traffic\vm-traffic-loop.ps1)
#    so no quoting is needed -- which avoids the bash-heredoc-escapes-
#    PowerShell-quotes-escapes nightmare.
\$cmdArgs = "-NoProfile -ExecutionPolicy Bypass -File \$dst -DurationMinutes \$DurationMinutes -TargetRps \$Rps -UserCount \$Users"
\$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument \$cmdArgs

# 4. Settings: no-battery flags are no-ops on a VM but harmless. Hard
#    ExecutionTimeLimit so a hung loop can't run forever.
\$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes \$TimeLimitMin) -MultipleInstances IgnoreNew

# 5. Run as SYSTEM, highest privileges. Re-register overwrites.
\$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest -LogonType ServiceAccount

Register-ScheduledTask -TaskName \$TaskName -Trigger \$trigger -Action \$action -Settings \$settings -Principal \$principal -Force | Out-Null

# 6. Echo final state.
\$task = Get-ScheduledTask -TaskName \$TaskName
\$info = \$task | Get-ScheduledTaskInfo
Write-Output ("[2/3] registered task {0}" -f \$TaskName)
Write-Output ("[3/3] next run (UTC):   {0}" -f \$info.NextRunTime)
EOF

az vm run-command invoke -g "$RG" -n "$VM" \
    --command-id RunPowerShellScript \
    --scripts @/tmp/install-traffic-task.ps1 \
    --query "value[].message" -o tsv

cat <<EOF

[install] done.
Verify with:   $0 --status
Cancel with:   $0 --cancel
EOF
