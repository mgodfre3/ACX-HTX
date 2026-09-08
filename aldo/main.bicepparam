using 'main.bicep'

// Concrete values from the Tokyo-WKLD stamp discovery on 2026-09-08.

param location = 'Autonomous'
param resourceGroupName = 'ACX-HTX-ALDO'
param namePrefix = 'htxaldo'

// ---- ALDO stamp IDs ----
param customLocationId = '/subscriptions/ef23bab2-5bd7-afa3-3013-d5116a941684/resourceGroups/tokyo-wkld/providers/Microsoft.ExtendedLocation/customLocations/Tokyo-WKLD'
param logicalNetworkName = 'Tokyo-VLAN-101'
param logicalNetworkResourceGroup = 'Tokyo-WKLD'
param ubuntuGalleryImageId = '/subscriptions/ef23bab2-5bd7-afa3-3013-d5116a941684/resourceGroups/Tokyo-WKLD/providers/microsoft.azurestackhci/galleryimages/Ubuntu2404'
param windowsGalleryImageId = '/subscriptions/ef23bab2-5bd7-afa3-3013-d5116a941684/resourceGroups/Tokyo-WKLD/providers/microsoft.azurestackhci/galleryimages/WS2025'

// SSH public key for the Vault VM admin.
// Private key is retained in the session workspace (not committed).
param vaultAdminSshPublicKey = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBx6XGJhkvQ1P6kx9MixBCJ16YyhJ4NKTAVKCorLcGJB htxadmin@aldo-vault'
param vaultAdminUsername = 'htxadmin'

// Jumpbox opt-in
param deployJumpbox = false
param jumpboxAdminPassword = readEnvironmentVariable('ALDO_JUMPBOX_PASSWORD', 'ChangeMe!Set-Via-Env-2026')

param sovereignAcrName = 'acxhtxacraguuve6o'

param tags = {
  Project: 'HTX'
  'Created By': 'Michael Godfrey'
  Environment: 'ALDO-Tokyo-WKLD'
}
