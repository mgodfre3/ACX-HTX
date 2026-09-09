@description('Azure region.')
param location string

@description('Short name prefix.')
param namePrefix string

@description('Tags applied to every resource.')
param tags object

@description('KEK name inside the vault (application-data KEK — used by the storage/disk/ACR CMK path in the prior demo iteration).')
param kekName string = 'htx-kek'

@description('OS/attestation key name — dedicated to gating CVM startup. NEVER used to protect customer application data. Kept distinct from kekName so the "Azure Key Vault does not hold the data key" narrative is provable by inspection.')
param cvmAttestationKeyName string = 'acxhtx-cvm-attestation-key'

@description('Subnet resource ID for the private endpoint.')
param workloadSubnetId string

var vaultName = toLower('${namePrefix}-kv-${uniqueString(resourceGroup().id)}')
var peName = '${vaultName}-pe'

resource vault 'Microsoft.KeyVault/vaults@2024-04-01-preview' = {
  name: vaultName
  location: location
  tags: tags
  properties: {
    sku: {
      family: 'A'
      name: 'premium'
    }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    enablePurgeProtection: true
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
    }
  }
}

resource kek 'Microsoft.KeyVault/vaults/keys@2024-04-01-preview' = {
  parent: vault
  name: kekName
  tags: union(tags, {
    // NOTE: This key shares a name with the on-prem Vault Transit key by
    // historical accident. It protects only the burst CVM's OS disk (via the
    // Disk Encryption Set) and Azure Container Registry storage. It does NOT
    // protect customer application data. The Act 1 demo walkthrough points at
    // these tags to prove this. See docs/demo-storyboard.md and
    // docs/burst-cvm-architecture.md for the sovereignty narrative.
    Purpose: 'osdisk-and-acr-cmk'
    'Not-Used-For': 'customer-application-data'
    'Customer-Data-Key-Location': 'on-prem Vault Transit (172.22.218.200)'
  })
  properties: {
    kty: 'RSA-HSM'
    keySize: 3072
    keyOps: [
      'wrapKey'
      'unwrapKey'
      'encrypt'
      'decrypt'
    ]
    attributes: {
      enabled: true
      exportable: false
    }
  }
}

// OS / attestation-gating key for the burst CVM demo.
// Deliberately separate from the KEK. Purpose is limited to gating CVM boot
// (e.g., disk-encryption-set attached to a Confidential DES using this key)
// so that on-stage a reviewer can see two distinct keys and understand that
// the AKV key never touches customer application data.
resource cvmAttestationKey 'Microsoft.KeyVault/vaults/keys@2024-04-01-preview' = {
  parent: vault
  name: cvmAttestationKeyName
  tags: union(tags, {
    Purpose: 'cvm-os-attestation'
  })
  properties: {
    kty: 'RSA-HSM'
    keySize: 3072
    keyOps: [
      'wrapKey'
      'unwrapKey'
    ]
    attributes: {
      enabled: true
      exportable: false
    }
  }
}

resource pe 'Microsoft.Network/privateEndpoints@2023-11-01' = {
  name: peName
  location: location
  tags: tags
  properties: {
    subnet: {
      id: workloadSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: 'kv-plsc'
        properties: {
          privateLinkServiceId: vault.id
          groupIds: [ 'vault' ]
        }
      }
    ]
  }
}

output keyVaultName string = vault.name
output keyVaultId string = vault.id
output keyVaultUri string = vault.properties.vaultUri
output kekName string = kek.name
output kekUri string = kek.properties.keyUri
output kekUriWithVersion string = kek.properties.keyUriWithVersion
output cvmAttestationKeyName string = cvmAttestationKey.name
output cvmAttestationKeyUri string = cvmAttestationKey.properties.keyUri
output cvmAttestationKeyUriWithVersion string = cvmAttestationKey.properties.keyUriWithVersion
output privateEndpointId string = pe.id
