// ACX_HTX_Contributor Entra group role assignments on both Key Vaults.
// The group itself is Entra-scoped and pre-created via portal or:
//   az ad group create --display-name ACX_HTX_Contributor --mail-nickname acx-htx-contributor
//
// Roles granted per vault:
//   - Key Vault Secrets User: get/list secrets (for app secrets stored in KV)
//   - Key Vault Crypto User:  get/list keys + wrap/unwrap/encrypt/decrypt/sign/verify
//                             (needed for the demo to show customer key custody)

@description('Object ID of the ACX_HTX_Contributor Entra security group.')
param contributorGroupObjectId string

@description('Name of the sovereign Key Vault (holds htx-kek).')
param sovereignKeyVaultName string

@description('Name of the Foundry hub associated Key Vault.')
param foundryKeyVaultName string

// Built-in role definition IDs
var roleKvSecretsUser = '/subscriptions/${subscription().subscriptionId}/providers/Microsoft.Authorization/roleDefinitions/4633458b-17de-408a-b874-0445c86b69e6'
var roleKvCryptoUser  = '/subscriptions/${subscription().subscriptionId}/providers/Microsoft.Authorization/roleDefinitions/12338af0-0e69-4776-bea7-57ae8d297424'

resource sovereignKv 'Microsoft.KeyVault/vaults@2024-04-01-preview' existing = {
  name: sovereignKeyVaultName
}

resource foundryKv 'Microsoft.KeyVault/vaults@2024-04-01-preview' existing = {
  name: foundryKeyVaultName
}

resource sovKvSecretsRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: sovereignKv
  name: guid(sovereignKv.id, contributorGroupObjectId, 'kv-secrets-user')
  properties: {
    roleDefinitionId: roleKvSecretsUser
    principalId: contributorGroupObjectId
    principalType: 'Group'
  }
}

resource sovKvCryptoRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: sovereignKv
  name: guid(sovereignKv.id, contributorGroupObjectId, 'kv-crypto-user')
  properties: {
    roleDefinitionId: roleKvCryptoUser
    principalId: contributorGroupObjectId
    principalType: 'Group'
  }
}

resource fdyKvSecretsRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: foundryKv
  name: guid(foundryKv.id, contributorGroupObjectId, 'kv-secrets-user')
  properties: {
    roleDefinitionId: roleKvSecretsUser
    principalId: contributorGroupObjectId
    principalType: 'Group'
  }
}

resource fdyKvCryptoRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: foundryKv
  name: guid(foundryKv.id, contributorGroupObjectId, 'kv-crypto-user')
  properties: {
    roleDefinitionId: roleKvCryptoUser
    principalId: contributorGroupObjectId
    principalType: 'Group'
  }
}

output rolesAssigned array = [
  'Key Vault Secrets User on ${sovereignKeyVaultName}'
  'Key Vault Crypto User on ${sovereignKeyVaultName}'
  'Key Vault Secrets User on ${foundryKeyVaultName}'
  'Key Vault Crypto User on ${foundryKeyVaultName}'
]
