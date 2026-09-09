<#
.SYNOPSIS
  Demo orchestrator — start CVM, run burst-consumer, capture logs, stop CVM.

.DESCRIPTION
  This is the operator-laptop side of the burst-CVM demo. See:
    docs/burst-cvm-architecture.md   design of record
    docs/demo-storyboard.md          on-stage script

  Actions (choose one):
    -Video <id>     Full burst cycle for one video envelope. Default action.
    -Stop           Deallocate the CVM without running a burst.
    -Status         Show CVM power state + last N edge-fetch audit events.
    -Reset          Deallocate CVM AND clear /var/lib/edge-fetch/processed on the edge
                    (via SSH to the ALDO Vault VM if -EdgeSsh is provided).

  The script has no destructive effects unless -Stop, -Reset, or -DeallocateWhenDone
  is set. Safe to run in -Status mode during a live demo.

.PARAMETER Video
  Video ID to fetch. Corresponds to /var/lib/edge-fetch/videos/<id>/envelope.json on the edge.

.PARAMETER Subscription
  Azure subscription containing acxhtx-vm. Default AdaptiveCloudLab.

.PARAMETER ResourceGroup
  RG holding acxhtx-vm. Default ACX-HTX.

.PARAMETER VmName
  Default acxhtx-vm.

.PARAMETER DeallocateWhenDone
  After the burst completes, deallocate the VM. Default $true.

.PARAMETER EdgeFetchUrl
  URL of the ALDO edge-fetch server. Default http://172.22.218.200:8444.
  Used only to poll audit logs for the on-stage overlay.
#>

[CmdletBinding(DefaultParameterSetName='Burst')]
param(
  [Parameter(ParameterSetName='Burst', Mandatory=$true, Position=0)]
  [string]$Video,

  [Parameter(ParameterSetName='Stop')]
  [switch]$Stop,

  [Parameter(ParameterSetName='Status')]
  [switch]$Status,

  [Parameter(ParameterSetName='Reset')]
  [switch]$Reset,

  [string]$Subscription    = 'AdaptiveCloudLab',
  [string]$ResourceGroup   = 'ACX-HTX',
  [string]$VmName          = 'acxhtx-vm',
  [string]$EdgeFetchUrl    = 'http://172.22.218.200:8444',
  [bool]  $DeallocateWhenDone = $true
)

$ErrorActionPreference = 'Stop'

# --- helpers ---

function Write-Banner {
  param([string]$Text, [ConsoleColor]$Color = 'Cyan')
  $line = '=' * ($Text.Length + 6)
  Write-Host ''
  Write-Host $line -ForegroundColor $Color
  Write-Host "== $Text ==" -ForegroundColor $Color
  Write-Host $line -ForegroundColor $Color
  Write-Host ''
}

function Get-VmPowerState {
  $j = az vm get-instance-view -g $ResourceGroup -n $VmName --subscription $Subscription --query 'instanceView.statuses' -o json | ConvertFrom-Json
  ($j | Where-Object { $_.code -like 'PowerState/*' } | Select-Object -First 1).displayStatus
}

function Wait-VmRunning {
  param([int]$TimeoutSec = 180)
  $start = Get-Date
  while ($true) {
    $state = Get-VmPowerState
    Write-Host ("[{0}] CVM state: {1}" -f (Get-Date -Format HH:mm:ss), $state)
    if ($state -eq 'VM running') { return }
    if ((Get-Date) - $start -gt (New-TimeSpan -Seconds $TimeoutSec)) {
      throw "CVM did not reach 'VM running' within $TimeoutSec seconds (state=$state)"
    }
    Start-Sleep -Seconds 5
  }
}

function Tail-EdgeAudit {
  param([int]$N = 5)
  try {
    $r = Invoke-RestMethod -Uri "$EdgeFetchUrl/audit/tail?n=$N" -Method GET -TimeoutSec 5
    Write-Host '[edge audit tail]' -ForegroundColor DarkYellow
    $r | ForEach-Object {
      $short = @{ ts = $_.ts_utc; event = $_.event }
      foreach ($k in @('reason','video_id','result_id','stub_indicator','arm_id','envelope_bytes')) {
        if ($_.$k) { $short[$k] = $_.$k }
      }
      Write-Host ('  ' + ($short | ConvertTo-Json -Compress))
    }
  } catch {
    Write-Host "[edge audit tail] unreachable ($_)" -ForegroundColor DarkYellow
  }
}

# --- Subscription context ---
az account set --subscription $Subscription | Out-Null

if ($Stop) {
  Write-Banner "STOP: deallocating $VmName" Yellow
  az vm deallocate -g $ResourceGroup -n $VmName --no-wait
  Write-Host "Deallocation dispatched. Poll with: .\demo-burst.ps1 -Status"
  return
}

