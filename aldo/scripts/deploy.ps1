<#
.SYNOPSIS
  Deploy the ALDO-side sovereign stack to the Tokyo-WKLD stamp.

  Run this from a workstation that is signed into the Autonomous ARM plane
  (subscription ef23bab2-5bd7-afa3-3013-d5116a941684). The public-cloud
  workstation cannot reach the ALDO ARM endpoint.

.EXAMPLE
  # Preview
  ./aldo/scripts/deploy.ps1 -WhatIf

  # Deploy
  ./aldo/scripts/deploy.ps1
#>
[CmdletBinding()]
param(
    [string]$Location = 'Autonomous',
    [string]$SubscriptionId = 'ef23bab2-5bd7-afa3-3013-d5116a941684',
    [switch]$WhatIf,
    [switch]$DeployJumpbox
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

Write-Host "==> Setting subscription context..." -ForegroundColor Cyan
Set-AzContext -Subscription $SubscriptionId | Out-Null
$ctx = Get-AzContext
Write-Host "    Subscription: $($ctx.Subscription.Name) ($($ctx.Subscription.Id))"
Write-Host "    Tenant:       $($ctx.Tenant.Id)"

if ($DeployJumpbox) {
    if (-not $env:ALDO_JUMPBOX_PASSWORD) {
        $pw = Read-Host -AsSecureString "Jumpbox admin password"
        $env:ALDO_JUMPBOX_PASSWORD = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($pw))
    }
}

$deploymentName = "aldo-htx-$(Get-Date -Format yyyyMMdd-HHmm)"

$deploymentArgs = @{
    Location              = $Location
    TemplateFile          = Join-Path $root 'main.bicep'
    TemplateParameterFile = Join-Path $root 'main.bicepparam'
    Name                  = $deploymentName
}

if ($WhatIf) {
    Write-Host "==> Running What-If against '$Location'..." -ForegroundColor Cyan
    Get-AzSubscriptionDeploymentWhatIfResult @deploymentArgs
} else {
    Write-Host "==> Deploying '$deploymentName' to '$Location'..." -ForegroundColor Cyan
    $r = New-AzSubscriptionDeployment @deploymentArgs
    Write-Host ""
    Write-Host "==> Provisioning state: $($r.ProvisioningState)" -ForegroundColor Green
    Write-Host "==> Outputs:" -ForegroundColor Cyan
    $r.Outputs | Format-List
    Write-Host ""
    Write-Host "Next steps:"
    Write-Host "  1. SSH into the Vault VM using the private key at:"
    Write-Host "     ~/.copilot/session-state/<session>/files/htx-vault-ed25519"
    Write-Host "  2. Copy aldo/scripts/init-vault.sh to /tmp and run it under sudo"
    Write-Host "  3. Enable AKS-Arc etcd KMS (see aldo/README.md)"
    Write-Host "  4. Install ACR Connected Registry mirror (see aldo/README.md)"
}

if ($DeployJumpbox -and $env:ALDO_JUMPBOX_PASSWORD) {
    Remove-Item Env:ALDO_JUMPBOX_PASSWORD -ErrorAction SilentlyContinue
}
