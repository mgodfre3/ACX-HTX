// Optional Windows Server 2022 jumpbox on the ALDO stamp.

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

@description('Gallery image resource ID for Windows Server 2022.')
param windowsGalleryImageId string

@description('Local admin username.')
param adminUsername string

@secure()
@description('Local admin password.')
param adminPassword string

@description('VM size.')
param vmSize string = 'Standard_A4_v2'

var vmName = '${namePrefix}-jumpbox'
var nicName = '${vmName}-nic'

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

resource nic 'Microsoft.AzureStackHCI/networkInterfaces@2024-01-01' = {
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

resource vmInstance 'Microsoft.AzureStackHCI/virtualMachineInstances@2024-01-01' = {
  scope: arcMachine
  name: 'default'
  extendedLocation: {
    type: 'CustomLocation'
    name: customLocationId
  }
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      adminUsername: adminUsername
      adminPassword: adminPassword
      computerName: 'htxjumpbox'
      windowsConfiguration: {
        provisionVMAgent: true
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
output privateIpAddress string = nic.properties.ipConfigurations[0].properties.privateIPAddress
