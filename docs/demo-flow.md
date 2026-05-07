# F1 SRE Demo — Stagecraft & Narrative Guide

> Companion to [`docs/sre-demo.md`](sre-demo.md). That doc is the **technical
> runbook** (every command, every parameter). This doc is the **narrative** —
> what to show, in what order, and what to say. Use both: read this first,
> keep `sre-demo.md` open in a second window for the actual commands.

**Audience:** NBCUniversal Sports — engineering leadership + SREs.
**Total time:** 25–30 minutes including Q&A. The demo itself is 15 min.

---

## Why this order works

The instinct is "lead with the scariest failure." Resist it. The credible
arc is **escalating subtlety** — each scenario is harder than the last for
both a human and an AI to diagnose:

1. **Obvious crash** (FileGenerator down) — establishes that the agent reads
   the right signals.
2. **Performance regression** (slow query → p99 long-tail) — the *interesting*
   problem. Status-code monitoring misses it entirely. This is the moment
   that lands with an SRE audience.
3. **Cross-tier dependency** (SQL down) — closes the loop, shows the agent
   can correlate across tiers and reach a different conclusion than #1
   even though the surface symptom is identical.

If you only have time for one scenario, pick **#2 (slow query)**. It's the
most differentiated.

---

## Pre-demo (10 minutes before)

```bash
# 1. Confirm green.
curl -sk -o /dev/null -w "%{http_code}\n" https://app-f1demo-wr4dcd.azurewebsites.net/race/2026/3
# expect 200, page renders with data

# 2. Pre-warm the cache so the first page-load on stage is fast.
./scripts/generate-traffic.sh burst

# 3. Start sustained background traffic so the workbook charts are LIVE
#    (not flatlined) when you switch to them on stage. Run this in its
#    own terminal/tmux pane and forget about it -- you can leave it
#    running through the entire demo. ~1 req/s, 4 fake users, 60 min.
./scripts/generate-traffic.sh sustained --rps 1 --users 4 --minutes 60 &
TRAFFIC_PID=$!
echo "background traffic PID=$TRAFFIC_PID"
# Kill it when the demo is over: kill $TRAFFIC_PID

# 4. Confirm all five heal scripts run clean (idempotent).
for s in filegen sql slow-query disk-fill stale-data; do
  ./scripts/heal/$s.sh > /dev/null 2>&1 && echo "  heal/$s OK" || echo "  heal/$s FAIL"
done
```

> **Why background traffic matters.** A workbook that says
> "0 requests in the last 5 minutes" looks broken even when nothing is
> wrong. Sustained traffic keeps the percentile bands populated, the
> volume timecharts moving, and the Application Map nodes "warm". When
> you switch from the live web app to the workbook on stage, the
> audience sees actual signal instead of empty charts.

