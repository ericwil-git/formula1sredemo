// =============================================================================
// Key Vault — RBAC, three secrets, role assignments for App Service + VM MIs.
// =============================================================================

targetScope = 'resourceGroup'

@description('Azure region.')
param location string

@description('Globally unique Key Vault name (3-24 chars).')
@minLength(3)
@maxLength(24)
param keyVaultName string

@description('Resource tags.')
param tags object

@description('SQL Server sa password — stored as a secret. Used by FileGenerator + Ingestion on the VM.')
@secure()
param sqlServerSaPassword string

@description('FileGenerator API key — stored as a secret.')
@secure()
param fileGeneratorApiKey string

@description('SQL connection string — stored as a secret.')
@secure()
param sqlConnectionString string

@description('System-assigned principal ID of the App Service (for RBAC).')
param appServicePrincipalId string

@description('System-assigned principal ID of the VM (for RBAC).')
param vmPrincipalId string

// Built-in role: Key Vault Secrets User
var kvSecretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6'

resource kv 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  tags: tags
  properties: {
    tenantId: subscription().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    // Purge protection cannot be downgraded once enabled. We omit the
    // property so MCAPS / Azure defaults apply (they enforce true on this
    // tenant). Tear-down requires `az keyvault purge` after `az group delete`.
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
  }
}

resource secretSqlAdmin 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: kv
  name: 'sqlServerSaPassword'
  properties: {
    value: sqlServerSaPassword
    contentType: 'text/plain'
  }
}

resource secretApiKey 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: kv
  name: 'fileGeneratorApiKey'
  properties: {
    value: fileGeneratorApiKey
    contentType: 'text/plain'
  }
}

resource secretSqlConn 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: kv
  name: 'sqlConnectionString'
  properties: {
    value: sqlConnectionString
    contentType: 'text/plain'
  }
}

resource raAppService 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: kv
  name: guid(kv.id, appServicePrincipalId, kvSecretsUserRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', kvSecretsUserRoleId)
    principalId: appServicePrincipalId
    principalType: 'ServicePrincipal'
  }
}

resource raVm 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: kv
  name: guid(kv.id, vmPrincipalId, kvSecretsUserRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', kvSecretsUserRoleId)
    principalId: vmPrincipalId
    principalType: 'ServicePrincipal'
  }
}

output keyVaultId string = kv.id
output keyVaultName string = kv.name
output keyVaultUri string = kv.properties.vaultUri
