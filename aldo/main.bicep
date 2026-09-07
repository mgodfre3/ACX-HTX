targetScope = 'subscription'

// ============================================================================
// ALDO-side sovereign compute + AI stack
//
// Deploys to the Azure Local Disconnected Operations stamp (Tokyo WKLD).
// All resources land in the same subscription/tenant/AAD as the Azure side
// (ACX-HTX), so the same customer identities and Arc RBAC apply end-to-end.
//
// Prereqs the ALDO admin provides (see aldo/README.md):
//   - Custom Location resource ID (existing on the ALDO stamp)
//   - Existing logical-network name on the ALDO stamp
//   - VHD paths to Ubuntu 22.04 + Windows Server 2022 images pre-staged
//   - Arc-enabled subscription with HybridContainerService + AzureStackHCI RPs registered
// ============================================================================

@description('Azure region for ALDO resources. Always "Autonomous" for ALDO stamps.')
param location string = 'Autonomous'

@description('Resource group name for the ALDO-side sovereign stack.')
param resourceGroupName string = 'ACX-HTX-ALDO'

@description('Short name prefix.')
@minLength(3)
@maxLength(8)
param namePrefix string = 'htxaldo'

@description('Custom Location resource ID of the ALDO Tokyo WKLD stamp.')
param customLocationId string

@description('Existing logical network name on the ALDO stamp used for workload VMs and Arc-AKS.')
param logicalNetworkName string

@description('Resource group that contains the existing logical network.')
param logicalNetworkResourceGroup string = resourceGroupName

@description('Gallery image resource ID for Ubuntu 22.04 (Vault VM).')
param ubuntuGalleryImageId string

@description('Gallery image resource ID for Windows Server 2022 (optional jumpbox).')
param windowsGalleryImageId string = ''

@description('Deploy the optional Windows Server 2022 jumpbox VM.')
param deployJumpbox bool = false

@description('SSH public key for the Vault VM admin user.')
param vaultAdminSshPublicKey string

@description('Admin username for the Vault VM.')
param vaultAdminUsername string = 'htxadmin'

@secure()
@description('Windows jumpbox admin password (required only if deployJumpbox=true).')
param jumpboxAdminPassword string = ''

@description('Azure ACR to sync from for the Connected Registry mirror.')
param sovereignAcrName string = 'acxhtxacraguuve6o'

@description('Tags applied to every resource.')
param tags object = {
  Project: 'HTX'
  'Created By': 'Michael Godfrey'
  Environment: 'ALDO-Tokyo-WKLD'
}

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}

module vault 'modules/vault-vm.bicep' = {
  scope: rg
  name: 'vault-deploy'
  params: {
    location: location
    namePrefix: namePrefix
    tags: tags
    customLocationId: customLocationId
    logicalNetworkName: logicalNetworkName
    logicalNetworkResourceGroup: logicalNetworkResourceGroup
    ubuntuGalleryImageId: ubuntuGalleryImageId
    adminUsername: vaultAdminUsername
    adminSshPublicKey: vaultAdminSshPublicKey
  }
}

module aks 'modules/aks-arc.bicep' = {
  scope: rg
  name: 'aks-arc-deploy'
  params: {
    location: location
    namePrefix: namePrefix
    tags: tags
    customLocationId: customLocationId
    logicalNetworkName: logicalNetworkName
    logicalNetworkResourceGroup: logicalNetworkResourceGroup
  }
}

module aksExtensions 'modules/aks-extensions.bicep' = {
  scope: rg
  name: 'aks-ext-deploy'
  params: {
    aksArcClusterName: aks.outputs.connectedClusterName
  }
}

module jumpbox 'modules/jumpbox-vm.bicep' = if (deployJumpbox) {
  scope: rg
  name: 'jumpbox-deploy'
  params: {
    location: location
    namePrefix: namePrefix
    tags: tags
    customLocationId: customLocationId
    logicalNetworkName: logicalNetworkName
    logicalNetworkResourceGroup: logicalNetworkResourceGroup
    windowsGalleryImageId: windowsGalleryImageId
    adminUsername: vaultAdminUsername
    adminPassword: jumpboxAdminPassword
  }
}

output resourceGroupName string = rg.name
output vaultVmName string = vault.outputs.vmName
output vaultVmPrivateIp string = vault.outputs.privateIpAddress
output aksArcClusterName string = aks.outputs.connectedClusterName
output connectedRegistryInstallHint string = 'Run: az acr connected-registry install info --registry ${sovereignAcrName} --name aldo-tokyo-wkld'
