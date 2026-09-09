<#
.SYNOPSIS
  Toggle A — edge Vault Transit key kill switch. Simulates the customer denying
  Azure the ability to decrypt anything, from the edge, without touching Azure.

.DESCRIPTION
  Bumps the min_decryption_version on the Vault Transit key so subsequent unwrap
  calls fail with 403. This is the recoverable form of "disable the key" and
  works on the demo lab immediately. For an even harder cut, add -Delete which
  actually deletes the key (destructive — requires re-seeding videos afterward).

  Uses SSH to reach the ALDO Vault VM at 172.22.218.200 with the operator's
  configured SSH identity. The Vault root token is read from the operator-local
  protected file at $env:HTX_VAULT_INIT_PATH (must contain the JSON produced by
  `vault operator init -format=json`).

.PARAMETER Disable
  Bump min_decryption_version to invalidate all wrapped DEKs currently in flight.

.PARAMETER Enable
  Reset min_decryption_version to 1 so unwrap works again.

.PARAMETER Delete
  Additive to -Disable. Marks the key deletable and deletes it. Destructive.
#>

[CmdletBinding()]
param(
  [Parameter(ParameterSetName='Off', Mandatory=$true)]
  [switch]$Disable,

  [Parameter(ParameterSetName='On', Mandatory=$true)]
  [switch]$Enable,

  [Parameter(ParameterSetName='Off')]
  [switch]$Delete,

  [string]$EdgeHost      = '172.22.218.200',
  [string]$EdgeSshUser   = 'edge',
  [string]$VaultAddr     = 'http://127.0.0.1:8200',
  [string]$KeyName       = 'htx-kek',
  [string]$VaultInitPath = $(if ($env:HTX_VAULT_INIT_PATH) { $env:HTX_VAULT_INIT_PATH } else { "$env:USERPROFILE\.htx\vault-init.json" })
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $VaultInitPath)) {
  throw "Vault init file not found at $VaultInitPath. Set HTX_VAULT_INIT_PATH or -VaultInitPath."
}
$vaultInit = Get-Content $VaultInitPath -Raw | ConvertFrom-Json
$token = $vaultInit.root_token
if (-not $token) { throw "root_token not found in $VaultInitPath" }

function Invoke-VaultOverSsh {
  param([string[]]$Commands)
  $env  = "export VAULT_ADDR='$VaultAddr'; export VAULT_TOKEN='$token';"
  $line = ($Commands -join ' && ')
  ssh "$EdgeSshUser@$EdgeHost" "$env $line"
}

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
  # Bump min_decryption_version to (current_version + 1) so all currently-wrapped DEKs stop working.
  Invoke-VaultOverSsh -Commands @(
    "vault write transit/keys/$KeyName/rotate",
    "CUR=`$(vault read -format=json transit/keys/$KeyName | jq -r .data.latest_version)",
    "vault write transit/keys/$KeyName/config min_decryption_version=`$CUR"
  )

  if ($Delete) {
    Invoke-VaultOverSsh -Commands @(
      "vault write transit/keys/$KeyName/config deletion_allowed=true",
      "vault delete transit/keys/$KeyName"
    )
    Write-Banner "EDGE VAULT: $KeyName DELETED (destructive - reseed required)" Red
    return
  }

  Write-Banner "EDGE VAULT: $KeyName DISABLED (min_decryption_version bumped)" Red
  Write-Host "All previously-wrapped DEKs are now inert. New videos seeded from this point onward will work if you Enable again." -ForegroundColor Yellow
  return
}

if ($Enable) {
  Invoke-VaultOverSsh -Commands @(
    "vault write transit/keys/$KeyName/config min_decryption_version=1"
  )
  Write-Banner "EDGE VAULT: $KeyName RESTORED (min_decryption_version=1)" Green
  return
}
