<#
.SYNOPSIS
    Stocke (ou remplace) un secret chiffré dans le coffre-fort — 2ème volet PAM du repo, à côté
    de l'accès juste-à-temps.

.DESCRIPTION
    Chiffre le mot de passe avec AES-256 (`ConvertFrom-SecureString -Key`, natif PowerShell,
    aucune dépendance externe) avant de l'écrire dans le coffre-fort JSON. Génère la clé de
    chiffrement au premier usage si elle n'existe pas encore — jamais régénérée après coup, ce
    qui rendrait tous les secrets déjà stockés illisibles.

    Limite assumée : une clé conservée dans un fichier (protégé par les ACL NTFS du système de
    fichiers) n'est pas un HSM — c'est une simplification de lab, pas ce qu'utiliserait un vrai
    produit PAM (CyberArk, HashiCorp Vault) en production.

.PARAMETER SecretName
    Identifiant du secret dans le coffre-fort (ex: "svc-vault-test").

.PARAMETER SamAccountName
    Compte AD associé à ce secret — c'est lui qui sera modifié par Rotate-VaultSecret.ps1.

.PARAMETER Password
    Le secret à stocker, en SecureString.

.PARAMETER VaultJson
    Fichier du coffre-fort. Vault.json par défaut.

.PARAMETER KeyFile
    Fichier de la clé de chiffrement AES-256. vault.key par défaut, généré au premier usage.

.EXAMPLE
    .\Add-VaultSecret.ps1 -SecretName "svc-vault-test" -SamAccountName "svc-vault-test" -Password (Read-Host -AsSecureString)
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$SecretName,

    [Parameter(Mandatory)]
    [string]$SamAccountName,

    [Parameter(Mandatory)]
    [System.Security.SecureString]$Password,

    [string]$VaultJson = "Vault.json",

    [string]$KeyFile = "vault.key"
)

function Get-OrCreateVaultKey {
    param([string]$KeyFile)
    if (Test-Path $KeyFile) {
        return [System.IO.File]::ReadAllBytes((Resolve-Path $KeyFile))
    }
    $keyBytes = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($keyBytes)
    [System.IO.File]::WriteAllBytes("$PWD\$KeyFile", $keyBytes)
    Write-Host "Nouvelle clé de coffre-fort générée : $KeyFile — à sauvegarder/protéger, sans elle aucun secret n'est récupérable." -ForegroundColor Yellow
    return $keyBytes
}

$result = [PSCustomObject]@{
    SecretName     = $SecretName
    SamAccountName = $SamAccountName
    LastRotated    = ""
    Status         = "Failed"
    Error          = ""
}

try {
    $keyBytes = Get-OrCreateVaultKey -KeyFile $KeyFile
    $encrypted = ConvertFrom-SecureString -SecureString $Password -Key $keyBytes

    $vaultEntries = if (Test-Path $VaultJson) { @(Get-Content $VaultJson -Raw | ConvertFrom-Json) } else { @() }
    $vaultEntries = $vaultEntries | Where-Object { $_.SecretName -ne $SecretName }

    $now = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $vaultEntries += [PSCustomObject]@{
        SecretName      = $SecretName
        SamAccountName  = $SamAccountName
        EncryptedSecret = $encrypted
        LastRotated     = $now
    }
    $vaultEntries | ConvertTo-Json -Depth 5 | Out-File $VaultJson -Encoding utf8BOM

    $result.LastRotated = $now
    $result.Status = "Success"
    Write-Host "=== Secret stocké : $SecretName (compte AD associé : $SamAccountName) ===" -ForegroundColor Green
}
catch {
    $result.Error = $_.Exception.Message
    Write-Host "ERREUR Add-VaultSecret $SecretName : $($_.Exception.Message)" -ForegroundColor Red
}

$result
