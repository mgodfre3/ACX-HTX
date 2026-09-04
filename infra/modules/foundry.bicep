@description('Azure region.')
param location string

@description('Short name prefix.')
param namePrefix string

@description('Tags applied to every resource.')
param tags object

var suffix = uniqueString(resourceGroup().id)
var hubStorageName = toLower('${namePrefix}fdystg${substring(suffix, 0, 8)}')
var hubKvName = toLower('${namePrefix}-fdy-kv-${substring(suffix, 0, 6)}')
var hubAiName = toLower('${namePrefix}-fdy-ai-${substring(suffix, 0, 6)}')
var hubName = '${namePrefix}-foundry-hub'
var projectName = '${namePrefix}-foundry-proj'

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
    description: 'AI Foundry hub representing commercial-GPU less-sensitive processing.'
    storageAccount: fdyStorage.id
    keyVault: fdyKv.id
    applicationInsights: fdyAi.id
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
    friendlyName: 'HTX Foundry Project'
    hubResourceId: hub.id
    publicNetworkAccess: 'Enabled'
  }
}

output hubName string = hub.name
output projectName string = project.name
output hubId string = hub.id
