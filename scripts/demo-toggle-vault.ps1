<#
.SYNOPSIS
  Toggle A -- edge Vault Transit key kill switch. Simulates the customer denying
  Azure the ability to decrypt anything, from the edge, without touching Azure.

.DESCRIPTION
  Bumps the min_decryption_version on the Vault Transit key so subsequent unwrap
  calls fail with a policy violation. This is the recoverable form of "disable
  the key" and works on the demo lab immediately. For an even harder cut, add
  -Delete which actually deletes the key (destructive -- requires re-seeding
  videos afterward).

  SECURITY POSTURE (changed in this revision):
    The Vault token is stored ON THE EDGE at /etc/vault/htx-toggle-token (mode
    0440, root:edge) and is a scoped, periodic token with the least-privilege
    'htx-toggle' policy attached. This script reads it from the edge over SSH
    at runtime; the token value never lands on the operator's laptop or in any
    log line.

    The 'htx-toggle' policy allows only:
      - update  transit/keys/htx-kek/rotate
      - update  transit/keys/htx-kek/config
      - read    transit/keys/htx-kek     (for inspecting latest_version)
    It has no decrypt capability; only the edge-fetch service token can decrypt.

    Previous versions of this script required the Vault ROOT token to live in a
    JSON file on the operator's laptop. That posture is now retired.

.PARAMETER Disable
  Bump min_decryption_version to invalidate all wrapped DEKs currently in flight.

.PARAMETER Enable
  Reset min_decryption_version to 1 so unwrap works again.

.PARAMETER Delete
  Additive to -Disable. Marks the key deletable and deletes it. Destructive:
  reseeding video envelopes is required after using this.

.PARAMETER EdgeHost
  IP/hostname of the ALDO Vault VM. Default 172.22.218.200.

.PARAMETER EdgeSshUser
  SSH user on the edge. Default 'edge'. Must have group membership giving read
  access to $TokenPath on the edge.

.PARAMETER TokenPath
  Absolute path on the edge to the scoped Vault toggle token file. Default
  /etc/vault/htx-toggle-token.

.PARAMETER VaultAddr
  Vault API address reachable from the edge itself. Default http://127.0.0.1:8200.

.PARAMETER KeyName
  Transit key name. Default 'htx-kek'.

.EXAMPLE
  .\demo-toggle-vault.ps1 -Disable
  Recoverable disable: bumps min_decryption_version.

.EXAMPLE
  .\demo-toggle-vault.ps1 -Enable
  Restores min_decryption_version=1 so previously-wrapped DEKs unwrap again.
#>

[CmdletBinding()]
param(
  [Parameter(ParameterSetName='Off', Mandatory=$true)]
  [switch]$Disable,

  [Parameter(ParameterSetName='On', Mandatory=$true)]
  [switch]$Enable,

  [Parameter(ParameterSetName='Off')]
  [switch]$Delete,

  [string]$EdgeHost     = '172.22.218.200',
  [string]$EdgeSshUser  = 'edge',
  [string]$TokenPath    = '/etc/vault/htx-toggle-token',
  [string]$VaultAddr    = 'http://127.0.0.1:8200',
  [string]$KeyName      = 'htx-kek'
)

$ErrorActionPreference = 'Stop'

function Write-Banner {
  param([string]$Text, [ConsoleColor]$Color)
  $bar = '!' * 78
  Write-Host ''
  Write-Host $bar -ForegroundColor $Color
  Write-Host ("!!! {0}" -f $Text.PadRight(72) + '!!!') -ForegroundColor $Color
  Write-Host $bar -ForegroundColor $Color
  Write-Host ''
}

function Invoke-EdgeVault {
  <#
    Run a shell block on the edge that:
      1. Sources the scoped token from a local file (never leaves the edge).
      2. Exports VAULT_ADDR + VAULT_TOKEN.
      3. Runs the given command block.

    Fails cleanly if the token file is unreadable or the ssh session errors.
    Output flows straight through so the operator sees vault's own responses.
  #>
  param([string]$Block)

  # A single heredoc-style bash script, sent as one ssh command line. Using
  # `bash -s` on the far side keeps quoting and $-expansion under bash rules,
  # not PowerShell's -- so the caller can use $VAULT_TOKEN, $CUR, etc. safely.
  $remote = @"
set -eu
if [ ! -r '$TokenPath' ]; then
  echo "edge: token file $TokenPath not readable by \$(id -un)" >&2
  exit 65
fi
export VAULT_ADDR='$VaultAddr'
export VAULT_TOKEN=`$(cat '$TokenPath')
if [ -z "`$VAULT_TOKEN" ]; then
  echo "edge: token file $TokenPath is empty" >&2
  exit 66
fi
$Block
"@

  # -T disables pseudo-tty allocation, keeps stdout clean and avoids ncurses
  # escape sequences leaking into the banner output.
  $remote | ssh -T "$EdgeSshUser@$EdgeHost" 'bash -s'
  if ($LASTEXITCODE -ne 0) {
    throw "edge vault command failed (ssh exit $LASTEXITCODE). See stderr above."
  }
}

if ($Disable) {
  # Bump min_decryption_version to (current_version + 1) so all currently-wrapped
  # DEKs stop working. `rotate` creates a fresh key version; setting
  # min_decryption_version to the new latest_version excludes every prior version
  # from decryption while still allowing new encryptions.
  Invoke-EdgeVault -Block @"
vault write -f transit/keys/$KeyName/rotate >/dev/null
CUR=`$(vault read -format=json transit/keys/$KeyName | jq -r .data.latest_version)
vault write transit/keys/$KeyName/config min_decryption_version=`$CUR
echo "edge: min_decryption_version bumped to `$CUR"
"@

  if ($Delete) {
    Invoke-EdgeVault -Block @"
vault write transit/keys/$KeyName/config deletion_allowed=true >/dev/null
vault delete transit/keys/$KeyName
echo "edge: key deleted (irrecoverable)"
"@
    Write-Banner "EDGE VAULT: $KeyName DELETED (destructive - reseed required)" Red
    return
  }

  Write-Banner "EDGE VAULT: $KeyName DISABLED (min_decryption_version bumped)" Red
  Write-Host "All previously-wrapped DEKs are now inert. Restore with -Enable." -ForegroundColor Yellow
  return
}

if ($Enable) {
  Invoke-EdgeVault -Block @"
vault write transit/keys/$KeyName/config min_decryption_version=1 >/dev/null
echo "edge: min_decryption_version reset to 1"
"@
  Write-Banner "EDGE VAULT: $KeyName RESTORED (min_decryption_version=1)" Green
  return
}
