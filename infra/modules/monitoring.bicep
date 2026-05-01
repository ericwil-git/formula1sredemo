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

output logAnalyticsWorkspaceId string = law.id
output logAnalyticsWorkspaceName string = law.name
output appInsightsId string = ai.id
output appInsightsConnectionString string = ai.properties.ConnectionString
output azureMonitorWorkspaceId string = amw.id
output azureMonitorWorkspaceName string = amw.name
output dataCollectionRuleId string = dcr.id
output actionGroupId string = actionGroup.id
