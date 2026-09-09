<#
.SYNOPSIS
  Install the burst-consumer package on the Azure CVM (acxhtx-vm).

.DESCRIPTION
  Run once on the Azure CVM as Administrator after connecting via Bastion.
  Idempotent: re-run to update config or refresh the venv.

  Installs:
    - Python 3.12 (if missing) via winget
    - A venv at C:\HTX\burst-consumer\venv
    - The burst_consumer package from the repo
    - A .cmd shim at C:\HTX\burst-consumer\run.cmd that the orchestrator invokes

  Configures env vars (Machine scope):
    BURST_CONSUMER_EDGE_FETCH_URL
    BURST_CONSUMER_EDGE_UNWRAP_URL
    BURST_CONSUMER_ATTESTATION_MODE

.PARAMETER RepoRoot
  Path to the cloned ACX-HTX repo on this VM (default C:\HTX\repo).

.PARAMETER EdgeFetchUrl
  URL of the ALDO edge-fetch server. Default http://172.22.218.200:8444.

.PARAMETER EdgeUnwrapUrl
  URL of the ALDO unwrap service. Default http://172.22.218.200:8443.

.PARAMETER AttestationMode
  "stub-tl-imds" (default) or "sev-snp".
#>

[CmdletBinding()]
param(
  [string]$RepoRoot         = 'C:\HTX\repo',
  [string]$EdgeFetchUrl     = 'http://172.22.218.200:8444',
  [string]$EdgeUnwrapUrl    = 'http://172.22.218.200:8443',
  [ValidateSet('stub-tl-imds','sev-snp')]
  [string]$AttestationMode  = 'stub-tl-imds'
)

$ErrorActionPreference = 'Stop'
$installRoot = 'C:\HTX\burst-consumer'

Write-Host "== Install root      : $installRoot"
Write-Host "== Repo root         : $RepoRoot"
Write-Host "== Edge fetch URL    : $EdgeFetchUrl"
Write-Host "== Edge unwrap URL   : $EdgeUnwrapUrl"
Write-Host "== Attestation mode  : $AttestationMode"

# --- Python ---
if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
  Write-Host "-- Installing Python 3.12 via winget..."
  winget install --id Python.Python.3.12 -e --accept-source-agreements --accept-package-agreements
  $env:PATH = [Environment]::GetEnvironmentVariable('PATH','Machine')
}

python --version | Write-Host

# --- Repo present? ---
if (-not (Test-Path "$RepoRoot\cvm-app\burst_consumer")) {
  throw "cvm-app/burst_consumer not found under RepoRoot=$RepoRoot. Clone the ACX-HTX repo there first."
}

# --- venv ---
New-Item -ItemType Directory -Path $installRoot -Force | Out-Null
if (-not (Test-Path "$installRoot\venv\Scripts\python.exe")) {
  Write-Host "-- Creating venv at $installRoot\venv"
  python -m venv "$installRoot\venv"
}
& "$installRoot\venv\Scripts\python.exe" -m pip install --upgrade pip
& "$installRoot\venv\Scripts\python.exe" -m pip install -r "$RepoRoot\cvm-app\requirements.txt"

# Copy the package into the install root so a repo re-checkout doesn't affect the running service.
Copy-Item -Recurse -Force "$RepoRoot\cvm-app\burst_consumer" "$installRoot\burst_consumer"

# --- Env vars (Machine scope so scheduled tasks see them) ---
[Environment]::SetEnvironmentVariable('BURST_CONSUMER_EDGE_FETCH_URL',    $EdgeFetchUrl,    'Machine')
[Environment]::SetEnvironmentVariable('BURST_CONSUMER_EDGE_UNWRAP_URL',   $EdgeUnwrapUrl,   'Machine')
[Environment]::SetEnvironmentVariable('BURST_CONSUMER_ATTESTATION_MODE',  $AttestationMode, 'Machine')

# --- Run shim ---
$runCmd = @"
@echo off
setlocal
set PYTHONPATH=$installRoot
"$installRoot\venv\Scripts\python.exe" -m burst_consumer.main %*
"@
$runCmd | Out-File -Encoding ASCII -FilePath "$installRoot\run.cmd" -Force

# --- Verify ---
Write-Host ""
Write-Host "-- Verifying import chain --"
& "$installRoot\venv\Scripts\python.exe" -c "import sys; sys.path.insert(0, r'$installRoot'); from burst_consumer import main, attestation; print('OK', main.__file__)"

Write-Host ""
Write-Host "-- Ready. Usage --"
Write-Host "  From this VM:"
Write-Host "     $installRoot\run.cmd --video-id sample-video-01"
Write-Host "  From the orchestrator (operator laptop):"
Write-Host "     az vm run-command invoke -g ACX-HTX -n acxhtx-vm ``"
Write-Host "       --command-id RunPowerShellScript ``"
Write-Host "       --scripts ""$installRoot\run.cmd --video-id sample-video-01"" "
