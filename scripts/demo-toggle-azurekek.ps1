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

  Azure Key Vault key enable/disable ONLY works via the data plane; there is no
  ARM control-plane PATCH. If the vault has firewall Deny (which it does), this
  script must add the caller's egress IP range to the firewall, do the toggle,
  and remove the range. Set -SkipFirewallBump if you are running from Azure
  Cloud Shell or another environment that already has data-plane reach.
#>

[CmdletBinding()]
param(
  [Parameter(ParameterSetName='Off', Mandatory=$true)]
  [switch]$Disable,

  [Parameter(ParameterSetName='On', Mandatory=$true)]
  [switch]$Enable,

  [string]$Subscription = 'AdaptiveCloudLab',
  [string]$VaultName    = 'acxhtx-kv-aguuve6oq6by6',
  [string]$KeyName      = 'acxhtx-cvm-attestation-key',

  # Egress subnet(s) to bump into the vault firewall for the duration of the toggle.
  # Defaults cover the Microsoft corp NAT pool observed from the operator's dev machine.
  # Extend or replace if your egress differs (e.g., add your home IP as /32).
  [string[]]$FirewallSubnets = @('52.167.112.0/22', '52.177.0.0/16'),

  [switch]$SkipFirewallBump
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

function Add-FirewallSubnets {
  param([string[]]$Subnets)
  foreach ($s in $Subnets) {
    az keyvault network-rule add --name $VaultName --ip-address $s -o none 2>&1 | Out-Null
  }
  Start-Sleep -Seconds 20   # propagation delay
}

function Remove-FirewallSubnets {
  param([string[]]$Subnets)
  foreach ($s in $Subnets) {
    az keyvault network-rule remove --name $VaultName --ip-address $s -o none 2>&1 | Out-Null
  }
}

function Set-KeyEnabled {
  param([bool]$Enabled)
  $desired = if ($Enabled) { 'true' } else { 'false' }
  for ($i = 1; $i -le 4; $i++) {
    $out = az keyvault key set-attributes --vault-name $VaultName --name $KeyName --enabled $Enabled --query 'attributes.enabled' -o tsv 2>&1
    if ($LASTEXITCODE -eq 0 -and ($out -eq $desired -or $out -eq $desired.Substring(0,1).ToUpper() + $desired.Substring(1))) { return $true }
    Start-Sleep -Seconds 10
  }
  Write-Host "  Last error: $out" -ForegroundColor Red
  return $false
}

$bumped = $false
try {
  if (-not $SkipFirewallBump) {
    Write-Host "Bumping vault firewall for egress subnets: $($FirewallSubnets -join ', ')"
    Add-FirewallSubnets -Subnets $FirewallSubnets
    $bumped = $true
  }

  if ($Disable) {
    if (Set-KeyEnabled -Enabled $false) {
      Write-Banner "AZURE KEY VAULT: $KeyName DISABLED" Red
      Write-Host "The next demo-burst.ps1 will see enabled=false at the ARM preflight and abort before starting the CVM." -ForegroundColor Yellow
      Write-Host "The customer's data key on the edge is unaffected."
    } else {
      Write-Banner "TOGGLE FAILED — could not disable $KeyName" Red
    }
  }

  if ($Enable) {
    if (Set-KeyEnabled -Enabled $true) {
      Write-Banner "AZURE KEY VAULT: $KeyName RESTORED" Green
    } else {
      Write-Banner "TOGGLE FAILED — could not enable $KeyName" Red
    }
  }
} finally {
  if ($bumped) {
    Write-Host "Removing firewall bumps..."
    Remove-FirewallSubnets -Subnets $FirewallSubnets
  }
}
