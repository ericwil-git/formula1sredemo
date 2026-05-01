// =============================================================================
// App Service — Linux B2, ASP.NET Core 8, Blazor Server, anonymous.
// System-assigned managed identity. Regional VNet integration.
// App settings reference Key Vault via @Microsoft.KeyVault syntax.
// =============================================================================

targetScope = 'resourceGroup'

@description('Azure region.')
param location string

@description('Name prefix.')
param namePrefix string

@description('Resource tags.')
param tags object

@description('Globally unique web app name.')
param webAppName string

@description('Resource ID of the snet-app subnet (used here to reach the VM via VNet).')
param appSubnetId string

@description('Application Insights connection string from monitoring module.')
param appInsightsConnectionString string

@description('Key Vault name (referenced via Key Vault references in app settings).')
param keyVaultName string

@description('FileGenerator base URL on the VM (private IP, https on 8443).')
param fileGeneratorBaseUrl string

var planName = 'plan-${namePrefix}'
// VNet integration must use a delegated subnet; use snet-appsvc-int derived
// from the VNet that owns appSubnetId.
var vnetIntegrationSubnetId = replace(appSubnetId, '/subnets/snet-app', '/subnets/snet-appsvc-int')

resource plan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: planName
  location: location
  tags: tags
  sku: {
    name: 'B2'
    tier: 'Basic'
    size: 'B2'
    family: 'B'
    capacity: 1
  }
  kind: 'linux'
  properties: {
    reserved: true
  }
}

resource site 'Microsoft.Web/sites@2023-12-01' = {
  name: webAppName
  location: location
  tags: tags
  kind: 'app,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    virtualNetworkSubnetId: vnetIntegrationSubnetId
    vnetRouteAllEnabled: true
    keyVaultReferenceIdentity: 'SystemAssigned'
    siteConfig: {
      linuxFxVersion: 'DOTNETCORE|8.0'
      alwaysOn: true
      ftpsState: 'Disabled'
      http20Enabled: true
      minTlsVersion: '1.2'
      vnetRouteAllEnabled: true
      appSettings: [
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsightsConnectionString
        }
        {
          name: 'ApplicationInsightsAgent_EXTENSION_VERSION'
          value: '~3'
        }
        {
          name: 'ASPNETCORE_ENVIRONMENT'
          value: 'Production'
        }
        {
          name: 'FileGenerator__BaseUrl'
          value: fileGeneratorBaseUrl
        }
        {
          name: 'FileGenerator__ApiKey'
          value: '@Microsoft.KeyVault(VaultName=${keyVaultName};SecretName=fileGeneratorApiKey)'
        }
        {
          name: 'WEBSITE_LOAD_ROOT_CERTIFICATES'
          value: '*'
        }
      ]
    }
  }
}

output webAppId string = site.id
output webAppName string = site.name
output defaultHostName string = site.properties.defaultHostName
output principalId string = site.identity.principalId
