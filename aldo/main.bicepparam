using 'main.bicep'

param location = 'Autonomous'
param resourceGroupName = 'ACX-HTX-ALDO'
param namePrefix = 'htxaldo'

// ---- REQUIRED ONCE ALDO IS READY ----
param customLocationId = readEnvironmentVariable('ALDO_CUSTOM_LOCATION_ID', '/subscriptions/<sub>/resourceGroups/<hci-rg>/providers/Microsoft.ExtendedLocation/customLocations/<cl-name>')
param logicalNetworkName = readEnvironmentVariable('ALDO_LOGICAL_NETWORK_NAME', '<logical-network-name>')
param logicalNetworkResourceGroup = readEnvironmentVariable('ALDO_LOGICAL_NETWORK_RG', 'ACX-HTX-ALDO')
param ubuntuGalleryImageId = readEnvironmentVariable('ALDO_UBUNTU_IMAGE_ID', '/subscriptions/<sub>/resourceGroups/<gallery-rg>/providers/Microsoft.AzureStackHCI/galleryImages/ubuntu-2204-lts')
param windowsGalleryImageId = readEnvironmentVariable('ALDO_WINDOWS_IMAGE_ID', '')

param vaultAdminSshPublicKey = readEnvironmentVariable('ALDO_VAULT_SSH_PUBKEY', 'ssh-ed25519 AAAA... htxadmin@bootstrap')
param vaultAdminUsername = 'htxadmin'
param jumpboxAdminPassword = readEnvironmentVariable('ALDO_JUMPBOX_PASSWORD', 'ChangeMe!')
param deployJumpbox = false

param sovereignAcrName = 'acxhtxacraguuve6o'

param tags = {
  Project: 'HTX'
  'Created By': 'Michael Godfrey'
  Environment: 'ALDO-Tokyo-WKLD'
}
