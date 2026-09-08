// Ubuntu 24.04 VM running HashiCorp Vault as the sovereign local key vault.
// Uses Microsoft.AzureStackHCI/virtualMachineInstances - Azure Local schema, NOT Azure schema.
// Reference: https://learn.microsoft.com/en-us/azure/templates/microsoft.azurestackhci/virtualmachineinstances

@description('Azure region ARM metadata. ALDO stamps use Autonomous.')
param location string

@description('Short name prefix.')
param namePrefix string

@description('Tags applied to every resource.')
param tags object

@description('Custom Location resource ID of the ALDO stamp.')
param customLocationId string

@description('Existing logical network name.')
param logicalNetworkName string

@description('Resource group containing the logical network.')
param logicalNetworkResourceGroup string

@description('Gallery image resource ID for Ubuntu 24.04.')
param ubuntuGalleryImageId string

@description('Admin username for the VM.')
param adminUsername string

@description('SSH public key for the admin user.')
param adminSshPublicKey string

@description('vCPU count (Azure Local sizes VMs by memoryMB + processors, not vmSize).')
param processorCount int = 4

@description('Memory in MB.')
param memoryMB int = 8192

var vmName = '${namePrefix}-vault'
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

// Arc-projected machine (host of the VM instance)
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

// The VM instance itself - Azure Local schema
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
      computerName: 'htxvault'
      linuxConfiguration: {
        disablePasswordAuthentication: true
        provisionVMAgent: true
        provisionVMConfigAgent: true
        ssh: {
          publicKeys: [
            {
              keyData: adminSshPublicKey
              path: '/home/${adminUsername}/.ssh/authorized_keys'
            }
          ]
        }
      }
    }
    storageProfile: {
      imageReference: {
        id: ubuntuGalleryImageId
      }
      osDisk: {
        osType: 'Linux'
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
output arcMachineId string = arcMachine.id
output arcMachinePrincipalId string = arcMachine.identity.principalId
