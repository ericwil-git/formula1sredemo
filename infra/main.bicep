// =============================================================================
// F1 SRE Demo — subscription-scope entry point.
// Creates the resource group and invokes all child modules.
// =============================================================================

targetScope = 'subscription'

@description('Azure region for all resources.')
param location string = 'centralus'

@description('Resource group name.')
param resourceGroupName string = 'rg-f1demo-centeral'

@description('Short prefix used to name resources (lowercase, 3-8 chars).')
@minLength(3)
@maxLength(8)
param namePrefix string = 'f1demo'

@description('Suffix used to make globally-unique names (KV, App Service). Default: short hash of subscription+RG.')
param uniqueSuffix string = substring(uniqueString(subscription().subscriptionId, resourceGroupName), 0, 6)

@description('SQL MI admin login (legacy field; SQL auth is disabled at runtime).')
param sqlMiAdminLogin string = 'f1adm'

@description('SQL MI admin password (legacy field; SQL auth is disabled at runtime, but ARM still requires a value).')
@secure()
param sqlMiAdminPassword string

@description('Display name (UPN or group name) of the Entra ID SQL MI admin.')
param aadAdminLogin string

@description('Object ID of the Entra ID user/group that will be SQL MI admin.')
param aadAdminObjectId string

@description('Principal type of the AAD admin: User, Group, or Application.')
@allowed(['User', 'Group', 'Application'])
param aadAdminPrincipalType string = 'User'

@description('Windows VM local admin username.')
param vmAdminUsername string = 'f1demoadmin'

@description('Windows VM local admin password (12+ chars, complexity rules apply).')
@secure()
param vmAdminPassword string

@description('Source CIDR allowed to RDP into the VM. Use your /32 for safety; "*" allows the world.')
param rdpSourceAddressPrefix string = '*'

@description('Static API key the FileGenerator expects in X-Api-Key header.')
@secure()
param fileGeneratorApiKey string

var tags = {
  demo: 'f1-nbcu'
  owner: 'eric.wilson@microsoft.com'
  'auto-stop': 'manual'
}

// Names derived once and shared between modules so both sides agree without
// creating circular dependencies.
var kvName = toLower('kv-${namePrefix}-${uniqueSuffix}')
var webAppName = toLower('app-${namePrefix}-${uniqueSuffix}')

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}

module monitoring 'modules/monitoring.bicep' = {
  scope: rg
  name: 'monitoring'
  params: {
    location: location
    namePrefix: namePrefix
    tags: tags
  }
}

module network 'modules/network.bicep' = {
  scope: rg
  name: 'network'
  params: {
    location: location
    namePrefix: namePrefix
    tags: tags
    rdpSourceAddressPrefix: rdpSourceAddressPrefix
  }
}

module sqlmi 'modules/sqlmi.bicep' = {
  scope: rg
  name: 'sqlmi'
  params: {
    location: location
    namePrefix: namePrefix
    uniqueSuffix: uniqueSuffix
    tags: tags
    sqlMiSubnetId: network.outputs.sqlMiSubnetId
    administratorLogin: sqlMiAdminLogin
    administratorLoginPassword: sqlMiAdminPassword
    aadAdminLogin: aadAdminLogin
    aadAdminObjectId: aadAdminObjectId
    aadAdminPrincipalType: aadAdminPrincipalType
  }
}

module vm 'modules/vm.bicep' = {
  scope: rg
  name: 'vm'
  params: {
    location: location
    namePrefix: namePrefix
    tags: tags
    appSubnetId: network.outputs.appSubnetId
    adminUsername: vmAdminUsername
    adminPassword: vmAdminPassword
    dataCollectionRuleId: monitoring.outputs.dataCollectionRuleId
  }
}

module appservice 'modules/appservice.bicep' = {
  scope: rg
  name: 'appservice'
  params: {
    location: location
    namePrefix: namePrefix
    tags: tags
    webAppName: webAppName
    appSubnetId: network.outputs.appSubnetId
    appInsightsConnectionString: monitoring.outputs.appInsightsConnectionString
    keyVaultName: kvName
    fileGeneratorBaseUrl: 'https://${vm.outputs.privateIp}:8443'
  }
}

module keyvault 'modules/keyvault.bicep' = {
  scope: rg
  name: 'keyvault'
  params: {
    location: location
    keyVaultName: kvName
    tags: tags
    sqlMiAdminPassword: sqlMiAdminPassword
    fileGeneratorApiKey: fileGeneratorApiKey
    sqlConnectionString: 'Server=${sqlmi.outputs.fullyQualifiedDomainName};Database=f1demo;Authentication=Active Directory Default;TrustServerCertificate=True;'
    appServicePrincipalId: appservice.outputs.principalId
    vmPrincipalId: vm.outputs.principalId
  }
}

output resourceGroupName string = rg.name
output webAppDefaultHostName string = appservice.outputs.defaultHostName
output webAppName string = webAppName
output vmName string = vm.outputs.vmName
output vmPrivateIp string = vm.outputs.privateIp
output sqlMiFqdn string = sqlmi.outputs.fullyQualifiedDomainName
output keyVaultName string = kvName
output logAnalyticsWorkspaceId string = monitoring.outputs.logAnalyticsWorkspaceId
output azureMonitorWorkspaceId string = monitoring.outputs.azureMonitorWorkspaceId
