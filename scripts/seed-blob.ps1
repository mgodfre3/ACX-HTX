<#
.SYNOPSIS
  Generate a synthetic "classified cold slice", encrypt it, wrap the DEK with the KEK
  in Azure Key Vault, and upload the envelope to the storage account.

  This stands in for the future Azure Local Disconnected Operations flow where the
  local side produces this envelope and ships it to Azure.

.PARAMETER ResourceGroup
  Resource group containing AKV + Storage. Defaults to ACX-HTX.

.PARAMETER SubscriptionId
  Optional. If provided, sets the active subscription first.

.EXAMPLE
  ./scripts/seed-blob.ps1 -ResourceGroup ACX-HTX
#>
[CmdletBinding()]
param(
    [string]$ResourceGroup = 'ACX-HTX',
    [string]$SubscriptionId,
    [string]$ContainerName = 'sovereign-cold',
    [string]$KekName = 'htx-kek',
    [int]$DocCount = 25
)

$ErrorActionPreference = 'Stop'

function Get-AzCliJson {
    param([string[]]$Args)
    $raw = & az @Args --output json 2>&1
    if ($LASTEXITCODE -ne 0) { throw "az $($Args -join ' ') failed: $raw" }
    return ($raw | ConvertFrom-Json)
}

if ($SubscriptionId) {
    az account set --subscription $SubscriptionId | Out-Null
}

Write-Host "[1/6] Discovering resources in RG '$ResourceGroup'..." -ForegroundColor Cyan
$kv = Get-AzCliJson @('keyvault','list','--resource-group',$ResourceGroup,'--query','[?properties.sku.name==`premium`] | [0]')
if (-not $kv) { throw "No Premium Key Vault found in $ResourceGroup." }
$stg = Get-AzCliJson @('storage','account','list','--resource-group',$ResourceGroup,'--query','[?not_null(encryption.keyVaultProperties.keyName)] | [0]')
if (-not $stg) { throw "No CMK-enabled Storage Account found in $ResourceGroup." }

Write-Host "    Key Vault: $($kv.name)"
Write-Host "    Storage:   $($stg.name)"
Write-Host "    KEK:       $KekName"

Write-Host "[2/6] Generating synthetic classified docs ($DocCount)..." -ForegroundColor Cyan
$classifications = @('CONFIDENTIAL','SECRET','TOP SECRET','RESTRICTED')
$subjects = @('Border sensor telemetry','Fleet movement analysis','Cyber incident report','Signals correlation','Asset tracking summary','Threat pattern analysis')
$docs = 1..$DocCount | ForEach-Object {
    [pscustomobject]@{
        id             = [Guid]::NewGuid().ToString()
        classification = Get-Random -InputObject $classifications
        subject        = Get-Random -InputObject $subjects
        timestamp      = (Get-Date).AddMinutes(-(Get-Random -Min 0 -Max 10080)).ToString('o')
        body           = "Synthetic record $_. This is demo content representing a sensitive report that was originally processed on Azure Local. It is being shipped as a cold slice to Azure inside an encrypted envelope."
    }
}
$plaintext = ($docs | ConvertTo-Json -Depth 5) 
$plainBytes = [System.Text.Encoding]::UTF8.GetBytes($plaintext)

Write-Host "[3/6] Generating DEK + encrypting payload (AES-256-GCM)..." -ForegroundColor Cyan
Add-Type -AssemblyName System.Security
$dek = New-Object byte[] 32
[System.Security.Cryptography.RandomNumberGenerator]::Fill($dek)
$nonce = New-Object byte[] 12
[System.Security.Cryptography.RandomNumberGenerator]::Fill($nonce)
$tag = New-Object byte[] 16
$ciphertext = New-Object byte[] $plainBytes.Length
$aes = [System.Security.Cryptography.AesGcm]::new($dek)
$aes.Encrypt($nonce, $plainBytes, $ciphertext, $tag, $null)
$aes.Dispose()

Write-Host "[4/6] Wrapping DEK with KEK '$KekName' in AKV..." -ForegroundColor Cyan
$dekB64 = [Convert]::ToBase64String($dek)
$tmp = New-TemporaryFile
[System.IO.File]::WriteAllBytes($tmp, $dek)
$wrap = Get-AzCliJson @('keyvault','key','encrypt','--vault-name',$kv.name,'--name',$KekName,'--algorithm','RSA-OAEP-256','--value',$dekB64,'--data-type','base64')
Remove-Item $tmp -Force
$wrappedDek = $wrap.result

Write-Host "[5/6] Building envelope..." -ForegroundColor Cyan
$envelope = [pscustomobject]@{
    version           = '1'
    createdUtc        = (Get-Date).ToUniversalTime().ToString('o')
    source            = 'seed-script (Azure-side stand-in for ALDO)'
    kekVaultUri       = $kv.properties.vaultUri
    kekName           = $KekName
    wrappedDek        = $wrappedDek
    wrapAlgorithm     = 'RSA-OAEP-256'
    dataAlgorithm     = 'AES-256-GCM'
    nonce             = [Convert]::ToBase64String($nonce)
    tag               = [Convert]::ToBase64String($tag)
    ciphertext        = [Convert]::ToBase64String($ciphertext)
    documentCount     = $DocCount
}
$envelopeJson = $envelope | ConvertTo-Json -Depth 5
$blobName = "cold-slice-$(Get-Date -Format yyyyMMdd-HHmmss).json"
$localPath = Join-Path $env:TEMP $blobName
$envelopeJson | Set-Content -Path $localPath -Encoding utf8

Write-Host "[6/6] Uploading envelope to $($stg.name)/$ContainerName/$blobName ..." -ForegroundColor Cyan
az storage blob upload `
    --account-name $stg.name `
    --container-name $ContainerName `
    --name $blobName `
    --file $localPath `
    --auth-mode login `
    --overwrite true | Out-Null

Remove-Item $localPath -Force
Write-Host ""
Write-Host "Done. Envelope uploaded as $blobName" -ForegroundColor Green
Write-Host "The CVM decrypt+summarize service can now pull this blob, unwrap the DEK via AKV,"
Write-Host "decrypt inside its TEE, and produce a summary."
