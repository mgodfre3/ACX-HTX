targetScope = 'subscription'

@description('Azure region for all resources.')
param location string = 'westus2'

@description('Resource group name.')
param resourceGroupName string = 'ACX-HTX'

@description('Short name prefix for resources (lowercase, 3-8 chars). Used to build globally unique names.')
@minLength(3)
@maxLength(8)
param namePrefix string = 'acxhtx'

@description('Admin username for the Confidential VM.')
param cvmAdminUsername string

@secure()
@description('Admin password for the Confidential VM. Must satisfy Windows password complexity.')
param cvmAdminPassword string

@description('Resource group of the existing VNet.')
param existingVnetResourceGroup string = 'AdaptiveCloud-Management'

@description('Existing VNet name to attach workloads and private endpoints to.')
param existingVnetName string = 'AC-Managment-WUS2'

@description('Subnet name inside the existing VNet for the CVM NIC and private endpoints.')
param workloadSubnetName string = 'Default'

@description('Tags applied to the resource group and every resource.')
param tags object = {
  Project: 'HTX'
  'Created By': 'Michael Godfrey'
}

var workloadSubnetId = '/subscriptions/${subscription().subscriptionId}/resourceGroups/${existingVnetResourceGroup}/providers/Microsoft.Network/virtualNetworks/${existingVnetName}/subnets/${workloadSubnetName}'

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}

module keyvault 'modules/keyvault.bicep' = {
  scope: rg
  name: 'kv-deploy'
  params: {
    location: location
    namePrefix: namePrefix
    tags: tags
    workloadSubnetId: workloadSubnetId
  }
}

module identity 'modules/identity.bicep' = {
  scope: rg
  name: 'identity-deploy'
  params: {
    location: location
    namePrefix: namePrefix
    tags: tags
    keyVaultName: keyvault.outputs.keyVaultName
  }
}

module storage 'modules/storage.bicep' = {
  scope: rg
  name: 'storage-deploy'
  params: {
    location: location
    namePrefix: namePrefix
    tags: tags
    keyVaultUri: keyvault.outputs.keyVaultUri
    kekName: keyvault.outputs.kekName
    storageIdentityId: identity.outputs.storageIdentityId
    workloadSubnetId: workloadSubnetId
  }
}

module cvm 'modules/cvm.bicep' = {
  scope: rg
  name: 'cvm-deploy'
  params: {
    location: location
    namePrefix: namePrefix
    tags: tags
    adminUsername: cvmAdminUsername
    adminPassword: cvmAdminPassword
    workloadSubnetId: workloadSubnetId
  }
}

module foundry 'modules/foundry.bicep' = {
  scope: rg
  name: 'foundry-deploy'
  params: {
    location: location
    namePrefix: namePrefix
    tags: tags
  }
}

output resourceGroupName string = rg.name
output keyVaultName string = keyvault.outputs.keyVaultName
output kekName string = keyvault.outputs.kekName
output storageAccountName string = storage.outputs.storageAccountName
output coldContainerName string = storage.outputs.coldContainerName
output cvmName string = cvm.outputs.cvmName
output cvmPrincipalId string = cvm.outputs.cvmPrincipalId
output cvmPrivateIp string = cvm.outputs.privateIpAddress
output foundryHubName string = foundry.outputs.hubName
output foundryProjectName string = foundry.outputs.projectName

