@description('Azure region.')
param location string

@description('Short name prefix.')
param namePrefix string

@description('Tags applied to every resource.')
param tags object

@description('Local admin username.')
param adminUsername string

@secure()
@description('Local admin password.')
param adminPassword string

@description('Subnet resource ID (existing) for the VM NIC.')
param workloadSubnetId string

@description('Key Vault name that holds the KEK.')
param keyVaultName string

@description('KEK name in the vault.')
param kekName string

@description('KEK key identifier with version.')
param kekUriWithVersion string

@description('VM size. Uses widely available AMD non-confidential; CMK works on any modern SKU.')
param vmSize string = 'Standard_D2as_v5'

var vmName = '${namePrefix}-vm'
var nicName = '${vmName}-nic'
var desName = '${namePrefix}-des'

resource des 'Microsoft.Compute/diskEncryptionSets@2024-03-02' = {
  name: desName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    encryptionType: 'EncryptionAtRestWithCustomerKey'
    rotationToLatestKeyVersionEnabled: true
    activeKey: {
      keyUrl: kekUriWithVersion
    }
  }
}

resource kv 'Microsoft.KeyVault/vaults@2024-04-01-preview' existing = {
  name: keyVaultName
}

// Grant the DES managed identity Crypto Service Encryption User on the KV KEK
var roleKvCryptoServiceEncryptionUser = '/subscriptions/${subscription().subscriptionId}/providers/Microsoft.Authorization/roleDefinitions/e147488a-f6f5-4113-8e2d-b22465e65bf6'

resource desKvRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: kv
  name: guid(kv.id, des.id, 'des-kv-encryption-user')
  properties: {
    roleDefinitionId: roleKvCryptoServiceEncryptionUser
    principalId: des.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource nic 'Microsoft.Network/networkInterfaces@2023-11-01' = {
  name: nicName
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: workloadSubnetId
          }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2024-03-01' = {
  name: vmName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: 'htxvm'
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        provisionVMAgent: true
        enableAutomaticUpdates: true
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: '2022-datacenter-g2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Premium_LRS'
          diskEncryptionSet: {
            id: des.id
          }
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
        }
      ]
    }
    securityProfile: {
      securityType: 'TrustedLaunch'
      uefiSettings: {
        secureBootEnabled: true
        vTpmEnabled: true
      }
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
  }
  dependsOn: [
    desKvRole
  ]
}

output vmName string = vm.name
output vmPrincipalId string = vm.identity.principalId
output privateIpAddress string = nic.properties.ipConfigurations[0].properties.privateIPAddress
output diskEncryptionSetName string = des.name
output diskEncryptionSetId string = des.id
