// AKS-Arc provisioned cluster on the ALDO stamp.
// Two nodepools:
//   - system: general-purpose nodes for control plane + system pods
//   - gpu:    A100-passthrough nodes for Foundry Local inference
// Node OS: Mariner Linux 3 (baked into the AKS-Arc extension).

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

@description('Kubernetes version supported by the ALDO stamp AKS-Arc extension.')
param kubernetesVersion string = '1.29.4'

@description('System nodepool VM size.')
param systemVmSize string = 'Standard_A4_v2'

@description('System nodepool node count.')
param systemNodeCount int = 3

@description('GPU nodepool VM size with A100 passthrough.')
param gpuVmSize string = 'Standard_NC24ads_A100_v4'

@description('GPU nodepool node count.')
param gpuNodeCount int = 2

var clusterName = '${namePrefix}-aks'
var logicalNetworkId = resourceId(logicalNetworkResourceGroup, 'Microsoft.AzureStackHCI/logicalNetworks', logicalNetworkName)

resource connectedCluster 'Microsoft.Kubernetes/connectedClusters@2024-01-01' = {
  name: clusterName
  location: location
  tags: tags
  kind: 'ProvisionedCluster'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    agentPublicKeyCertificate: ''
    aadProfile: {
      enableAzureRBAC: false
    }
    distribution: 'aks_edge'
    infrastructure: 'azure_stack_hci'
  }
}

resource provisionedCluster 'Microsoft.HybridContainerService/provisionedClusterInstances@2024-01-01' = {
  scope: connectedCluster
  name: 'default'
  extendedLocation: {
    type: 'CustomLocation'
    name: customLocationId
  }
  properties: {
    agentPoolProfiles: []
    cloudProviderProfile: {
      infraNetworkProfile: {
        vnetSubnetIds: [ logicalNetworkId ]
      }
    }
    clusterVMAccessProfile: {}
    controlPlane: {
      count: 1
      vmSize: systemVmSize
    }
    kubernetesVersion: kubernetesVersion
    licenseProfile: {
      azureHybridBenefit: 'False'
    }
    linuxProfile: {
      ssh: {
        publicKeys: []
      }
    }
    networkProfile: {
      loadBalancerProfile: {
        count: 0
      }
      networkPolicy: 'calico'
      podCidr: '10.244.0.0/16'
    }
    storageProfile: {
      nfsCsiDriver: { enabled: false }
      smbCsiDriver: { enabled: false }
    }
  }
}

resource systemNodepool 'Microsoft.HybridContainerService/provisionedClusterInstances/agentPools@2024-01-01' = {
  parent: provisionedCluster
  name: 'system'
  extendedLocation: {
    type: 'CustomLocation'
    name: customLocationId
  }
  properties: {
    osType: 'Linux'
    osSKU: 'CBLMariner'
    vmSize: systemVmSize
    count: systemNodeCount
    nodeLabels: {
      workload: 'system'
    }
  }
}

resource gpuNodepool 'Microsoft.HybridContainerService/provisionedClusterInstances/agentPools@2024-01-01' = {
  parent: provisionedCluster
  name: 'gpu'
  extendedLocation: {
    type: 'CustomLocation'
    name: customLocationId
  }
  properties: {
    osType: 'Linux'
    osSKU: 'CBLMariner'
    vmSize: gpuVmSize
    count: gpuNodeCount
    nodeLabels: {
      'htx.aldo/gpu': 'a100'
      'htx.aldo/stamp': 'tokyo-wkld'
      workload: 'inference'
    }
    nodeTaints: [
      'nvidia.com/gpu=true:NoSchedule'
    ]
  }
  dependsOn: [
    systemNodepool
  ]
}

output connectedClusterName string = connectedCluster.name
output connectedClusterId string = connectedCluster.id
output provisionedClusterId string = provisionedCluster.id
