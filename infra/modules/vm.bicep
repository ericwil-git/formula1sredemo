// =============================================================================
// VM — Windows Server 2022 Datacenter Azure Edition, Standard_D2s_v5.
// Not domain-joined. System-assigned managed identity.
// Includes Azure Monitor Agent extension and DCR association.
// =============================================================================

targetScope = 'resourceGroup'

@description('Azure region.')
param location string

@description('Name prefix.')
param namePrefix string

@description('Resource tags.')
param tags object

@description('Resource ID of the app subnet.')
param appSubnetId string

@description('Local admin username.')
param adminUsername string

@description('Local admin password.')
@secure()
param adminPassword string

@description('Resource ID of the Data Collection Rule (from monitoring module).')
param dataCollectionRuleId string

var vmName = 'vm-${namePrefix}-win'
var nicName = 'nic-${vmName}'
var pipName = 'pip-${vmName}'
var dataDiskName = 'disk-${vmName}-data'

resource pip 'Microsoft.Network/publicIPAddresses@2024-01-01' = {
  name: pipName
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
    idleTimeoutInMinutes: 4
  }
}

resource nic 'Microsoft.Network/networkInterfaces@2024-01-01' = {
  name: nicName
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: { id: appSubnetId }
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: { id: pip.id }
        }
      }
    ]
  }
}

resource dataDisk 'Microsoft.Compute/disks@2024-03-02' = {
  name: dataDiskName
  location: location
  tags: tags
  sku: {
    name: 'Premium_LRS'
  }
  properties: {
    creationData: {
      createOption: 'Empty'
    }
    diskSizeGB: 128
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2024-03-01' = {
  name: vmName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    hardwareProfile: {
      vmSize: 'Standard_D2s_v5'
    }
    osProfile: {
      computerName: 'vmf1demo'
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        provisionVMAgent: true
        enableAutomaticUpdates: true
        patchSettings: {
          patchMode: 'AutomaticByOS'
        }
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: '2022-datacenter-azure-edition'
        version: 'latest'
      }
      osDisk: {
        name: 'disk-${vmName}-os'
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
        caching: 'ReadWrite'
      }
      dataDisks: [
        {
          lun: 0
          name: dataDiskName
          createOption: 'Attach'
          managedDisk: {
            id: dataDisk.id
          }
          caching: 'ReadOnly'
        }
      ]
    }
    networkProfile: {
      networkInterfaces: [
        { id: nic.id }
      ]
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
  }
}

// -----------------------------------------------------------------------------
// Azure Monitor Agent
// -----------------------------------------------------------------------------

resource ama 'Microsoft.Compute/virtualMachines/extensions@2024-03-01' = {
  parent: vm
  name: 'AzureMonitorWindowsAgent'
  location: location
  tags: tags
  properties: {
    publisher: 'Microsoft.Azure.Monitor'
    type: 'AzureMonitorWindowsAgent'
    typeHandlerVersion: '1.10'
    autoUpgradeMinorVersion: true
    enableAutomaticUpgrade: true
    settings: {}
  }
}

// Data Collection Rule association — must be a top-level resource scoped to
// the VM. Built using the extensionResourceId pattern.
resource dcra 'Microsoft.Insights/dataCollectionRuleAssociations@2023-03-11' = {
  name: 'dcra-${vmName}'
  scope: vm
  properties: {
    dataCollectionRuleId: dataCollectionRuleId
    description: 'Associate VM with the demo DCR.'
  }
  dependsOn: [
    ama
  ]
}

output vmName string = vm.name
output vmId string = vm.id
output principalId string = vm.identity.principalId
output privateIp string = nic.properties.ipConfigurations[0].properties.privateIPAddress
output publicIp string = pip.properties.ipAddress
