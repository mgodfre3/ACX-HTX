@description('Azure region.')
param location string

@description('Short name prefix.')
param namePrefix string

@description('Tags applied to every resource.')
param tags object

@description('KEK URL with version for CMK.')
param kekUriWithVersion string

@description('Key Vault name that holds the KEK (used to grant ACR MI encryption rights).')
param keyVaultName string

var suffix = uniqueString(resourceGroup().id)
var hubStorageName = toLower('${namePrefix}fdystg${substring(suffix, 0, 8)}')
var hubKvName = toLower('${namePrefix}-fdy-kv-${substring(suffix, 0, 6)}')
var hubAiName = toLower('${namePrefix}-fdy-ai-${substring(suffix, 0, 6)}')
var acrName = toLower('${namePrefix}acr${substring(suffix, 0, 8)}')
var acrMiName = '${namePrefix}-acr-mi'
var hubName = '${namePrefix}-foundry-hub'
var projectName = '${namePrefix}-foundry-proj'

// User-assigned MI for ACR CMK
resource acrMi 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: acrMiName
  location: location
  tags: tags
}

// Grant ACR MI Crypto Service Encryption User on the sovereign KV
resource sovereignKv 'Microsoft.KeyVault/vaults@2024-04-01-preview' existing = {
  name: keyVaultName
}

var roleKvCryptoServiceEncryptionUser = '/subscriptions/${subscription().subscriptionId}/providers/Microsoft.Authorization/roleDefinitions/e147488a-f6f5-4113-8e2d-b22465e65bf6'

resource acrMiKvRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: sovereignKv
  name: guid(sovereignKv.id, acrMi.id, 'acr-kv-encryption')
  properties: {
    roleDefinitionId: roleKvCryptoServiceEncryptionUser
    principalId: acrMi.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// Premium ACR with CMK - the sovereign model registry
resource acr 'Microsoft.ContainerRegistry/registries@2023-11-01-preview' = {
  name: acrName
  location: location
  tags: tags
  sku: {
    name: 'Premium'
  }
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${acrMi.id}': {}
    }
  }
  properties: {
    adminUserEnabled: false
    publicNetworkAccess: 'Enabled'
    networkRuleBypassOptions: 'AzureServices'
    encryption: {
      status: 'enabled'
      keyVaultProperties: {
        keyIdentifier: kekUriWithVersion
        identity: acrMi.properties.clientId
      }
    }
    zoneRedundancy: 'Disabled'
  }
  dependsOn: [
    acrMiKvRole
  ]
}

// Foundry hub associated Key Vault - RBAC-authorized to sidestep the accessPolicies/write requirement
resource fdyKv 'Microsoft.KeyVault/vaults@2024-04-01-preview' = {
  name: hubKvName
  location: location
  tags: tags
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
  }
}

resource fdyStorage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: hubStorageName
  location: location
  tags: tags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: true
  }
}

resource fdyAi 'Microsoft.Insights/components@2020-02-02' = {
  name: hubAiName
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    Request_Source: 'rest'
  }
}

resource hub 'Microsoft.MachineLearningServices/workspaces@2024-07-01-preview' = {
  name: hubName
  location: location
  tags: tags
  kind: 'Hub'
  identity: {
    type: 'SystemAssigned'
  }
  sku: {
    name: 'Basic'
    tier: 'Basic'
  }
  properties: {
    friendlyName: 'HTX Foundry Hub'
    description: 'AI Foundry hub for cell-antenna model training. Model registry uses CMK-encrypted ACR.'
    storageAccount: fdyStorage.id
    keyVault: fdyKv.id
    applicationInsights: fdyAi.id
    containerRegistry: acr.id
    publicNetworkAccess: 'Enabled'
  }
}

resource project 'Microsoft.MachineLearningServices/workspaces@2024-07-01-preview' = {
  name: projectName
  location: location
  tags: tags
  kind: 'Project'
  identity: {
    type: 'SystemAssigned'
  }
  sku: {
    name: 'Basic'
    tier: 'Basic'
  }
  properties: {
    friendlyName: 'HTX Antenna Training Project'
    hubResourceId: hub.id
    publicNetworkAccess: 'Enabled'
  }
}

output hubName string = hub.name
output projectName string = project.name
output hubId string = hub.id
output acrName string = acr.name
output acrLoginServer string = acr.properties.loginServer
