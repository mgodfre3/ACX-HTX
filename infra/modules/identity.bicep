@description('Azure region.')
param location string

@description('Short name prefix.')
param namePrefix string

@description('Tags applied to every resource.')
param tags object

@description('Existing Key Vault name (RBAC-enabled).')
param keyVaultName string

@description('If true, deploy the storage-related identities (storage CMK MI + producer MI) alongside the storage plane. When false, only ACR/other identities remain.')
param deployStorageIdentities bool = false

var storageIdentityName = '${namePrefix}-mi-storage'
var producerIdentityName = '${namePrefix}-producer-mi'

// Built-in role IDs
var roleKvCryptoServiceEncryptionUser = '/subscriptions/${subscription().subscriptionId}/providers/Microsoft.Authorization/roleDefinitions/e147488a-f6f5-4113-8e2d-b22465e65bf6'

resource storageIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = if (deployStorageIdentities) {
  name: storageIdentityName
  location: location
  tags: tags
}

// Producer identity — dedicated to the scheduled producer job on the jump host.
// Grants ONLY Storage Blob Data Contributor scoped to the sovereign-encrypted container
// (role assignment lives in storage.bicep so it can reference the container resource directly).
resource producerIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = if (deployStorageIdentities) {
  name: producerIdentityName
  location: location
  tags: tags
}

resource kv 'Microsoft.KeyVault/vaults@2024-04-01-preview' existing = {
  name: keyVaultName
}

// Storage MI needs to wrap/unwrap the CMK inside AKV
resource storageMiKvRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployStorageIdentities) {
  scope: kv
  name: guid(kv.id, storageIdentity!.id, 'kv-encryption-user')
  properties: {
    roleDefinitionId: roleKvCryptoServiceEncryptionUser
    principalId: storageIdentity!.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

output storageIdentityId string = deployStorageIdentities ? storageIdentity!.id : ''
output storageIdentityPrincipalId string = deployStorageIdentities ? storageIdentity!.properties.principalId : ''
output storageIdentityClientId string = deployStorageIdentities ? storageIdentity!.properties.clientId : ''
output producerIdentityId string = deployStorageIdentities ? producerIdentity!.id : ''
output producerIdentityPrincipalId string = deployStorageIdentities ? producerIdentity!.properties.principalId : ''
output producerIdentityClientId string = deployStorageIdentities ? producerIdentity!.properties.clientId : ''
