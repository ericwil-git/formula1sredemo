// =============================================================================
// SRE Demo Workbook — three stacked sections:
//   1. Service Health  — tiles for Web / FileGenerator / SQL + slowest reqs
//   2. Latency         — request volume + duration percentiles by role
//   3. Ingestion       — f1_ingest_runs heartbeat + cache hit ratio
//
// Earlier revision used a links/tabs control with conditionalVisibility
// against a 'selectedTab' parameter. That pattern is fragile (parameter
// must come BEFORE the tab control in items[], and the cellValue/subTarget
// schema varies between portal versions) and broke clicking the Latency /
// Ingestion tabs in the deployed workbook. This revision drops tabs
// entirely and uses three always-visible stacked sections separated by H2
// markdown headers. Less clever, more reliable for live demos.
// =============================================================================

targetScope = 'resourceGroup'

@description('Azure region.')
param location string

@description('Name prefix.')
param namePrefix string

@description('Resource tags.')
param tags object

@description('Resource ID of the existing Application Insights component.')
param appInsightsId string

// Workbook JSON — assembled as a Bicep object then stringified. Schema
// reference: https://github.com/Microsoft/Application-Insights-Workbooks
var workbookContent = {
  version: 'Notebook/1.0'
  items: [
    {
      type: 1
      content: {
        json: '# F1 SRE Demo — Live Service View\n\nLive against `${last(split(appInsightsId, '/'))}`. Three sections below: **Service Health** (15m window) · **Latency** (1h window) · **Ingestion** (24h window). See [docs/sre-demo.md](https://github.com/ericwil-git/formula1sredemo/blob/main/docs/sre-demo.md) for the demo runbook and [docs/demo-flow.md](https://github.com/ericwil-git/formula1sredemo/blob/main/docs/demo-flow.md) for the on-stage talk track.'
      }
      name: 'header'
    }

    // ============================ SECTION 1: Service Health ============================
    {
      type: 1
      content: {
        json: '---\n## 🟢 Service Health — last 15 minutes\n\nEach card shows the request volume and failure count per cloud role. A failure count above zero is a degradation signal worth investigating.'
      }
      name: 'health-md'
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: 'requests | where timestamp > ago(15m) | summarize Requests = count(), Failures = countif(success == false), AvgMs = avg(duration), P95Ms = percentile(duration, 95) by cloud_RoleName | order by cloud_RoleName asc'
        size: 3
        title: 'Per-tier traffic & failures (15m)'
        queryType: 0
        resourceType: 'microsoft.insights/components'
        visualization: 'table'
        gridSettings: {
          formatters: [
            {
              columnMatch: 'Failures'
              formatter: 8
              formatOptions: {
                palette: 'redBright'
              }
            }
            {
              columnMatch: 'P95Ms'
              formatter: 8
              formatOptions: {
                palette: 'orange'
              }
            }
          ]
        }
      }
      name: 'health-tiles'
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: 'dependencies | where timestamp > ago(15m) and type == "SQL" | summarize Calls = count(), Failures = countif(success == false), AvgMs = avg(duration) by cloud_RoleName | order by Calls desc'
        size: 3
        title: 'SQL dependency health (15m)'
        queryType: 0
        resourceType: 'microsoft.insights/components'
        visualization: 'table'
      }
      name: 'health-sql'
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: 'requests | where timestamp > ago(15m) and cloud_RoleName == "F1.Web" | top 20 by duration desc | project timestamp, name, duration, success, operation_Id'
        size: 0
        title: 'Slowest user-facing requests (top 20, 15m)'
        queryType: 0
        resourceType: 'microsoft.insights/components'
        visualization: 'table'
      }
      name: 'health-slowest'
    }

    // ============================ SECTION 2: Latency ============================
    {
      type: 1
      content: {
        json: '---\n## ⏱ Latency drill-down — last hour\n\nThe two charts below render the same `requests` table sliced by `cloud_RoleName`. The first is volume; the second is the percentile latency band. The SQL dependency overlay at the bottom answers _"is the latency from the database or from the middle tier?"_.'
      }
      name: 'latency-md'
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: 'requests | where timestamp > ago(1h) | summarize Count = count() by bin(timestamp, 1m), cloud_RoleName | render timechart'
        size: 0
        title: 'Request volume by tier (1h, 1m bins)'
        queryType: 0
        resourceType: 'microsoft.insights/components'
      }
      name: 'latency-volume'
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: 'requests | where timestamp > ago(1h) | summarize p50 = percentile(duration, 50), p95 = percentile(duration, 95), p99 = percentile(duration, 99) by bin(timestamp, 5m), cloud_RoleName | render timechart'
        size: 0
        title: 'Duration percentiles by tier (p50 / p95 / p99)'
        queryType: 0
        resourceType: 'microsoft.insights/components'
      }
      name: 'latency-percentiles'
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: 'dependencies | where timestamp > ago(1h) and type == "SQL" and cloud_RoleName == "F1.FileGenerator" | summarize p50 = percentile(duration, 50), p95 = percentile(duration, 95), p99 = percentile(duration, 99) by bin(timestamp, 5m) | render timechart'
        size: 0
        title: 'SQL query duration from FileGenerator (p50 / p95 / p99)'
        queryType: 0
        resourceType: 'microsoft.insights/components'
      }
      name: 'latency-sql'
    }

    // ============================ SECTION 3: Ingestion ============================
    {
      type: 1
      content: {
        json: '---\n## 📥 Ingestion freshness & cache effectiveness — last 24 hours\n\nThe top tile is the data the **alert-f1demo-ingest-stale** rule fires on. The middle chart is the OTel `f1_ingest_runs` counter. The bottom panel is FileGenerator cache hit ratio — drops here translate directly into SQL load.'
      }
      name: 'ingest-md'
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: 'customMetrics | where timestamp > ago(24h) | where name == "f1_ingest_runs" | summarize Runs = sum(valueSum), LastRun = max(timestamp) by tostring(customDimensions.year) | order by LastRun desc'
        size: 3
        title: 'Successful ingestion runs (24h)'
        queryType: 0
        resourceType: 'microsoft.insights/components'
        visualization: 'table'
      }
      name: 'ingest-runs-table'
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: 'customMetrics | where timestamp > ago(24h) | where name == "f1_ingest_runs" | summarize Runs = sum(valueSum) by bin(timestamp, 1h) | render timechart'
        size: 0
        title: 'Ingestion heartbeat over time (1h bins)'
        queryType: 0
        resourceType: 'microsoft.insights/components'
      }
      name: 'ingest-runs-chart'
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: 'customMetrics | where timestamp > ago(1h) | where name in ("f1_filegen_cache_hits", "f1_filegen_cache_misses") | summarize Sum = sum(valueSum) by name | extend label = case(name == "f1_filegen_cache_hits", "Hits", "Misses")'
        size: 3
        title: 'Cache hits vs. misses (last 1h)'
        queryType: 0
        resourceType: 'microsoft.insights/components'
        visualization: 'piechart'
      }
      name: 'ingest-cache'
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: 'customMetrics | where timestamp > ago(24h) and name == "f1_files_generated" | summarize Total = sum(valueSum) by tostring(customDimensions.endpoint) | order by Total desc'
        size: 3
        title: 'Files generated by endpoint (24h)'
        queryType: 0
        resourceType: 'microsoft.insights/components'
        visualization: 'barchart'
      }
      name: 'ingest-files-by-endpoint'
    }
  ]
  fallbackResourceIds: [
    appInsightsId
  ]
  '$schema': 'https://github.com/Microsoft/Application-Insights-Workbooks/blob/master/schema/workbook.json'
}

// Deterministic GUID so the workbook updates in place rather than creating a
// new orphan on every deploy.
var workbookGuid = guid(resourceGroup().id, '${namePrefix}-sre-overview')

resource workbook 'Microsoft.Insights/workbooks@2023-06-01' = {
  name: workbookGuid
  location: location
  tags: tags
  kind: 'shared'
  properties: {
    displayName: 'F1 SRE Demo — Service Overview'
    description: 'Three-section live workbook for the F1 SRE demo. See docs/sre-demo.md for the runbook.'
    version: '1.0'
    serializedData: string(workbookContent)
    sourceId: appInsightsId
    category: 'workbook'
  }
}

output workbookId string = workbook.id
output workbookName string = workbook.name
