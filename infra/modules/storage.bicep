@description('Azure region.')
param location string

@description('Short name prefix.')
param namePrefix string

@description('Tags applied to every resource.')
param tags object

@description('Key Vault base URI.')
param keyVaultUri string

@description('KEK name inside the vault.')
param kekName string

@description('User-assigned MI resource ID used for storage CMK.')
param storageIdentityId string

var storageName = toLower('${namePrefix}stg${uniqueString(resourceGroup().id)}')
var trimmedName = length(storageName) > 24 ? substring(storageName, 0, 24) : storageName

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: trimmedName
  location: location
  tags: tags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${storageIdentityId}': {}
    }
  }
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: true
    publicNetworkAccess: 'Enabled'
    accessTier: 'Hot'
    encryption: {
      identity: {
        userAssignedIdentity: storageIdentityId
      }
      keySource: 'Microsoft.Keyvault'
      keyvaultproperties: {
        keyvaulturi: keyVaultUri
        keyname: kekName
      }
      services: {
        blob: {
          enabled: true
          keyType: 'Account'
        }
        file: {
          enabled: true
          keyType: 'Account'
        }
      }
    }
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storage
  name: 'default'
  properties: {
    deleteRetentionPolicy: {
      enabled: true
      days: 7
    }
  }
}

resource coldContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: 'sovereign-cold'
  properties: {
    publicAccess: 'None'
  }
}

output storageAccountName string = storage.name
output storageAccountId string = storage.id
output coldContainerName string = coldContainer.name
