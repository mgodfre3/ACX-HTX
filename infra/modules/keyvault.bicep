@description('Azure region.')
param location string

@description('Short name prefix.')
param namePrefix string

@description('Tags applied to every resource.')
param tags object

@description('KEK name inside the vault.')
param kekName string = 'htx-kek'

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
  tags: tags
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
output privateEndpointId string = pe.id
