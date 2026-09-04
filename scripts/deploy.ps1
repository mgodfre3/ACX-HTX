<#
.SYNOPSIS
  Deploy the ACX-HTX resource group and all resources.

.EXAMPLE
  ./scripts/deploy.ps1 -SubscriptionId <sub> -CvmAdminPassword (Read-Host -AsSecureString) -AllowedSourceIp 203.0.113.4/32
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][SecureString]$CvmAdminPassword,
    [Parameter(Mandatory)][string]$AllowedSourceIp,
    [string]$Location = 'eastus2',
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

az account set --subscription $SubscriptionId | Out-Null

$plainPw = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($CvmAdminPassword))

$env:CVM_ADMIN_PASSWORD = $plainPw
$env:ALLOWED_SOURCE_IP = $AllowedSourceIp

$deploymentName = "acx-htx-$(Get-Date -Format yyyyMMdd-HHmm)"

Write-Host "Checking DCadsv5 quota in $Location..." -ForegroundColor Cyan
$quota = az vm list-usage --location $Location --output json | ConvertFrom-Json |
    Where-Object { $_.name.value -like '*DCADSv5*' -or $_.name.value -like '*standardDCAdsv5*' }
if ($quota) {
    $quota | ForEach-Object { Write-Host "    $($_.name.localizedValue): $($_.currentValue)/$($_.limit)" }
} else {
    Write-Warning "Could not find DCadsv5 quota entry. Proceeding anyway."
}

$op = if ($WhatIf) { 'what-if' } else { 'create' }
Write-Host "Running deployment '$deploymentName' ($op)..." -ForegroundColor Cyan

az deployment sub $op `
    --location $Location `
    --template-file "$root/infra/main.bicep" `
    --parameters "$root/infra/main.bicepparam" `
    --name $deploymentName

# Scrub env
Remove-Item Env:CVM_ADMIN_PASSWORD -ErrorAction SilentlyContinue
Remove-Item Env:ALLOWED_SOURCE_IP -ErrorAction SilentlyContinue

Write-Host "Done." -ForegroundColor Green
