<#
.SYNOPSIS
    Retire ("checkout") un secret du coffre-fort avec justification obligatoire, journalisé
    dans un registre d'audit.

.DESCRIPTION
    Déchiffre l'entrée demandée et retourne le secret en SecureString — jamais affiché en clair
    sur la console par défaut, c'est à l'appelant de le convertir s'il en a réellement besoin.
    Chaque retrait est tracé (qui, quand, quel secret, pourquoi) dans un registre, même
    discipline que Grant-JitAccess.ps1 côté accès juste-à-temps : un retrait de secret sans
    motif n'est pas auditable.

.PARAMETER SecretName
    Identifiant du secret à retirer.

.PARAMETER Reason
    Justification du retrait — obligatoire.

.PARAMETER VaultJson
    Fichier du coffre-fort. Vault.json par défaut.

.PARAMETER KeyFile
    Fichier de la clé de chiffrement AES-256. vault.key par défaut.

.PARAMETER CheckoutLedgerCsv
    Registre des retraits. Vault_Checkout_Ledger.csv par défaut.

.EXAMPLE
    .\Get-VaultSecret.ps1 -SecretName "svc-vault-test" -Reason "Maintenance planifiée"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$SecretName,

    [Parameter(Mandatory)]
    [string]$Reason,

    [string]$VaultJson = "Vault.json",

    [string]$KeyFile = "vault.key",

    [string]$CheckoutLedgerCsv = "Vault_Checkout_Ledger.csv"
)

# -Encoding UTF8 ajoute le BOM sous Windows PowerShell 5.1 mais pas sous PowerShell 7+, où
# Excel (locale FR) lit alors les accents comme du Windows-1252 et les corrompt. On force le
# BOM sur les deux versions.
$csvEncoding = if ($PSVersionTable.PSVersion.Major -ge 6) { 'utf8BOM' } else { 'UTF8' }

$result = [PSCustomObject]@{
    SecretName     = $SecretName
    SamAccountName = ""
    Secret         = $null
    Status         = "Failed"
    Error          = ""
}

try {
    if (-not (Test-Path $KeyFile)) {
        throw "Clé de coffre-fort introuvable : $KeyFile — aucun secret n'a encore été stocké avec Add-VaultSecret.ps1 ?"
    }
    if (-not (Test-Path $VaultJson)) {
        throw "Coffre-fort introuvable : $VaultJson"
    }

    $keyBytes = [System.IO.File]::ReadAllBytes((Resolve-Path $KeyFile))
    $vaultEntries = @(Get-Content $VaultJson -Raw | ConvertFrom-Json)
    $entry = $vaultEntries | Where-Object { $_.SecretName -eq $SecretName } | Select-Object -First 1
    if (-not $entry) {
        throw "Secret introuvable dans le coffre-fort : $SecretName"
    }

    $result.SamAccountName = $entry.SamAccountName
    $result.Secret = ConvertTo-SecureString -String $entry.EncryptedSecret -Key $keyBytes

    $ledgerRows = if (Test-Path $CheckoutLedgerCsv) { @(Import-Csv $CheckoutLedgerCsv) } else { @() }
    $ledgerRows += [PSCustomObject]@{
        SecretName     = $SecretName
        SamAccountName = $entry.SamAccountName
        CheckedOutAt   = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        CheckedOutBy   = $env:USERNAME
        Reason         = $Reason
    }
    $ledgerRows | Export-Csv $CheckoutLedgerCsv -NoTypeInformation -Encoding $csvEncoding

    $result.Status = "Success"
    Write-Host "=== Secret retiré : $SecretName (compte AD associé : $($entry.SamAccountName)) ===" -ForegroundColor Green
    Write-Host "Motif consigné dans $CheckoutLedgerCsv — secret retourné en SecureString, jamais affiché en clair." -ForegroundColor DarkGray
}
catch {
    $result.Error = $_.Exception.Message
    Write-Host "ERREUR Get-VaultSecret $SecretName : $($_.Exception.Message)" -ForegroundColor Red
}

$result
