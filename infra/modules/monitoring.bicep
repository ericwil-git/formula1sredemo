// =============================================================================
// Monitoring — Log Analytics, Application Insights, Azure Monitor Workspace
// (managed Prometheus), Data Collection Rule for the Windows VM, sample alert.
// =============================================================================

targetScope = 'resourceGroup'

@description('Azure region.')
param location string

@description('Name prefix.')
param namePrefix string

@description('Resource tags.')
param tags object

var lawName = 'log-${namePrefix}'
var aiName = 'appi-${namePrefix}'
var amwName = 'amw-${namePrefix}'
var dcrName = 'dcr-${namePrefix}-vm'
var actionGroupName = 'ag-${namePrefix}-sre'

resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: lawName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
  }
}

resource ai 'Microsoft.Insights/components@2020-02-02' = {
  name: aiName
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: law.id
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

// Azure Monitor Workspace = managed Prometheus backend.
resource amw 'Microsoft.Monitor/accounts@2023-04-03' = {
  name: amwName
  location: location
  tags: tags
  properties: {}
}

// Data Collection Rule for the Windows VM.
//   - Windows Event Logs (System, Application)
//   - Performance counters
//   - Custom text log from D:\f1-files\logs\filegen-*.log
resource dcr 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: dcrName
  location: location
  tags: tags
  kind: 'Windows'
  properties: {
    dataSources: {
      windowsEventLogs: [
        {
          name: 'eventLogsDataSource'
          streams: ['Microsoft-Event']
          xPathQueries: [
            'System!*[System[(Level=1 or Level=2 or Level=3)]]'
            'Application!*[System[(Level=1 or Level=2 or Level=3)]]'
          ]
        }
      ]
      performanceCounters: [
        {
          name: 'perfCounterDataSource'
          streams: ['Microsoft-Perf']
          samplingFrequencyInSeconds: 60
          counterSpecifiers: [
            '\\Processor(_Total)\\% Processor Time'
            '\\Memory\\Available Bytes'
            '\\LogicalDisk(_Total)\\% Free Space'
            '\\Network Interface(*)\\Bytes Total/sec'
          ]
        }
      ]
    }
    destinations: {
      logAnalytics: [
        {
          workspaceResourceId: law.id
          name: 'lawDestination'
        }
      ]
    }
    dataFlows: [
      {
        streams: ['Microsoft-Event']
        destinations: ['lawDestination']
      }
      {
        streams: ['Microsoft-Perf']
        destinations: ['lawDestination']
      }
    ]
  }
}

resource actionGroup 'Microsoft.Insights/actionGroups@2024-10-01-preview' = {
  name: actionGroupName
  location: 'global'
  tags: tags
  properties: {
    groupShortName: 'f1sre'
    enabled: true
    emailReceivers: [
      {
        name: 'owner'
        emailAddress: 'eric.wilson@microsoft.com'
        useCommonAlertSchema: true
      }
    ]
  }
}

// Sample log-search alert: any FileGenerator error in the last 5 minutes.
resource sampleAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: 'alert-${namePrefix}-filegen-errors'
  location: location
  tags: tags
  properties: {
    displayName: 'FileGenerator errors (last 5m)'
    description: 'Fires when any FileGenerator error events appear in Log Analytics.'
    enabled: true
    severity: 2
    evaluationFrequency: 'PT5M'
    windowSize: 'PT5M'
    scopes: [law.id]
    criteria: {
      allOf: [
        {
          query: 'Event | where Source has "FileGenerator" and EventLevel <= 3 | summarize Count = count()'
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: [actionGroup.id]
    }
  }
}

// ===========================================================================
// Phase 2 alerts — query App Insights (workspace-based) for the OTel-exported
// FileGenerator + Ingestion telemetry.
// ===========================================================================

// 1. FileGenerator p99 latency > 2s over a rolling 5m window.
//    Targets the App Insights `requests` table, filtered to the FileGenerator
//    cloud_RoleName so the alert is tier-specific (web-tier latency lives in
//    a different rule, see roadmap Phase 3).
resource alertFilegenP99 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: 'alert-${namePrefix}-filegen-p99-high'
  location: location
  tags: tags
  properties: {
    displayName: 'FileGenerator p99 latency > 2s (5m)'
    description: 'FileGenerator request p99 above 2000 ms over a rolling 5m window. Indicates middle-tier slowness; check SQL query duration in the trace.'
    enabled: true
    severity: 2
    evaluationFrequency: 'PT5M'
    windowSize: 'PT5M'
    scopes: [ai.id]
    criteria: {
      allOf: [
        {
          query: 'requests | where cloud_RoleName == "F1.FileGenerator" | summarize p99 = percentile(duration, 99) | where p99 > 2000'
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: [actionGroup.id]
    }
  }
}

// 2. FileGenerator SQL errors > 0 over a rolling 5m window.
//    Targets the customMetrics table populated by the OTel meter
//    "F1.FileGenerator" (see src/filegenerator/Metrics.cs).
resource alertSqlErrors 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: 'alert-${namePrefix}-sql-errors'
  location: location
  tags: tags
  properties: {
    displayName: 'FileGenerator SQL errors (5m)'
    description: 'Any SQL exception in the FileGenerator middle tier over a 5m window. Severity 1 — the demo is degraded.'
    enabled: true
    severity: 1
    evaluationFrequency: 'PT5M'
    windowSize: 'PT5M'
    scopes: [ai.id]
    criteria: {
      allOf: [
        {
          query: 'customMetrics | where name == "f1_filegen_sql_errors" | summarize Total = sum(valueSum) | where Total > 0'
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: [actionGroup.id]
    }
  }
}

// 3. Ingestion stale: no successful ingestion run in the last 24 hours.
//    The ingestion script increments customMetrics name="f1_ingest_runs"
//    on success (see src/ingestion/src/f1_ingest/metrics.py).
resource alertIngestStale 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: 'alert-${namePrefix}-ingest-stale'
  location: location
  tags: tags
  properties: {
    displayName: 'Ingestion stale (no successful run in 24h)'
    description: 'No f1_ingest_runs metric received in 24h. Either the ingestion job failed or has not been triggered.'
    enabled: true
    severity: 3
    evaluationFrequency: 'PT1H'
    windowSize: 'PT24H'
    scopes: [ai.id]
    criteria: {
      allOf: [
        {
          query: 'customMetrics | where name == "f1_ingest_runs" | summarize Runs = sum(valueSum)'
          timeAggregation: 'Count'
          operator: 'Equal'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: [actionGroup.id]
    }
  }
}

output logAnalyticsWorkspaceId string = law.id
output logAnalyticsWorkspaceName string = law.name
output appInsightsId string = ai.id
output appInsightsConnectionString string = ai.properties.ConnectionString
output azureMonitorWorkspaceId string = amw.id
output azureMonitorWorkspaceName string = amw.name
output dataCollectionRuleId string = dcr.id
output actionGroupId string = actionGroup.id
