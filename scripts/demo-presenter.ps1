<#
.SYNOPSIS
  Demo Presenter — the single command you run on stage.

.DESCRIPTION
  Wraps the six acts from docs/demo-storyboard.md into an ENTER-gated
  teleprompter. You focus on the customer conversation; this script prints the
  on-stage line for each act, waits for you to tap ENTER, then runs the
  underlying commands and prints their output.

  The idea: your finger sits on the ENTER key. Your eyes stay on the audience.
  Your voice delivers the storyboard. This script is the demo apparatus that
  makes the tech invisible.

  Interactive controls:
    ENTER     advance to the next act (or run the current act's commands)
    S         skip the current act (only meaningful for optional kill-switch acts)
    Q         quit cleanly (deallocates the CVM if it's running)
    Ctrl-C    same as Q — cleanup runs in the finally block

  This script does NOT replace docs/demo-storyboard.md; that's still the source
  of truth for the on-stage lines. This script just adds pacing.

.PARAMETER Video
  Video ID to burst. Default: sample-video-01. Must be seeded on the edge.

.PARAMETER SkipToggles
  If set, ends the demo after Act 5 (skips both kill switches). Useful for a
  "highlights only" run when time is short.

.PARAMETER Rehearse
  Run through the acts without pausing for ENTER. Every gate becomes a 1-second
  delay. Kill-switch acts (6a and 6b) are AUTO-SKIPPED in rehearse mode — they
  take an extra ~8-10 minutes to run for real, and if the rehearsal were
  interrupted the keys would stay disabled. Rehearse mode ends after Act 5.
  Use `.\scripts\demo-presenter.ps1 -Rehearse` once before demo day to check
  Acts 1-5 pacing.

.PARAMETER Subscription
  Azure subscription. Default: AdaptiveCloudLab.

.PARAMETER ResourceGroup
  RG holding acxhtx-vm. Default: ACX-HTX.

.PARAMETER VmName
  Burst CVM. Default: acxhtx-vm.

.PARAMETER EdgeHost
  ALDO Vault VM. Default: 172.22.218.200.

.PARAMETER EdgeSshUser
  SSH user on the edge. Default: edge.

.EXAMPLE
  .\scripts\demo-presenter.ps1

  Full 6-act run, ENTER-gated between acts.

.EXAMPLE
  .\scripts\demo-presenter.ps1 -SkipToggles

  Acts 1-5 only (customer walkthrough without the kill-switch reveal).

.EXAMPLE
  .\scripts\demo-presenter.ps1 -Rehearse

  Timed dry run of Acts 1-5. Every ENTER gate becomes a 1-second pause. Kill
  switches auto-skip. Use once before demo day to sanity-check pacing.
#>

[CmdletBinding()]
param(
  [string]$Video          = 'sample-video-01',
  [switch]$SkipToggles,
  [switch]$Rehearse,
  [string]$Subscription   = 'AdaptiveCloudLab',
  [string]$ResourceGroup  = 'ACX-HTX',
  [string]$VmName         = 'acxhtx-vm',
  [string]$EdgeHost       = '172.22.218.200',
  [string]$EdgeSshUser    = 'edge',
  [string]$EdgeFetchUrl   = 'http://172.22.218.200:8444',
  [string]$AttestKeyVault = 'acxhtx-kv-aguuve6oq6by6',
  [string]$AttestKeyName  = 'acxhtx-cvm-attestation-key'
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $PSCommandPath

# --- state used by the finally block ---
$script:VmStartedByUs = $false
$script:VaultDisabled = $false    # true iff we've -Disabled the edge Vault Transit key and not yet restored
$script:AzureKekDisabled = $false # true iff we've -Disabled the AKV attestation key and not yet restored

# ========================================================================
# Presentation primitives
# ========================================================================

function Show-Divider {
  Write-Host ('-' * 78) -ForegroundColor DarkGray
}

function Show-ActBanner {
  param([int]$Number, [string]$Title, [string]$TargetSeconds = '')
  $tag = if ($TargetSeconds) { " [~${TargetSeconds}s]" } else { '' }
  Write-Host ''
  Write-Host ('=' * 78) -ForegroundColor Cyan
  Write-Host ("ACT $Number : $Title$tag") -ForegroundColor Cyan
  Write-Host ('=' * 78) -ForegroundColor Cyan
}

function Show-StageLine {
  # The line the presenter says out loud. Keep quotes and italic-ish framing.
  param([string]$Text)
  Write-Host ''
  Write-Host '  SAY: ' -ForegroundColor Yellow -NoNewline
  Write-Host $Text -ForegroundColor White
  Write-Host ''
}

function Show-Doing {
  param([string]$Text)
  Write-Host "  > $Text" -ForegroundColor DarkGreen
}

function Show-Note {
  param([string]$Text)
  Write-Host "  NOTE: $Text" -ForegroundColor DarkYellow
}

function Wait-Gate {
  <#
    Blocks until the operator taps ENTER (or S/Q). In -Rehearse mode this is a
    1-second delay instead of a keypress.

    In -Rehearse mode, gates that -AllowSkip return 'SKIP' automatically so the
    kill-switch acts are NOT exercised for real during a timed dry run — that
    would take an extra ~8-10 minutes and would leave the keys disabled if the
    rehearsal were interrupted.
  #>
  param(
    [string]$Prompt = 'ENTER to continue',
    [switch]$AllowSkip
  )
  if ($Rehearse) {
    if ($AllowSkip) { return 'SKIP' }
    Start-Sleep -Seconds 1
    return 'ENTER'
  }
  $hint = if ($AllowSkip) { "$Prompt  (S=skip, Q=quit)" } else { "$Prompt  (Q=quit)" }
  Write-Host ''
  Write-Host "  [ $hint ]" -ForegroundColor Magenta -NoNewline
  while ($true) {
    $key = [Console]::ReadKey($true)
    switch ($key.Key) {
      'Enter'   { Write-Host ''; return 'ENTER' }
      'Q'       { Write-Host ' -> QUIT'; throw 'operator quit' }
      'S'       { if ($AllowSkip) { Write-Host ' -> SKIP'; return 'SKIP' } }
      default   { }   # ignore other keys, keep listening
    }
  }
}

# ========================================================================
# Command wrappers (thin — real logic lives in the underlying scripts)
# ========================================================================

function Get-VmPowerState {
  $j = az vm get-instance-view -g $ResourceGroup -n $VmName --subscription $Subscription --query 'instanceView.statuses' -o json 2>$null | ConvertFrom-Json
  if (-not $j) { return 'unknown' }
  ($j | Where-Object { $_.code -like 'PowerState/*' } | Select-Object -First 1).displayStatus
}

function Wait-VmRunning {
  <#
    Poll for CVM power state = 'VM running'. Throws on timeout so callers don't
    hang the demo indefinitely if Azure control-plane is slow. Used by Act 2
    and Act 6a alike.
  #>
  param(
    [int]$TimeoutSec = 180
  )
  $started = [DateTime]::UtcNow
  while ((Get-VmPowerState) -ne 'VM running') {
    if (([DateTime]::UtcNow - $started).TotalSeconds -gt $TimeoutSec) {
      throw "CVM did not reach 'VM running' within ${TimeoutSec}s"
    }
    Start-Sleep -Seconds 5
    Write-Host '.' -NoNewline -ForegroundColor DarkGray
  }
  Write-Host ' running'
}

function Ensure-AzContext {
  $current = az account show --query name -o tsv 2>$null
  if ($current -ne $Subscription) {
    az account set --subscription $Subscription | Out-Null
  }
}

function Invoke-Edge {
  <# Run a single shell command on the edge and return stdout. #>
  param([string]$Command)
  ssh "$EdgeSshUser@$EdgeHost" "$Command"
}

function Tail-EdgeAudit {
  param([int]$N = 6)
  try {
    $r = Invoke-RestMethod -Uri "$EdgeFetchUrl/audit/tail?n=$N" -Method GET -TimeoutSec 5
    Write-Host '  [edge audit]' -ForegroundColor DarkYellow
    foreach ($e in $r) {
      $summary = @{ event = $e.event }
      foreach ($k in @('reason', 'video_id', 'result_id', 'stub_indicator', 'arm_id', 'envelope_bytes', 'dek_bytes')) {
        if ($e.$k) { $summary[$k] = $e.$k }
      }
      Write-Host ('    ' + ($summary | ConvertTo-Json -Compress)) -ForegroundColor DarkYellow
    }
  } catch {
    Write-Host "  [edge audit unreachable: $_]" -ForegroundColor DarkYellow
  }
}

# ========================================================================
# Act implementations
# ========================================================================

function Invoke-Act1 {
  Show-ActBanner 1 "What's here, what isn't" -TargetSeconds 90
  Show-StageLine 'This is the customer''s data. It''s encrypted. It lives here — on the customer''s edge.'
  Wait-Gate 'ENTER to show the edge state' | Out-Null

  Show-Doing 'edge: list seeded videos'
  Invoke-Edge 'ls -la /var/lib/edge-fetch/videos/'
  Write-Host ''

  Show-Doing "edge: inspect envelope kek_ref and wrap_algo for $Video"
  Invoke-Edge "sudo -u edge-fetch jq '.kek_ref, .wrap_algo, (.ciphertext_b64 | length)' /var/lib/edge-fetch/videos/$Video/envelope.json"
  Write-Host ''

  Show-Doing 'edge: confirm the Transit key is present locally on the on-prem Vault'
  Invoke-Edge 'vault read -field=type transit/keys/htx-kek || vault read transit/keys/htx-kek | head -6'

  Show-StageLine 'Now look at what''s in Azure. Zero storage accounts holding customer data.'
  Wait-Gate 'ENTER to show the Azure state' | Out-Null

  Show-Doing 'azure: list all storage accounts in the RG (should show only Foundry-internal)'
  Ensure-AzContext
  az resource list -g $ResourceGroup --query "[?type=='Microsoft.Storage/storageAccounts'].name" -o tsv | ForEach-Object { Write-Host "    $_" }
  Write-Host ''

  Show-Doing 'azure: list Key Vault keys with their purpose tags'
  $sub = az account show --query id -o tsv
  $kvKeysUrl = "https://management.azure.com/subscriptions/$sub/resourceGroups/$ResourceGroup/providers/Microsoft.KeyVault/vaults/$AttestKeyVault/keys?api-version=2024-04-01-preview"
  az rest --method GET --url $kvKeysUrl --query "value[].{name:name, purpose:tags.Purpose, notForData:tags.\`"Not-Used-For\`"}" -o table

  Show-StageLine 'Both keys are Azure''s. Neither of them holds the customer''s application data key. That key is in the on-prem Vault we just looked at.'
}

function Invoke-Act2 {
  Show-ActBanner 2 'The customer bursts' -TargetSeconds 60
  Show-StageLine 'The customer''s on-prem orchestrator is deciding to consume Azure burst compute. Azure is not initiating this.'
  Wait-Gate 'ENTER to start the CVM if it isn''t already running' | Out-Null

  Ensure-AzContext
  $state = Get-VmPowerState
  Show-Doing "azure: current power state = $state"
  if ($state -ne 'VM running') {
    Show-Doing "azure: az vm start -g $ResourceGroup -n $VmName"
    az vm start -g $ResourceGroup -n $VmName --no-wait | Out-Null
    $script:VmStartedByUs = $true
    Wait-VmRunning -TimeoutSec 180
  } else {
    Show-Doing 'azure: CVM already running, no start needed'
  }

  Show-StageLine 'The machine is up. No data has moved yet. And this VM has no permissions on any storage account.'
  Show-Doing 'azure: confirm the CVM MI has zero Storage roles anywhere'
  $vmPrincipalId = az vm show -g $ResourceGroup -n $VmName --query 'identity.principalId' -o tsv
  $storageRoles = az role assignment list --assignee $vmPrincipalId --all --query "[?contains(roleDefinitionName, 'Storage')].roleDefinitionName" -o tsv
  if ([string]::IsNullOrWhiteSpace($storageRoles)) {
    Write-Host '    (empty — confirmed no Storage roles)' -ForegroundColor Green
  } else {
    Write-Host '    UNEXPECTED — Storage roles present:' -ForegroundColor Red
    Write-Host $storageRoles
  }
}

function Invoke-Act345Burst {
  Show-ActBanner 3 'Attest, fetch, unwrap' -TargetSeconds 90
  Show-StageLine 'The CVM inside Azure is going to ask the edge for the video. The edge — not Azure — will decide whether to release the key.'
  Wait-Gate 'ENTER to trigger the burst (Acts 3, 4, and 5 all stream from this one call)' | Out-Null

  Show-Doing "orchestrator: demo-burst.ps1 -Video $Video (streams live)"
  Show-Note 'Narrate Act 3 during phases 1-4 (attestation, fetch, unwrap, decrypt).'
  Show-Note 'Narrate Act 4 during phases 5-7 (process, encrypt, wrap).'
  Show-Note 'Narrate Act 5 during phase 8 and the deallocation.'
  Write-Host ''

  # Run demo-burst.ps1 with pass-through output. Deallocate=true so Act 5 completes naturally.
  & (Join-Path $scriptDir 'demo-burst.ps1') -Video $Video -Subscription $Subscription -ResourceGroup $ResourceGroup -VmName $VmName -EdgeFetchUrl $EdgeFetchUrl

  # The burst script already tailed the audit; add one more pass for the final state.
  Show-ActBanner 4 'Processing happened in CVM memory. Nothing landed in Azure.' -TargetSeconds 60
  Show-StageLine 'Look at the phase events — sha256, byte count, thumbnail. All computed against plaintext that only ever lived in CVM memory. The OS disk metrics are flat.'
  Wait-Gate 'ENTER to advance' | Out-Null

  Show-ActBanner 5 'Result home; CVM gone.' -TargetSeconds 45
  Show-StageLine 'The re-encrypted result is on the edge. The CVM is deallocating. Data was in Azure for approximately 90 seconds. The bill just stopped.'
  Show-Doing 'edge: confirm the result envelope landed'
  Invoke-Edge 'sudo ls -la /var/lib/edge-fetch/processed/ | tail -5'
  $script:VmStartedByUs = $false   # demo-burst.ps1 handles its own deallocation
}

function Invoke-Act6a {
  Show-ActBanner '6a' 'Kill switch A — edge disables the data key' -TargetSeconds 45
  Show-StageLine 'The customer is now denying Azure the ability to decrypt anything, from the edge. No Azure API is being called.'
  $choice = Wait-Gate 'ENTER to run Toggle A (S=skip)' -AllowSkip
  if ($choice -eq 'SKIP') { Show-Note 'skipped'; return }

  Show-Doing 'edge: demo-toggle-vault.ps1 -Disable (bumps min_decryption_version)'
  & (Join-Path $scriptDir 'demo-toggle-vault.ps1') -Disable
  $script:VaultDisabled = $true

  Show-StageLine 'The CVM will attest and fetch, but the unwrap call will fail 403. That''s the sovereignty story — a property of the wiring, not a promise from Microsoft.'
  Wait-Gate 'ENTER to run the burst and prove the kill' | Out-Null

  # Restart the CVM briefly for the failed-burst demo
  Ensure-AzContext
  if ((Get-VmPowerState) -ne 'VM running') {
    Show-Doing 'azure: starting CVM for the failed-burst demo'
    az vm start -g $ResourceGroup -n $VmName --no-wait | Out-Null
    $script:VmStartedByUs = $true
    Wait-VmRunning -TimeoutSec 180
  }

  Show-Doing 'orchestrator: demo-burst.ps1 (expect Phase C unwrap failure)'
  try {
    & (Join-Path $scriptDir 'demo-burst.ps1') -Video $Video -Subscription $Subscription -ResourceGroup $ResourceGroup -VmName $VmName -EdgeFetchUrl $EdgeFetchUrl
  } catch {
    Show-Doing 'orchestrator returned non-zero — that''s the expected failure'
  }
  $script:VmStartedByUs = $false

  Show-StageLine 'Restoring the key so the next audience sees a working demo.'
  Wait-Gate 'ENTER to re-enable' | Out-Null
  & (Join-Path $scriptDir 'demo-toggle-vault.ps1') -Enable
  $script:VaultDisabled = $false
}

function Invoke-Act6b {
  Show-ActBanner '6b' 'Kill switch B — Azure disables the OS attestation key' -TargetSeconds 45
  Show-StageLine 'Now Microsoft is denying startup. Different toggle. Different outcome. Azure can stop the compute; that''s the extent of Azure''s power.'
  $choice = Wait-Gate 'ENTER to run Toggle B (S=skip)' -AllowSkip
  if ($choice -eq 'SKIP') { Show-Note 'skipped'; return }

  Show-Doing 'azure: demo-toggle-azurekek.ps1 -Disable (bumps vault firewall + data-plane set-attributes false)'
  & (Join-Path $scriptDir 'demo-toggle-azurekek.ps1') -Disable
  $script:AzureKekDisabled = $true

  Show-StageLine 'When we try to burst, the orchestrator preflights the AKV key and aborts BEFORE `az vm start`. A real SEV-SNP DES would fail at boot for the same reason.'
  Wait-Gate 'ENTER to run the burst and prove the preflight abort' | Out-Null

  Show-Doing 'orchestrator: demo-burst.ps1 (expect preflight abort at Step 1/6)'
  try {
    & (Join-Path $scriptDir 'demo-burst.ps1') -Video $Video -Subscription $Subscription -ResourceGroup $ResourceGroup -VmName $VmName -EdgeFetchUrl $EdgeFetchUrl
  } catch {
    Show-Doing 'orchestrator aborted at preflight — that''s the expected behavior'
  }

  Show-StageLine 'Restoring the key.'
  Wait-Gate 'ENTER to re-enable' | Out-Null
  & (Join-Path $scriptDir 'demo-toggle-azurekek.ps1') -Enable
  $script:AzureKekDisabled = $false
}

# ========================================================================
# Main
# ========================================================================

function Show-Intro {
  Clear-Host
  Write-Host ''
  Write-Host '   BURST TO AZURE WITHOUT GIVING UP THE KEYS' -ForegroundColor Cyan
  Write-Host '   Sovereign Hybrid Compute Demo — Presenter Mode' -ForegroundColor DarkCyan
  Show-Divider
  Write-Host "   Video ID       : $Video"
  Write-Host "   Subscription   : $Subscription"
  Write-Host "   RG / VM        : $ResourceGroup / $VmName"
  Write-Host "   Edge fetch     : $EdgeFetchUrl"
  Write-Host "   Skip toggles?  : $($SkipToggles.IsPresent)"
  Write-Host "   Rehearse mode  : $($Rehearse.IsPresent)"
  Show-Divider
  Write-Host ''
  Write-Host '   Controls: ENTER = advance   S = skip (where allowed)   Q or Ctrl-C = quit' -ForegroundColor DarkGray
  Write-Host ''
  Wait-Gate 'ENTER when ready to begin' | Out-Null
}

$startedUtc = [DateTime]::UtcNow

try {
  Show-Intro
  Invoke-Act1
  Invoke-Act2
  Invoke-Act345Burst

  if (-not $SkipToggles) {
    Invoke-Act6a
    Invoke-Act6b
  } else {
    Show-Note 'SkipToggles set — ending after Act 5'
  }

  $elapsed = ([DateTime]::UtcNow - $startedUtc).TotalSeconds
  $doneMsg = "  DEMO COMPLETE -- wall clock {0:N0}s ({1:N1} minutes)" -f $elapsed, ($elapsed / 60)
  Write-Host ''
  Write-Host '=========================================================================' -ForegroundColor Green
  Write-Host $doneMsg -ForegroundColor Green
  Write-Host '=========================================================================' -ForegroundColor Green
} catch {
  $msg = $_.Exception.Message
  if ($msg -eq 'operator quit') {
    Write-Host ''
    Write-Host '  Quit by operator.' -ForegroundColor Yellow
  } else {
    Write-Host ''
    Write-Host "  ERROR: $msg" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
  }
} finally {
  # Best-effort recovery: if we started the CVM ourselves, deallocate it.
  # If either kill-switch key was disabled by us and not yet restored, restore
  # it. If restore fails, print an explicit warning so the operator doesn't
  # walk away thinking the world is back to normal.
  if ($script:VmStartedByUs) {
    Write-Host ''
    Write-Host '  Cleanup: deallocating CVM (we started it, so we stop it).' -ForegroundColor DarkYellow
    az vm deallocate -g $ResourceGroup -n $VmName --no-wait 2>$null | Out-Null
  }
  if ($script:VaultDisabled) {
    Write-Host ''
    Write-Host '  Cleanup: EDGE VAULT KEY IS STILL DISABLED — attempting -Enable...' -ForegroundColor Yellow
    try {
      & (Join-Path $scriptDir 'demo-toggle-vault.ps1') -Enable
      Write-Host '  Edge Vault key restored.' -ForegroundColor Green
    } catch {
      Write-Host ''
      Write-Host '  ==== ACTION REQUIRED ====' -ForegroundColor Red
      Write-Host '  Could not automatically re-enable the edge Vault Transit key.' -ForegroundColor Red
      Write-Host '  Run this manually before the next demo:' -ForegroundColor Red
      Write-Host '      .\scripts\demo-toggle-vault.ps1 -Enable' -ForegroundColor Red
      Write-Host "  Underlying error: $($_.Exception.Message)" -ForegroundColor Red
    }
  }
  if ($script:AzureKekDisabled) {
    Write-Host ''
    Write-Host '  Cleanup: AZURE KV ATTESTATION KEY IS STILL DISABLED — attempting -Enable...' -ForegroundColor Yellow
    try {
      & (Join-Path $scriptDir 'demo-toggle-azurekek.ps1') -Enable
      Write-Host '  Azure Key Vault attestation key restored.' -ForegroundColor Green
    } catch {
      Write-Host ''
      Write-Host '  ==== ACTION REQUIRED ====' -ForegroundColor Red
      Write-Host '  Could not automatically re-enable acxhtx-cvm-attestation-key.' -ForegroundColor Red
      Write-Host '  Run this manually before the next demo:' -ForegroundColor Red
      Write-Host '      .\scripts\demo-toggle-azurekek.ps1 -Enable' -ForegroundColor Red
      Write-Host "  Underlying error: $($_.Exception.Message)" -ForegroundColor Red
    }
  }
}
