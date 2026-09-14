<#
.SYNOPSIS
  Toggle A -- edge Vault Transit key kill switch. Simulates the customer denying
  Azure the ability to decrypt anything, from the edge, without touching Azure.

.DESCRIPTION
  Bumps the min_decryption_version on the Vault Transit key so subsequent unwrap
  calls fail with a policy violation. This is a fully recoverable disable; run
  the script again with -Enable to restore.

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
    It has no decrypt capability and no delete capability. Only the edge-fetch
    service token can decrypt; destructive key deletion is deliberately not
    reachable from this script.

    Previous versions of this script required the Vault ROOT token to live in a
    JSON file on the operator's laptop. That posture is now retired. Previous
    versions also supported a -Delete switch that permanently deleted the key;
    that switch has been removed because (a) the scoped policy doesn't permit
    it, and (b) permanent deletion is never part of the on-stage demo -- only
    the recoverable disable/enable cycle is.

.PARAMETER Disable
  Bump min_decryption_version to invalidate all wrapped DEKs currently in flight.

.PARAMETER Enable
  Reset min_decryption_version to 1 so unwrap works again.

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
  echo "edge: token file $TokenPath not readable by `$(id -un)" >&2
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

  # POWERSHELL NEWLINE HANDLING (the bug that took two attempts to fix):
  # PowerShell here-strings on Windows contain bare LF in memory. But when
  # a string is piped to a NATIVE process's stdin (like ssh.exe), PowerShell's
  # pipeline converts every LF to CRLF using [Console]::OutputEncoding line
  # semantics. That CRLF stays attached on the far side and bash sees
  # `set -eu<CR>` and prints "invalid option: -" then dies on unexpected EOF.
  #
  # A `-replace` on the string is a no-op because the string itself has LF only;
  # the CRLF appears at the boundary between PowerShell and the native process.
  #
  # The fix is to bypass the native pipeline entirely: start ssh via
  # System.Diagnostics.Process, get its raw stdin BaseStream, write LF-encoded
  # UTF-8 bytes directly. No newline conversion happens because we never touch
  # a StreamWriter or a PowerShell pipe.
  $remoteLf = $remote -replace "`r`n", "`n"   # belt-and-suspenders; here-strings should already be LF
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($remoteLf)

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = 'ssh'
  # -T disables pseudo-tty allocation, keeps stdout clean.
  $psi.Arguments = "-T $EdgeSshUser@$EdgeHost `"bash -s`""
  $psi.RedirectStandardInput = $true
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true

  $proc = [System.Diagnostics.Process]::Start($psi)
  try {
    $proc.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
    $proc.StandardInput.BaseStream.Flush()
  } finally {
    $proc.StandardInput.Close()   # signal EOF to bash -s
  }
  $proc.WaitForExit()

  if ($proc.ExitCode -ne 0) {
    throw "edge vault command failed (ssh exit $($proc.ExitCode)). See stderr above."
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
