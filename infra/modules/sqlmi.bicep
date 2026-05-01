// =============================================================================
// SQL Managed Instance — General Purpose, 4 vCore, 32 GB.
// Private-endpoint only (no public endpoint enabled).
// SQL MI itself attaches to a delegated subnet and is therefore inherently
// private; no separate Microsoft.Network/privateEndpoint resource is required.
//
// MCAPS deny policy AzureSQLMI_WithoutAzureADOnlyAuthentication_Deny requires
// Azure AD-only authentication. We therefore set:
//   properties.administrators.azureADOnlyAuthentication = true
// SQL auth is disabled at runtime. The administratorLogin/Password fields
// are still required by the API contract, so we set them but they cannot be
// used to log in.
// =============================================================================

targetScope = 'resourceGroup'

@description('Azure region.')
param location string

@description('Name prefix.')
param namePrefix string

@description('Suffix used to make the MI name globally unique.')
param uniqueSuffix string

@description('Resource tags.')
param tags object

@description('Resource ID of the delegated SQL MI subnet.')
param sqlMiSubnetId string

@description('SQL MI admin login (required by ARM contract; unused at runtime due to AAD-only auth).')
param administratorLogin string

@description('SQL MI admin password (required by ARM contract; unused at runtime due to AAD-only auth).')
@secure()
param administratorLoginPassword string

@description('Display name (UPN or group name) of the Entra ID admin for SQL MI.')
param aadAdminLogin string

@description('Object ID of the Entra ID user or group that will be SQL MI admin.')
param aadAdminObjectId string

@description('Principal type of the AAD admin: User, Group, or Application.')
@allowed(['User', 'Group', 'Application'])
param aadAdminPrincipalType string = 'User'

var miName = toLower('mi-${namePrefix}-${uniqueSuffix}')

resource sqlMi 'Microsoft.Sql/managedInstances@2023-08-01-preview' = {
  name: miName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  sku: {
    name: 'GP_Gen5'
    tier: 'GeneralPurpose'
    family: 'Gen5'
    capacity: 4
  }
  properties: {
    administratorLogin: administratorLogin
    administratorLoginPassword: administratorLoginPassword
    subnetId: sqlMiSubnetId
    licenseType: 'LicenseIncluded'
    vCores: 4
    storageSizeInGB: 32
    collation: 'SQL_Latin1_General_CP1_CI_AS'
    publicDataEndpointEnabled: false
    proxyOverride: 'Proxy'
    timezoneId: 'UTC'
    minimalTlsVersion: '1.2'
    requestedBackupStorageRedundancy: 'Local'
    zoneRedundant: false
    administrators: {
      administratorType: 'ActiveDirectory'
      principalType: aadAdminPrincipalType
      login: aadAdminLogin
      sid: aadAdminObjectId
      tenantId: subscription().tenantId
      azureADOnlyAuthentication: true
    }
  }
}

output managedInstanceId string = sqlMi.id
output managedInstanceName string = sqlMi.name
output fullyQualifiedDomainName string = sqlMi.properties.fullyQualifiedDomainName
output principalId string = sqlMi.identity.principalId
