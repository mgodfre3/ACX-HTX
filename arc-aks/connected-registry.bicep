// Connected Registry pattern: sync token + scope map + connected registry itself.
// Deployed to the Azure side only; the on-prem mirror is deployed to the ALDO stamp
// separately using `az acr connected-registry install`.

@description('Sovereign ACR name (from foundry.bicep output).')
param acrName string

@description('Name for the on-prem mirror (matches the identity used on the ALDO stamp).')
param mirrorName string = 'aldo-tokyo-wkld'

resource acr 'Microsoft.ContainerRegistry/registries@2023-11-01-preview' existing = {
  name: acrName
}

resource scopeMap 'Microsoft.ContainerRegistry/registries/scopeMaps@2023-11-01-preview' = {
  parent: acr
  name: '${mirrorName}-scope'
  properties: {
    description: 'ALDO stamp ${mirrorName} — read-only pull of HTX models'
    actions: [
      'repositories/models/htx-antenna-detector/content/read'
      'repositories/models/htx-antenna-detector/metadata/read'
      'gateway/${mirrorName}/config/read'
      'gateway/${mirrorName}/message/read'
      'gateway/${mirrorName}/message/write'
    ]
  }
}

resource syncToken 'Microsoft.ContainerRegistry/registries/tokens@2023-11-01-preview' = {
  parent: acr
  name: '${mirrorName}-token'
  properties: {
    scopeMapId: scopeMap.id
    status: 'enabled'
  }
}

resource connectedRegistry 'Microsoft.ContainerRegistry/registries/connectedRegistries@2023-11-01-preview' = {
  parent: acr
  name: mirrorName
  properties: {
    mode: 'ReadOnly'
    parent: {
      syncProperties: {
        tokenId: syncToken.id
        // Sync every 30 min; mirror caches locally for offline serving
        schedule: '0 */30 * * * *'
        // Keep at most 7 days of cached images on the mirror
        messageTtl: 'P7D'
        syncWindow: 'PT4H'
      }
    }
  }
}

output connectedRegistryName string = connectedRegistry.name
output syncTokenName string = syncToken.name
output installCommand string = 'az acr connected-registry install info --registry ${acrName} --name ${mirrorName}'
