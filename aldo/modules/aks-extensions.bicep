// AKS-Arc cluster extensions.

@description('AKS-Arc cluster name.')
param aksArcClusterName string

resource cluster 'Microsoft.Kubernetes/connectedClusters@2024-01-01' existing = {
  name: aksArcClusterName
}

// NVIDIA GPU Operator for A100 passthrough
resource gpuOperator 'Microsoft.KubernetesConfiguration/extensions@2024-04-01-preview' = {
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

// KV Secrets Store CSI - workload pods mount secrets from the local Vault
resource kvCsi 'Microsoft.KubernetesConfiguration/extensions@2024-04-01-preview' = {
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

// Azure Monitor for cluster + GPU + inference metrics
resource azureMonitor 'Microsoft.KubernetesConfiguration/extensions@2024-04-01-preview' = {
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

// Flux GitOps - drives model rollout via new commits to arc-aks/
resource flux 'Microsoft.KubernetesConfiguration/extensions@2024-04-01-preview' = {
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

resource fluxConfig 'Microsoft.KubernetesConfiguration/fluxConfigurations@2024-04-01-preview' = {
  scope: cluster
  name: 'htx-workloads'
  properties: {
    scope: 'cluster'
    namespace: 'htx-foundry-local'
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
        path: './arc-aks'
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
  ]
}

output extensionNames array = [
  gpuOperator.name
  kvCsi.name
  azureMonitor.name
  flux.name
]
output fluxConfigName string = fluxConfig.name
