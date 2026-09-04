@description('Azure region.')
param location string

@description('Short name prefix.')
param namePrefix string

@description('Tags applied to every resource.')
param tags object

@description('Existing Key Vault name (RBAC-enabled).')
param keyVaultName string

var storageIdentityName = '${namePrefix}-mi-storage'

// Built-in role IDs
var roleKvCryptoServiceEncryptionUser = '/subscriptions/${subscription().subscriptionId}/providers/Microsoft.Authorization/roleDefinitions/e147488a-f6f5-4113-8e2d-b22465e65bf6'

resource storageIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: storageIdentityName
  location: location
  tags: tags
}

resource kv 'Microsoft.KeyVault/vaults@2024-04-01-preview' existing = {
  name: keyVaultName
}

// Storage MI needs to wrap/unwrap the CMK inside AKV
resource storageMiKvRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: kv
  name: guid(kv.id, storageIdentity.id, 'kv-encryption-user')
  properties: {
    roleDefinitionId: roleKvCryptoServiceEncryptionUser
    principalId: storageIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

output storageIdentityId string = storageIdentity.id
output storageIdentityPrincipalId string = storageIdentity.properties.principalId
output storageIdentityClientId string = storageIdentity.properties.clientId
