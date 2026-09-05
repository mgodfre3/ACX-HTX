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

@description('Deploy the Confidential VM (SEV-SNP). Blocked in this subscription pending SEV-SNP capacity.')
param deployCvm bool = false

@description('Deploy a standard VM whose managed disks are encrypted with the customer KEK via a Disk Encryption Set. Same key-custody story as CVM without the SEV-SNP capacity dependency.')
param deployCmkVm bool = true

@description('Deploy the AI Foundry hub + project. Blocked pending resolution of ML workspace RP access-policy write permission on the shared Key Vault.')
param deployFoundry bool = false

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

module cvm 'modules/cvm.bicep' = if (deployCvm) {
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

module vmCmk 'modules/vm-cmk.bicep' = if (deployCmkVm) {
  scope: rg
  name: 'vm-cmk-deploy'
  params: {
    location: location
    namePrefix: namePrefix
    tags: tags
    adminUsername: cvmAdminUsername
    adminPassword: cvmAdminPassword
    workloadSubnetId: workloadSubnetId
    keyVaultName: keyvault.outputs.keyVaultName
    kekName: keyvault.outputs.kekName
    kekUriWithVersion: keyvault.outputs.kekUriWithVersion
  }
}

module foundry 'modules/foundry.bicep' = if (deployFoundry) {
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
output cvmName string = deployCvm ? cvm.outputs.cvmName : ''
output cvmPrincipalId string = deployCvm ? cvm.outputs.cvmPrincipalId : ''
output cvmPrivateIp string = deployCvm ? cvm.outputs.privateIpAddress : ''
output foundryHubName string = deployFoundry ? foundry!.outputs.hubName : ''
output foundryProjectName string = deployFoundry ? foundry!.outputs.projectName : ''
output cmkVmName string = deployCmkVm ? vmCmk!.outputs.vmName : ''
output cmkVmPrivateIp string = deployCmkVm ? vmCmk!.outputs.privateIpAddress : ''
output diskEncryptionSetName string = deployCmkVm ? vmCmk!.outputs.diskEncryptionSetName : ''

