#!/usr/bin/env bash
# generate-traffic.sh — synthetic user traffic against the F1 demo web tier.
#
# Drives realistic browsing patterns so the workbook has populated charts
# and the SRE Agent has trace history to reason against. Designed for two
# modes:
#
#   1. burst         — one quick wave (~30s) to pre-warm before a demo.
#   2. sustained     — a steady background hum, configurable duration.
#
# No external dependencies beyond bash + curl. Runs from your laptop.
#
# Usage:
#   scripts/generate-traffic.sh burst
#   scripts/generate-traffic.sh sustained --minutes 30 --rps 2 --users 4
#   scripts/generate-traffic.sh sustained --forever --rps 1
#
# Stop with Ctrl-C (or `kill %1` if backgrounded with &).

set -uo pipefail

BASE_URL="${F1_DEMO_BASE_URL:-https://app-f1demo-wr4dcd.azurewebsites.net}"

# ---- realistic page mix --------------------------------------------------
# Weighted by how a real user would browse: most hits on the home page and
# a single race; lap-explorer + compare are deeper drilldowns. Telemetry
# lap-detail is rare but when it happens it spans a heavy SQL path.
PAGES=(
    "/"
    "/"
    "/"
    "/race/2026/1"
    "/race/2026/2"
    "/race/2026/3"
    "/race/2026/3"            # round 3 is the "demo round" -- weight it
    "/qualifying/2026/1"
    "/qualifying/2026/3"
    "/lap-explorer"
    "/lap-explorer"
    "/compare"
)

# Realistic driver / lap combinations for the lap-detail JSON endpoint
# (FileGen direct hit -- skips the Blazor render but exercises the SQL path).
LAP_DETAILS=(
    "year=2026&round=1&session=R&driver=VER&lap=20"
    "year=2026&round=1&session=R&driver=NOR&lap=20"
    "year=2026&round=3&session=R&driver=VER&lap=30"
    "year=2026&round=3&session=R&driver=PIA&lap=25"
    "year=2026&round=3&session=Q&driver=VER&lap=12"
)

usage() {
    cat >&2 <<EOF
Usage: $0 <mode> [options]

Modes:
  burst                       One ~30s wave (~50 hits). Pre-warm cache.
  sustained                   Steady traffic until --minutes elapses or Ctrl-C.

Options for sustained:
  --rps N                     Target requests per second (default: 1).
  --users N                   Concurrent fake users (default: 3).
  --minutes N                 Duration cap (default: 10). Use --forever for no cap.
  --forever                   Run until Ctrl-C.

Env:
  F1_DEMO_BASE_URL            Override target URL.
                              Default: $BASE_URL
EOF
    exit 1
}

# ---- helpers --------------------------------------------------------------
random_page() {
    echo "${PAGES[$((RANDOM % ${#PAGES[@]}))]}"
}

random_lap_detail() {
    echo "${LAP_DETAILS[$((RANDOM % ${#LAP_DETAILS[@]}))]}"
}

hit_one() {
    # 1 in 10 hits is a deep lap-detail call, which exercises the
    # FileGen -> SQL Telemetry path (large rowsets). Rest is web-page
    # navigation through Blazor.
    if (( RANDOM % 10 == 0 )); then
        local q
        q=$(random_lap_detail)
        # lap-detail requires the FileGen API key. Skip if we don't have
        # one set; fall back to a normal page hit. (We never want to
        # *demand* the key from this script -- it's optional polish.)
        if [[ -n "${F1_FILEGEN_API_KEY:-}" ]]; then
            curl -sk -o /dev/null \
                -H "X-Api-Key: $F1_FILEGEN_API_KEY" \
                -w "  %{http_code}  %{time_total}s  /files/lap-detail?$q\n" \
                "${BASE_URL}/files/lap-detail?${q}&format=json" || true
            return
        fi
    fi

    local p
    p=$(random_page)
    curl -sk -o /dev/null \
        -w "  %{http_code}  %{time_total}s  ${p}\n" \
        "${BASE_URL}${p}" || true
}

burst() {
    echo "[burst] driving ~50 hits against ${BASE_URL} ..."
    for _ in $(seq 1 50); do
        hit_one &
        # tiny jitter so we don't accidentally synflood our own demo
        sleep 0.${RANDOM:0:2}
    done
    wait
    echo "[burst] done."
}

sustained() {
    local rps=1 users=3 minutes=10 forever=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --rps)      rps="$2"; shift 2;;
            --users)    users="$2"; shift 2;;
            --minutes)  minutes="$2"; shift 2;;
            --forever)  forever=true; shift;;
            *) echo "unknown option: $1" >&2; usage;;
        esac
    done

    # Per-user delay so the aggregate target rate ~= rps.
    # delay = users / rps  (each user fires every `delay` seconds on average).
    local delay
    delay=$(awk -v u="$users" -v r="$rps" 'BEGIN { printf "%.3f", u / r }')

    local cap_msg
    if $forever; then
        cap_msg="forever (Ctrl-C to stop)"
    else
        cap_msg="${minutes}m"
    fi
    echo "[sustained] target=${rps} req/s, users=${users}, per-user delay=${delay}s, duration=${cap_msg}"
    echo "[sustained] base=${BASE_URL}"

    local end_at=0
    if ! $forever; then
        # Allow fractional minutes (e.g. --minutes 0.5 for 30s smoke tests).
        local seconds
        seconds=$(awk -v m="$minutes" 'BEGIN { printf "%d", m * 60 }')
        end_at=$(( $(date +%s) + seconds ))
    fi

    # Trap to cleanly kill children on Ctrl-C.
    trap 'echo ""; echo "[sustained] stopping..."; kill 0; exit 0' INT TERM

    # Spawn one fake-user loop per --users.
    for i in $(seq 1 "$users"); do
        (
            while true; do
                hit_one
                sleep "$delay"
                if (( end_at > 0 )) && (( $(date +%s) >= end_at )); then
                    exit 0
                fi
            done
        ) &
    done
    wait
    echo "[sustained] done."
}

# ---- entry point ----------------------------------------------------------
[[ $# -ge 1 ]] || usage
mode="$1"; shift
case "$mode" in
    burst)      burst "$@";;
    sustained)  sustained "$@";;
    *)          usage;;
esac
