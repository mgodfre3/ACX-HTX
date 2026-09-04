using 'main.bicep'

param location = 'westus2'
param resourceGroupName = 'ACX-HTX'
param namePrefix = 'acxhtx'
param cvmAdminUsername = 'htxadmin'
param cvmAdminPassword = readEnvironmentVariable('CVM_ADMIN_PASSWORD', 'ChangeMe!Str0ng-Passw0rd-Here')
param allowedSourceIpPrefix = readEnvironmentVariable('ALLOWED_SOURCE_IP', '0.0.0.0/0')
param tags = {
  Project: 'HTX'
  'Created By': 'Michael Godfrey'
}
