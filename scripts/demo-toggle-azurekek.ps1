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

  # Additional egress subnet(s) to bump into the vault firewall for the duration
  # of the toggle. The script auto-detects the operator's own egress IP (via
  # api.ipify.org) and prepends it to this list unless -NoAutoDetectEgress is set.
  # Historically-observed Microsoft corp NAT ranges are included as fallbacks so
  # a run from a corp-connected session also works.
  [string[]]$FirewallSubnets = @('52.167.112.0/22', '52.177.0.0/16'),

  [switch]$NoAutoDetectEgress,
  [switch]$SkipFirewallBump
)

# NOTE: script-level $ErrorActionPreference is deliberately set to 'Continue'
# to SHADOW any inherited value from a parent scope. If this script is invoked
# via `& demo-toggle-azurekek.ps1` from a parent that already set 'Stop' (e.g.,
# demo-presenter.ps1 does exactly that at its top), and we only omitted an
# explicit assignment here, the parent's 'Stop' would bleed in. That turns
# every non-zero az CLI exit into a terminating error and unwinds the retry
# loop in Set-KeyEnabled before it can iterate -- silently. The retry loop
# MUST tolerate transient ForbiddenByFirewall errors; individual az calls
# check $LASTEXITCODE explicitly. Do not remove this line.
$ErrorActionPreference = 'Continue'

if (-not $NoAutoDetectEgress) {
  try {
    $myIp = (Invoke-RestMethod -Uri 'https://api.ipify.org?format=json' -TimeoutSec 5).ip
    if ($myIp -match '^\d+\.\d+\.\d+\.\d+$') {
      $mySubnet = "$myIp/32"
      if ($FirewallSubnets -notcontains $mySubnet) {
        Write-Host "Auto-detected operator egress IP: $myIp (adding as $mySubnet)" -ForegroundColor DarkGray
        $FirewallSubnets = @($mySubnet) + $FirewallSubnets
      }
    } else {
      Write-Host "Auto-detect returned unrecognized value: '$myIp' -- continuing with defaults." -ForegroundColor DarkYellow
    }
  } catch {
    Write-Host "Auto-detect of egress IP failed ($($_.Exception.Message)) -- continuing with defaults." -ForegroundColor DarkYellow
  }
}

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
  # Azure Key Vault firewall changes are eventually consistent. Empirically this
  # takes 30-90 seconds to reach every front-end. Historical 20s wait was too
  # short and the retry loop below hit its window before propagation completed.
  Write-Host "  Waiting 45s for firewall rule propagation..." -ForegroundColor DarkGray
  Start-Sleep -Seconds 45
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
  # 8 attempts x 15s = 2 minute total window past the initial 45s wait. Chosen
  # to accommodate the slowest observed KV firewall propagation without leaving
  # the operator staring at a silent script.
  $maxAttempts = 8
  for ($i = 1; $i -le $maxAttempts; $i++) {
    $out = az keyvault key set-attributes --vault-name $VaultName --name $KeyName --enabled $Enabled --query 'attributes.enabled' -o tsv 2>&1
    if ($LASTEXITCODE -eq 0 -and ($out -eq $desired -or $out -eq $desired.Substring(0,1).ToUpper() + $desired.Substring(1))) {
      Write-Host "  attempt $i/$maxAttempts : succeeded" -ForegroundColor DarkGreen
      return $true
    }
    $reason = if ($out -match 'ForbiddenByFirewall|Client address is not authorized') { 'firewall not yet propagated' } else { 'other error' }
    Write-Host "  attempt $i/$maxAttempts : failed ($reason); retrying in 15s..." -ForegroundColor DarkYellow
    Start-Sleep -Seconds 15
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