if ($Status) {
  Write-Banner "STATUS: $VmName" Cyan
  Write-Host ("Power state : {0}" -f (Get-VmPowerState))
  az vm show -g $ResourceGroup -n $VmName --query "{name:name, secType:securityProfile.securityType, size:hardwareProfile.vmSize}" -o table
  Write-Host ''
  Tail-EdgeAudit -N 5
  return
}

if ($Reset) {
  Write-Banner "RESET: deallocating $VmName; edge processed/ cleanup requires SSH (out-of-band)" Yellow
  az vm deallocate -g $ResourceGroup -n $VmName --no-wait
  Write-Host "To clear edge results: ssh edge@172.22.218.200 'sudo rm -rf /var/lib/edge-fetch/processed/* && sudo systemctl restart edge-fetch'"
  return
}

# --- Burst path ---
Write-Banner "BURST: video=$Video" Green
Write-Host "Step 1/6 : Preflight attestation-gate on Azure Key Vault"
# Toggle B — Azure key kill switch — is observable HERE. If the operator has
# disabled acxhtx-cvm-attestation-key via demo-toggle-azurekek.ps1, this preflight
# sees enabled=false and aborts before starting the VM.
#
# We use the ARM control plane (Microsoft.KeyVault/vaults/keys GET) instead of
# the data-plane `az keyvault key show` because:
#   - The vault firewall (Deny + AzureServices bypass) blocks arbitrary data-plane
#     callers, but the ARM control plane bypasses it entirely.
#   - The attestation key is provisioned with keyOps=[wrapKey,unwrapKey] only, so
#     an `encrypt` preflight would 403 regardless of enabled state.
$sub            = az account show --query id -o tsv
$attestKeyVault = 'acxhtx-kv-aguuve6oq6by6'
$attestKeyName  = 'acxhtx-cvm-attestation-key'
$armPath        = "/subscriptions/$sub/resourceGroups/$ResourceGroup/providers/Microsoft.KeyVault/vaults/$attestKeyVault/keys/${attestKeyName}?api-version=2024-04-01-preview"
$armUrl         = "https://management.azure.com$armPath"

$enabled = az rest --method GET --url $armUrl --query 'properties.attributes.enabled' -o tsv 2>&1
if ($LASTEXITCODE -ne 0) {
  Write-Banner "AZURE KV OS ATTESTATION GATE: UNREACHABLE" Red
  Write-Host "  ARM GET on '$attestKeyName' failed: $enabled" -ForegroundColor Red
  Write-Host "  Aborting."
  return
}
if ($enabled -ne 'true') {
  Write-Banner "AZURE KV OS ATTESTATION GATE: DENIED" Red
  Write-Host "  Key '$attestKeyName' is disabled (properties.attributes.enabled=$enabled)."
  Write-Host "  A real SEV-SNP Confidential DES against this key would fail at boot for the same reason."
  Write-Host "  Restore with:  .\scripts\demo-toggle-azurekek.ps1 -Enable"
  return
}
Write-Host "  Attestation gate PASSED (attributes.enabled=true). Continuing." -ForegroundColor Green

Write-Host "`nStep 2/6 : Ensure CVM is running"
$state = Get-VmPowerState
if ($state -ne 'VM running') {
  Write-Host "  CVM state = $state; starting..."
  az vm start -g $ResourceGroup -n $VmName --no-wait
  Wait-VmRunning
} else {
  Write-Host "  Already running."
}

Write-Host "`nStep 3/6 : Invoke burst_consumer on CVM (this streams stdout back)"
$runScript = @"
C:\HTX\burst-consumer\run.cmd --video-id $Video
"@
$invoke = az vm run-command invoke `
  -g $ResourceGroup -n $VmName `
  --command-id RunPowerShellScript `
  --scripts $runScript `
  --query "value[0].message" -o tsv

Write-Host $invoke

# Parse the last JSON line of the CVM output for the audit id.
$lastJson = ($invoke -split "`n" | Where-Object { $_ -match '^\s*\{' } | Select-Object -Last 1)
if ($lastJson) {
  Write-Host "`n[cvm last event]" -ForegroundColor DarkCyan
  Write-Host "  $lastJson"
}

Write-Host "`nStep 4/6 : Poll edge audit tail"
Tail-EdgeAudit -N 8

Write-Host "`nStep 5/6 : Confirm result envelope landed"
try {
  $probe = Invoke-RestMethod -Uri "$EdgeFetchUrl/healthz" -Method GET -TimeoutSec 5
  Write-Host "  edge-fetch healthz: $($probe | ConvertTo-Json -Compress)"
} catch {
  Write-Host "  edge-fetch unreachable" -ForegroundColor Yellow
}

if ($DeallocateWhenDone) {
  Write-Host "`nStep 6/6 : Deallocate CVM"
  az vm deallocate -g $ResourceGroup -n $VmName --no-wait
  Write-Host "  Deallocation dispatched."
} else {
  Write-Host "`nStep 6/6 : Leaving CVM running (-DeallocateWhenDone=`$false)"
}

Write-Banner "BURST COMPLETE" Green
