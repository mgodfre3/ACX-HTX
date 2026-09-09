<#
.SYNOPSIS
  Toggle B — Azure Key Vault OS/attestation key kill switch. Simulates Microsoft
  denying the CVM the ability to start. The customer's data key on the edge is
  unaffected.

.DESCRIPTION
  Enables or disables the dedicated OS/attestation key
  acxhtx-cvm-attestation-key in the Azure Key Vault acxhtx-kv-aguuve6oq6by6.
  This key is separate from htx-kek by design so it is provable on stage that
  Azure has no control over the customer's data key.
#>

[CmdletBinding()]
param(
  [Parameter(ParameterSetName='Off', Mandatory=$true)]
  [switch]$Disable,

  [Parameter(ParameterSetName='On', Mandatory=$true)]
  [switch]$Enable,

  [string]$Subscription = 'AdaptiveCloudLab',
  [string]$VaultName    = 'acxhtx-kv-aguuve6oq6by6',
  [string]$KeyName      = 'acxhtx-cvm-attestation-key'
)

$ErrorActionPreference = 'Stop'

az account set --subscription $Subscription | Out-Null

function Write-Banner {
  param([string]$Text, [ConsoleColor]$Color)
  $bar = '!' * 78
  Write-Host ''
  Write-Host $bar -ForegroundColor $Color
  Write-Host ("!!! {0}" -f $Text.PadRight(72) + '!!!') -ForegroundColor $Color
  Write-Host $bar -ForegroundColor $Color
  Write-Host ''
}

if ($Disable) {
  az keyvault key set-attributes --vault-name $VaultName --name $KeyName --enabled false --query "{name:kid, enabled:attributes.enabled}" -o json | Out-Host
  Write-Banner "AZURE KEY VAULT: $KeyName DISABLED" Red
  Write-Host "The CVM will fail its next attestation-gated startup. The customer's data key on the edge is unaffected." -ForegroundColor Yellow
  return
}

if ($Enable) {
  az keyvault key set-attributes --vault-name $VaultName --name $KeyName --enabled true --query "{name:kid, enabled:attributes.enabled}" -o json | Out-Host
  Write-Banner "AZURE KEY VAULT: $KeyName RESTORED" Green
  return
}
