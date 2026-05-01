// =============================================================================
// Network — VNet, 3 subnets, NSGs, route table for SQL MI, private DNS zones.
// =============================================================================

targetScope = 'resourceGroup'

@description('Azure region.')
param location string

@description('Name prefix.')
param namePrefix string

@description('Resource tags.')
param tags object

@description('CIDR allowed to RDP into the VM.')
param rdpSourceAddressPrefix string

var vnetName = 'vnet-${namePrefix}-cus'
var sqlMiNsgName = 'nsg-${namePrefix}-sqlmi'
var sqlMiRouteTableName = 'rt-${namePrefix}-sqlmi'
var appNsgName = 'nsg-${namePrefix}-app'
var peNsgName = 'nsg-${namePrefix}-pe'

// -----------------------------------------------------------------------------
// NSGs
// -----------------------------------------------------------------------------

resource sqlMiNsg 'Microsoft.Network/networkSecurityGroups@2024-01-01' = {
  name: sqlMiNsgName
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'allow_management_inbound'
        properties: {
          priority: 100
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRanges: ['9000', '9003', '1438', '1440', '1452']
        }
      }
      {
        name: 'allow_misubnet_inbound'
        properties: {
          priority: 200
          access: 'Allow'
          direction: 'Inbound'
          protocol: '*'
          sourceAddressPrefix: '10.20.1.0/27'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
      {
        name: 'allow_health_probe_inbound'
        properties: {
          priority: 300
          access: 'Allow'
          direction: 'Inbound'
          protocol: '*'
          sourceAddressPrefix: 'AzureLoadBalancer'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
      {
        name: 'allow_tds_inbound'
        properties: {
          priority: 1000
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Tcp'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '1433'
        }
      }
      {
        name: 'deny_all_inbound'
        properties: {
          priority: 4096
          access: 'Deny'
          direction: 'Inbound'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
      {
        name: 'allow_management_outbound'
        properties: {
          priority: 100
          access: 'Allow'
          direction: 'Outbound'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRanges: ['80', '443', '12000']
        }
      }
      {
        name: 'allow_misubnet_outbound'
        properties: {
          priority: 200
          access: 'Allow'
          direction: 'Outbound'
          protocol: '*'
          sourceAddressPrefix: '10.20.1.0/27'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
      {
        name: 'deny_all_outbound'
        properties: {
          priority: 4096
          access: 'Deny'
          direction: 'Outbound'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

resource appNsg 'Microsoft.Network/networkSecurityGroups@2024-01-01' = {
  name: appNsgName
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'allow_rdp_inbound'
        properties: {
          priority: 100
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Tcp'
          sourceAddressPrefix: rdpSourceAddressPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '3389'
        }
      }
      {
        name: 'allow_filegen_from_vnet'
        properties: {
          priority: 200
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Tcp'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRanges: ['8443', '9182']
        }
      }
    ]
  }
}

resource peNsg 'Microsoft.Network/networkSecurityGroups@2024-01-01' = {
  name: peNsgName
  location: location
  tags: tags
  properties: {
    securityRules: []
  }
}

// -----------------------------------------------------------------------------
// Route table required for SQL MI subnet (must permit Internet next hop).
// -----------------------------------------------------------------------------

resource sqlMiRouteTable 'Microsoft.Network/routeTables@2024-01-01' = {
  name: sqlMiRouteTableName
  location: location
  tags: tags
  properties: {
    disableBgpRoutePropagation: false
    routes: [
      {
        name: 'default_internet'
        properties: {
          addressPrefix: '0.0.0.0/0'
          nextHopType: 'Internet'
        }
      }
    ]
  }
}

// -----------------------------------------------------------------------------
// VNet
// -----------------------------------------------------------------------------

resource vnet 'Microsoft.Network/virtualNetworks@2024-01-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: ['10.20.0.0/16']
    }
    subnets: [
      {
        name: 'snet-sqlmi'
        properties: {
          addressPrefix: '10.20.1.0/27'
          networkSecurityGroup: { id: sqlMiNsg.id }
          routeTable: { id: sqlMiRouteTable.id }
          delegations: [
            {
              name: 'sqlmi-delegation'
              properties: {
                serviceName: 'Microsoft.Sql/managedInstances'
              }
            }
          ]
        }
      }
      {
        name: 'snet-app'
        properties: {
          addressPrefix: '10.20.2.0/24'
          networkSecurityGroup: { id: appNsg.id }
        }
      }
      {
        name: 'snet-pe'
        properties: {
          addressPrefix: '10.20.3.0/24'
          networkSecurityGroup: { id: peNsg.id }
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
      {
        name: 'snet-appsvc-int'
        properties: {
          addressPrefix: '10.20.4.0/26'
          delegations: [
            {
              name: 'appsvc-delegation'
              properties: {
                serviceName: 'Microsoft.Web/serverFarms'
              }
            }
          ]
        }
      }
    ]
  }
}

// -----------------------------------------------------------------------------
// Private DNS zones (linked to VNet).
// -----------------------------------------------------------------------------

resource pdnsKeyVault 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'privatelink.vaultcore.azure.net'
  location: 'global'
  tags: tags
}

resource pdnsAppService 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'privatelink.azurewebsites.net'
  location: 'global'
  tags: tags
}

resource pdnsKeyVaultLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: pdnsKeyVault
  name: 'link-${vnetName}'
  location: 'global'
  tags: tags
  properties: {
    registrationEnabled: false
    virtualNetwork: { id: vnet.id }
  }
}

resource pdnsAppServiceLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: pdnsAppService
  name: 'link-${vnetName}'
  location: 'global'
  tags: tags
  properties: {
    registrationEnabled: false
    virtualNetwork: { id: vnet.id }
  }
}

// -----------------------------------------------------------------------------
// Outputs
// -----------------------------------------------------------------------------

output vnetId string = vnet.id
output vnetName string = vnet.name
output sqlMiSubnetId string = '${vnet.id}/subnets/snet-sqlmi'
output appSubnetId string = '${vnet.id}/subnets/snet-app'
output peSubnetId string = '${vnet.id}/subnets/snet-pe'
output appSvcIntSubnetId string = '${vnet.id}/subnets/snet-appsvc-int'
output keyVaultPrivateDnsZoneId string = pdnsKeyVault.id
