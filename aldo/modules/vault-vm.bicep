// Ubuntu 22.04 VM running HashiCorp Vault as the sovereign local key vault.
// Holds the on-prem mirror of htx-kek. Serves KMS to Arc-AKS etcd encryption,
// KV Secrets Store CSI to workload pods, and model-signing keys for the mirror.

@description('Azure region ARM metadata.')
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

@description('Gallery image resource ID for Ubuntu 22.04.')
param ubuntuGalleryImageId string

@description('Admin username for the VM.')
param adminUsername string

@description('SSH public key for the admin user.')
param adminSshPublicKey string

@description('VM size class (Azure Local sizing).')
param vmSize string = 'Standard_A4_v2'

var vmName = '${namePrefix}-vault'
var nicName = '${vmName}-nic'

// NOTE: Azure Local VirtualMachineInstance doesn't expose userData/customData
// in the current ARM surface for Linux. Vault installation is done post-boot
// by SSH'ing in and running aldo/scripts/init-vault.sh - documented in aldo/README.md.

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
      computerName: 'htxvault'
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              keyData: adminSshPublicKey
              path: '/home/${adminUsername}/.ssh/authorized_keys'
            }
          ]
        }
        provisionVMAgent: true
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
output privateIpAddress string = nic.properties.ipConfigurations[0].properties.privateIPAddress
output arcMachineId string = arcMachine.id
output arcMachinePrincipalId string = arcMachine.identity.principalId