**Open these tabs in order, left → right (the order you'll switch through them):**

| # | Tab | What |
|---|---|---|
| 1 | https://app-f1demo-wr4dcd.azurewebsites.net/race/2026/3 | The live web app (the "user view") |
| 2 | App Insights → Application Map | Three-node service map |
| 3 | App Insights → Workbooks → "F1 SRE Demo — Service Overview" | Live three-section workbook (Service Health · Latency · Ingestion) |
| 4 | Azure SRE Agent (or Observability Agent) | The Q&A surface |
| 5 | Terminal | `cd ~/Projects/formula1-sre-demo/formula1sredemo` |

Hide the terminal until you need it. Audience focus = browser.

---

## Act 1 — "What you're looking at" (3 min)

> **Goal:** establish what the system is and *why anyone should care that
> it works*. Build investment before you break it.

**Tab 1 (web app, /race/2026/3):**

> "This is real Formula 1 timing and telemetry — 2026 round 3, Suzuka. Lap
> times, tyre stints, the speed traces you see in the broadcast graphics
> pipeline are exactly this shape of data. Three-tier app: Blazor on
> App Service, a .NET service on a Windows VM, SQL Server on the same VM."

Click through:
- Lap-time distribution (the box plot) → "consistency story"
- Tyre stint Gantt → "strategy story"
- Open `/lap-explorer`, overlay two drivers on lap 30 → "telemetry detail"

**Tab 2 (Application Map):**

> "Here's the same architecture in App Insights. F1.Web on the left,
> F1.FileGenerator in the middle, MSSQL on the right, F1.Ingestion off to
> the side because it runs on a schedule. Every arrow you see is a real
> distributed trace — when a user request comes in, we follow it through
> all three tiers and timing each hop."

Click an arrow → show a Transaction Search example with a real waterfall.

**Tab 3 (workbook, scrolled to the Service Health section at top):**

> "Right now all three rows are green. Per-tier traffic, zero failures,
> sub-second p95. This is what 'healthy' looks like."

---

## Act 2 — Scenario 1: The obvious crash (4 min)

> **Story:** "A deploy went sideways and the middle-tier service won't
> start." This is the bread-and-butter outage every operator has lived.

```bash
# Terminal:
./scripts/break/filegen.sh
```

Switch to **Tab 1** (web app). Hit refresh.

> "Notice — page renders, but no data. Banner says 'No race data
> available, the database may be empty.' Status code is 200. **A
> health-check that only watches HTTP codes would think this is fine.**"

Wait ~30 seconds (talk through it).

Switch to **Tab 3** (workbook → Service Health). Click "Refresh all".

> "The Failures column on F1.Web jumped — those are the dependency
> failures. SQL dependency health on the second panel is unchanged —
> the database is fine. So the broken hop is between Web and FileGen."

Switch to **Tab 4** (SRE Agent). Type:

> "What's wrong with the F1 demo running in rg-f1demo-centeral?"

**Expected agent answer:** identifies the F1FileGenerator service is
stopped, cites the failed GET /files/race dependency calls, suggests
`Start-Service F1FileGenerator`.

> "Note what just happened: the agent didn't just look at uptime, it
> correlated the page rendering with the upstream dependency failure
> across two roles. That's the win."

```bash
# Heal:
./scripts/heal/filegen.sh
```

Wait 30 seconds. Refresh Tab 1. Page recovers.

---

## Act 3 — Scenario 2: The interesting problem (5 min)

> **Story:** "Service is up. p50 is fine. But users are starting to
> complain that some pages are slow. There's no error to log."

This is the scenario that earns the agent its keep.

```bash
# Terminal:
./scripts/break/slow-query.sh

# Drive a few requests so the agent has something to chew on:
for i in $(seq 1 8); do
  curl -sk -o /dev/null "https://app-f1demo-wr4dcd.azurewebsites.net/race/2026/$((RANDOM % 3 + 1))"
  sleep 4
done
```

Switch to **Tab 1**. Reload.

> "The page works. It just feels slow. Some refreshes are 3–4 seconds.
> Some are normal. There's nothing in the user-visible experience to
> latch onto."

Switch to **Tab 3** (workbook → scroll down to the **Latency** section).

> "Volume is normal — see the top chart. But look at the percentiles.
> p50 is right where it was. p95 climbed. **p99 went past 2 seconds.**
> That's a long-tail problem — 99% of users are fine, 1% are getting
> punished. And the SQL-query-duration chart at the bottom shows the
> time is being spent at the SQL hop, not the middle tier."

Switch to **Tab 4** (SRE Agent):

> "F1.FileGenerator p99 latency just spiked. Is the bottleneck in the
> middle tier or in SQL?"

**Expected agent answer:** identifies the SQL dependency duration spike
for `F1.FileGenerator` cloud role, cites the new sev-2 alert if it has
fired, distinguishes p50 vs p99.

> "This is the demo moment. Status-code monitoring saw nothing. Average
> latency monitoring saw nothing. The agent is reading p99 over a 5-min
> window and pinpointing the offending hop in seconds — not after a 30-
> minute incident bridge."

```bash
# Heal:
./scripts/heal/slow-query.sh
```

p99 returns to baseline within ~3–5 min as the metric window ages out.
Don't wait for it on stage — move on.

---

## Act 4 — Scenario 3: Same symptom, different cause (4 min)

> **Story:** "Same broken page as Act 2 — 'No race data available'.
> Same banner. Same Blazor toast. Different root cause. Can the agent
> tell?"

```bash
# Terminal:
./scripts/break/sql.sh
```

Switch to **Tab 1**. Refresh.

> "Look familiar? Same banner, same error toast. **Watch how a less
> capable monitoring system would tell us the same answer as Act 2 —
> 'restart FileGenerator'. Here's why that's wrong.**"

Switch to **Tab 4** (SRE Agent):

> "Same question — what's wrong with the F1 demo?"

**Expected agent answer:** diagnoses **SQL Server**, not FileGenerator.
Cites the f1_filegen_sql_errors custom metric and/or the FileGenerator
`/health` endpoint reporting `sqlServer: unreachable`. Suggests
`Start-Service MSSQLSERVER`.

> "Same surface symptom. Different upstream cause. Different remediation.
> The agent picked it because we instrumented two distinct signals —
> a custom counter for SQL exceptions, and a health endpoint that
> reports its own dependency state."

If the audience pushes — "is this just a hardcoded if-then?" — the
honest answer is:

> "No, it's reading App Insights `customMetrics` for the OTel-emitted
> counter, plus the dependency table where `success == false` for SQL,
> plus the f1_filegen_sql_errors gauge. We made those three signals
> available. The agent decided which to pull."

```bash
# Heal:
./scripts/heal/sql.sh
```

---

## Act 5 — Closing (2 min)

Switch back to **Tab 3** (workbook → Service Health). Refresh.

> "Three deliberate failures, three clean diagnoses, zero engineering
> escalations. Total wall-clock time including the scripted breaks
> was under 15 minutes. In a real incident, this is the difference
> between a 5-minute Slack thread and a 90-minute conference bridge."

Pause. Then:

> "What we're showing isn't AI for AI's sake. It's that the right
> instrumentation — distributed traces, custom metrics with stable
> names, alerts that point at exact KQL queries, a workbook that
> visualizes the same signals — gives an agent enough surface area
> to reason about a system the way an experienced SRE does."

---

## Q&A — common questions

| Question | Answer |
|---|---|
| "Did you script the agent's responses?" | No — the agent is reading live App Insights. The scripts only break the system. The "Q&A" with the agent is real. |
| "What if the agent hallucinates?" | It happens. We've found that *grounding* it in specific KQL queries (which is what the alerts and workbook do) reduces this dramatically. Show them the alert rule definitions if pushed — they're plain KQL. |
| "What does this cost?" | App Insights ingestion ~$2/day at the scrape rate we have configured. Log Analytics ~$0.50/day. The VM is the cost driver — B2 is ~$30/mo if left running. The scripts include `az vm deallocate` for between demos. |
| "Could we use this on prem?" | Yes — replace the App Insights sink with OTel → managed Prometheus + Tempo, or any OTel-compatible collector. The application code change is one line. |
| "What about Copilot for Azure / SRE Copilot?" | Same surface. The agent in this demo is whichever GA / preview agent is enabled in your tenant. |

---

## SRE Agent / Observability Agent — configuration prerequisites

The demo requires the agent to be **already onboarded to the demo
subscription/RG** before you start. None of these are demo-day tasks —
do them ahead of time.

### One-time tenant setup (admin)

1. **Enroll in the preview** (skip if your tenant already has the agent
   enabled): <https://aka.ms/AzureSREAgent>. The Azure SRE Agent is in
   limited preview as of this demo's date; enrollment via the page above.
2. **Allow the agent's service principal in the demo tenant.** This is
   automatic once the preview is granted.

### Demo-environment scope (one-time per RG)

The agent reads telemetry through Azure RBAC. Grant it the minimum
roles it needs on the demo resource group:

```bash
RG=rg-f1demo-centeral
SP_ID=$(az ad sp list --display-name "Azure SRE Agent" --query "[0].id" -o tsv)

# Read all resource metadata
az role assignment create --assignee-object-id $SP_ID \
    --assignee-principal-type ServicePrincipal \
    --role "Reader" \
    --scope "/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$RG"

# Read App Insights / Log Analytics / Monitor Workspace data
az role assignment create --assignee-object-id $SP_ID \
    --assignee-principal-type ServicePrincipal \
    --role "Monitoring Reader" \
    --scope "/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$RG"

# Read Log Analytics workspace data (separate role)
az role assignment create --assignee-object-id $SP_ID \
    --assignee-principal-type ServicePrincipal \
    --role "Log Analytics Reader" \
    --scope "/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$RG/providers/Microsoft.OperationalInsights/workspaces/log-f1demo"
```

> If `az ad sp list` returns nothing, the agent isn't enrolled yet —
> circle back to the preview signup.

### Agent context — give it the right resources

In the agent UI (Azure Portal → SRE Agent), set the **scope** of the
investigation to:

- Subscription: `<your subscription>`
- Resource group: `rg-f1demo-centeral`
- Primary App Insights resource: `appi-f1demo`
- Primary workbook: `F1 SRE Demo — Service Overview`

Saving this scope ahead of time means you don't fumble with picker
dialogs during the demo.

### Sanity-check before going on stage

Ask the agent:

> "What resources are in rg-f1demo-centeral and what does each one do?"

If it can list `app-f1demo-wr4dcd` (Web), `vm-f1demo-win` (VM),
`appi-f1demo` (App Insights), `kv-f1demo-wr4dcd` (Key Vault) and the rest
of the RG, you're good. If it returns "I don't have access" or "I don't
see that resource", re-check the role assignments.

### If the agent isn't available in your tenant on demo day

Two graceful fallbacks:

1. **App Insights Smart Detection.** Open `appi-f1demo` → Smart Detection
   → Detected issues. After the slow-query break it will surface a
   "performance anomaly" card automatically. Less impressive than the
   agent (no natural language) but uses the same telemetry.
2. **The workbook alone.** The workbook is the agent's reference
   material. Walk the audience through the **Service Health → Latency
   → Ingestion** tabs and narrate what an SRE would see. Reorder the
   acts so the workbook is the "co-star" rather than supporting cast.

---

## Anti-patterns — what NOT to do on stage

- **Don't run more than 2 break scripts back-to-back.** They're
  idempotent but the alerts have 5-min windows; firing three concurrent
  breaks confuses the agent.
- **Don't show raw KQL.** It crashes the narrative for non-engineers.
  If a developer in the audience asks, sidebar after the demo.
- **Don't let the disk-fill scenario sit broken.** D: is small. Always
  pair it with the heal within 90 seconds.
- **Don't try to demo the ingest-stale alert live.** The 24h window
  makes it impossible to trigger in real time. Use `break/stale-data.sh`
  to *show the alert rule and the live KQL it evaluates* instead.
- **Don't open Application Insights → Logs.** It's a great tool but
  the UI is busy and audiences don't connect with raw query results.
  The workbook tabs are the curated version of the same data.

---

## Appendix — opt-in extras for longer demos

If you have 45 minutes instead of 25:

| Add-on | Time | What it shows |
|---|---|---|
| Disk-fill scenario | 5 min | AMA Perf-counter pipeline (different signal source from App Insights). Good for "we collect *infra* signals too." |
| Walk through `infra/main.bicep` | 4 min | Show the IaC story. Useful with platform-team audiences. |
| Walk through one alert rule's KQL | 3 min | Demystifies the agent — "this is just a query the agent reads." |
| Show the App Insights Live Metrics blade during the slow-query break | 4 min | Real-time visualization of the same signals the agent sees. Effective with engineers who want a "one-pane-of-glass" pitch. |
