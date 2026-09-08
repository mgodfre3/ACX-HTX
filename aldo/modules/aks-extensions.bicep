// AKS-Arc cluster extensions - matches the MWC26 demo pattern.
//
// Stack (order matters):
//   1. Microsoft.CertManagement - prereq for Foundry
//   2. NVIDIA GPU Operator - A100 device plugin
//   3. KV Secrets Store CSI - workload pods mount secrets from local Vault
//   4. Azure Monitor - cluster/GPU/inference metrics
//   5. Microsoft.Foundry - Foundry Local operator + CRDs (namespace: foundry-local-operator)
//   6. Flux - GitOps binding to this repo (delivers ModelDeployment CRs from arc-aks/)

@description('AKS-Arc cluster name (Microsoft.Kubernetes/connectedClusters).')
param aksArcClusterName string

@description('Microsoft Entra tenant ID (for Foundry extension EntraAuth).')
param entraTenantId string

@description('Microsoft Entra client (application) ID authorized to call Foundry endpoints.')
param entraClientId string

resource cluster 'Microsoft.Kubernetes/connectedClusters@2024-01-01' existing = {
  name: aksArcClusterName
}

// 1. CertManagement - required prereq for Microsoft.Foundry
resource certManagement 'Microsoft.KubernetesConfiguration/extensions@2024-11-01' = {
  scope: cluster
  name: 'azure-cert-manager'
  properties: {
    extensionType: 'Microsoft.CertManagement'
    autoUpgradeMinorVersion: true
    releaseTrain: 'Stable'
    scope: {
      cluster: {
        releaseNamespace: 'cert-manager'
      }
    }
  }
}

// 2. NVIDIA GPU Operator for A100 passthrough
resource gpuOperator 'Microsoft.KubernetesConfiguration/extensions@2024-11-01' = {
  scope: cluster
  name: 'nvidia-gpu-operator'
  properties: {
    extensionType: 'microsoft.arcgpu.nvidiadeviceplugin'
    autoUpgradeMinorVersion: true
    releaseTrain: 'stable'
    scope: {
      cluster: {
        releaseNamespace: 'gpu-resources'
      }
    }
  }
}

// 3. KV Secrets Store CSI - workload pods can mount secrets from the local Vault
resource kvCsi 'Microsoft.KubernetesConfiguration/extensions@2024-11-01' = {
  scope: cluster
  name: 'azure-keyvault-secrets-provider'
  properties: {
    extensionType: 'microsoft.azurekeyvaultsecretsprovider'
    autoUpgradeMinorVersion: true
    releaseTrain: 'stable'
    scope: {
      cluster: {
        releaseNamespace: 'kube-system'
      }
    }
    configurationSettings: {
      'secrets-store-csi-driver.syncSecret.enabled': 'true'
      'secrets-store-csi-driver.enableSecretRotation': 'true'
    }
  }
}

// 4. Azure Monitor for containers - cluster + GPU + inference metrics
resource azureMonitor 'Microsoft.KubernetesConfiguration/extensions@2024-11-01' = {
  scope: cluster
  name: 'azuremonitor-containers'
  properties: {
    extensionType: 'microsoft.azuremonitor.containers'
    autoUpgradeMinorVersion: true
    releaseTrain: 'stable'
    scope: {
      cluster: {
        releaseNamespace: 'azuremonitor'
      }
    }
  }
}

// 5. Microsoft.Foundry - Foundry Local operator + CRDs
// This is the same extension used by the MWC26 demo (see MWC repo docs/foundry-arc-extension-migration.md).
// It creates namespace 'foundry-local-operator' and installs the ModelDeployment/Model/StoreModel CRDs.
resource foundry 'Microsoft.KubernetesConfiguration/extensions@2024-11-01' = {
  scope: cluster
  name: 'inference-operator'
  properties: {
    extensionType: 'Microsoft.Foundry'
    autoUpgradeMinorVersion: true
    releaseTrain: 'stable'
    scope: {
      cluster: {
        releaseNamespace: 'foundry-local-operator'
      }
    }
    configurationSettings: {
      'entraAuth.tenantId': entraTenantId
      'entraAuth.clientId': entraClientId
    }
  }
  dependsOn: [
    certManagement
    gpuOperator
  ]
}

// 6. Flux - GitOps binding to this repo (delivers ModelDeployment CRs from arc-aks/)
resource flux 'Microsoft.KubernetesConfiguration/extensions@2024-11-01' = {
  scope: cluster
  name: 'flux'
  properties: {
    extensionType: 'microsoft.flux'
    autoUpgradeMinorVersion: true
    releaseTrain: 'stable'
    scope: {
      cluster: {
        releaseNamespace: 'flux-system'
      }
    }
    configurationSettings: {
      'multiTenancy.enforce': 'false'
    }
  }
}

resource fluxConfig 'Microsoft.KubernetesConfiguration/fluxConfigurations@2024-11-01' = {
  scope: cluster
  name: 'htx-workloads'
  properties: {
    scope: 'cluster'
    namespace: 'foundry-local-operator'
    sourceKind: 'GitRepository'
    gitRepository: {
      url: 'https://github.com/mgodfre3/ACX-HTX'
      repositoryRef: {
        branch: 'master'
      }
      timeoutInSeconds: 600
      syncIntervalInSeconds: 300
    }
    kustomizations: {
      foundryLocal: {
        path: './arc-aks/foundry-local'
        dependsOn: []
        timeoutInSeconds: 600
        syncIntervalInSeconds: 300
        retryIntervalInSeconds: 300
        prune: true
        force: false
      }
    }
  }
  dependsOn: [
    flux
    foundry
  ]
}

output extensionNames array = [
  certManagement.name
  gpuOperator.name
  kvCsi.name
  azureMonitor.name
  foundry.name
  flux.name
]
output fluxConfigName string = fluxConfig.name
