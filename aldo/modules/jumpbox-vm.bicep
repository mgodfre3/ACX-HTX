// Optional Windows Server 2025 jumpbox on the ALDO stamp.
// Uses Microsoft.AzureStackHCI/virtualMachineInstances - Azure Local schema.

@description('Azure region ARM metadata.')
param location string

@description('Short name prefix.')
param namePrefix string

@description('Tags applied to every resource.')
param tags object

@description('Custom Location resource ID.')
param customLocationId string

@description('Existing logical network name.')
param logicalNetworkName string

@description('Resource group containing the logical network.')
param logicalNetworkResourceGroup string

@description('Gallery image resource ID for Windows Server 2025.')
param windowsGalleryImageId string

@description('Local admin username.')
param adminUsername string

@secure()
@description('Local admin password.')
param adminPassword string

@description('vCPU count.')
param processorCount int = 4

@description('Memory in MB.')
param memoryMB int = 8192

var vmName = '${namePrefix}-jumpbox'
var nicName = '${vmName}-nic'

resource nic 'Microsoft.AzureStackHCI/networkInterfaces@2025-02-01-preview' = {
  name: nicName
  location: location
  tags: tags
  extendedLocation: {
    type: 'CustomLocation'
    name: customLocationId
  }
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: resourceId(logicalNetworkResourceGroup, 'Microsoft.AzureStackHCI/logicalNetworks', logicalNetworkName)
          }
        }
      }
    ]
  }
}

resource arcMachine 'Microsoft.HybridCompute/machines@2024-07-10' = {
  name: vmName
  location: location
  tags: tags
  kind: 'AzureStackHCI'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {}
}

resource vmInstance 'Microsoft.AzureStackHCI/virtualMachineInstances@2025-02-01-preview' = {
  scope: arcMachine
  name: 'default'
  extendedLocation: {
    type: 'CustomLocation'
    name: customLocationId
  }
  properties: {
    hardwareProfile: {
      processors: processorCount
      memoryMB: memoryMB
    }
    osProfile: {
      adminUsername: adminUsername
      adminPassword: adminPassword
      computerName: 'htxjumpbox'
      windowsConfiguration: {
        provisionVMAgent: true
        provisionVMConfigAgent: true
        enableAutomaticUpdates: true
      }
    }
    storageProfile: {
      imageReference: {
        id: windowsGalleryImageId
      }
      osDisk: {
        osType: 'Windows'
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
        }
      ]
    }
    securityProfile: {
      enableTPM: true
    }
  }
}

output vmName string = arcMachine.name
