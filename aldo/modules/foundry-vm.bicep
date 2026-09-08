// Windows Server 2025 VM on ALDO with A100 GPU passthrough (Discrete Device Assignment).
// Runs Foundry Local for sovereign on-prem inference (Phi-4 + HTX antenna detector).
//
// Follows the Azure Local hardwareProfile.virtualMachineGPUs schema for DDA:
//   https://learn.microsoft.com/en-us/azure/templates/microsoft.azurestackhci/virtualmachineinstances

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

@description('Gallery image resource ID for Windows Server 2025.')
param windowsGalleryImageId string

@description('Local admin username.')
param adminUsername string

@secure()
@description('Local admin password.')
param adminPassword string

@description('vCPU count.')
param processorCount int = 16

@description('Memory in MB (32 GB default).')
param memoryMB int = 32768

@description('GPU name as reported by Get-VMHostPartitionableGpu on the ALDO cluster. Blank = no GPU (falls back to CPU-only Foundry Local).')
param gpuName string = ''

@description('GPU assignment type: DDA (whole GPU) or GpuP (partitioned).')
@allowed([
  'GpuDDA'
  'GpuP'
])
param gpuAssignmentType string = 'GpuDDA'

@description('Partition size in MB when using GpuP. Ignored for GpuDDA. Set to your A100 partition size (e.g. 20480 for 20GB slice).')
param gpuPartitionSizeMB int = 0

var vmName = '${namePrefix}-foundry'
var nicName = '${vmName}-nic'

var gpuArray = empty(gpuName) ? [] : [
  {
    gpuName: gpuName
    assignmentType: gpuAssignmentType
    partitionSizeMB: gpuAssignmentType == 'GpuP' ? gpuPartitionSizeMB : null
  }
]

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
  kind: 'HCI'
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
      virtualMachineGPUs: gpuArray
    }
    osProfile: {
      adminUsername: adminUsername
      adminPassword: adminPassword
      computerName: 'htxfoundry'
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
output arcMachineId string = arcMachine.id
output arcMachinePrincipalId string = arcMachine.identity.principalId
