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

// SSH public key for the Vault VM admin. Private key retained in session workspace.
param vaultAdminSshPublicKey = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJjMWl4XQqy+6kVW7Lg9zHRPn9OxY4Hqa4mxednOaYu4 htxadmin@aldo-vault'
param vaultAdminUsername = 'htxadmin'

// Windows VM credentials
param windowsAdminUsername = 'htxadmin'
param foundryAdminPassword = readEnvironmentVariable('ALDO_FOUNDRY_PASSWORD', 'ChangeMe!Set-Via-Env-2026')
param jumpboxAdminPassword = readEnvironmentVariable('ALDO_JUMPBOX_PASSWORD', 'ChangeMe!Set-Via-Env-2026')

// Jumpbox opt-in
param deployJumpbox = false

// GPU passthrough. Discover with (on any ALDO host node):
//   Get-VMHostPartitionableGpu | Select-Object Name
// Common Tokyo-WKLD A100 name: 'NVIDIA A100 80GB PCIe' or the PCI ID string.
param foundryGpuName = readEnvironmentVariable('ALDO_FOUNDRY_GPU_NAME', '')

param sovereignAcrName = 'acxhtxacraguuve6o'

param tags = {
  Project: 'HTX'
  'Created By': 'Michael Godfrey'
  Environment: 'ALDO-Tokyo-WKLD'
}
