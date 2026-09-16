<#
.SYNOPSIS
    Génère un nouveau mot de passe, le pose réellement sur le compte AD associé, et met à jour
    le coffre-fort — la rotation qui referme la boucle après un checkout.

.DESCRIPTION
    Contrairement à un simple renouvellement côté coffre-fort, ce script change réellement le
    mot de passe du compte AD associé au secret (`Set-ADAccountPassword -Reset`) avant de
    chiffrer et stocker la nouvelle valeur — l'ancien mot de passe cesse de fonctionner
    immédiatement, ce n'est pas juste une mise à jour de registre.

.PARAMETER SecretName
    Identifiant du secret à faire tourner.

.PARAMETER Server
    Contrôleur de domaine cible. DC1.society.local par défaut.

.PARAMETER Credential
    Identifiants admin pour le bind AD. Si omis, demandés interactivement.

.PARAMETER VaultJson
    Fichier du coffre-fort. Vault.json par défaut.

.PARAMETER KeyFile
    Fichier de la clé de chiffrement AES-256. vault.key par défaut.

.EXAMPLE
    .\Rotate-VaultSecret.ps1 -SecretName "svc-vault-test"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$SecretName,

    [string]$Server = "DC1.society.local",

    [System.Management.Automation.PSCredential]$Credential,

    [string]$VaultJson = "Vault.json",

    [string]$KeyFile = "vault.key"
)

function New-RandomPassword {
    # Respecte la complexité AD par défaut (3 des 4 catégories), même fonction que
    # New-Joiner.ps1 dans IAM-JML-Lifecycle.
    $upper   = 'ABCDEFGHJKLMNPQRSTUVWXYZ'
    $lower   = 'abcdefghijkmnpqrstuvwxyz'
    $digits  = '23456789'
    $special = '!@#$%^&*-_+='
    $all = $upper + $lower + $digits + $special
    $required = @(
        $upper[(Get-Random -Maximum $upper.Length)]
        $lower[(Get-Random -Maximum $lower.Length)]
        $digits[(Get-Random -Maximum $digits.Length)]
        $special[(Get-Random -Maximum $special.Length)]
    )
    $rest = 1..10 | ForEach-Object { $all[(Get-Random -Maximum $all.Length)] }
    $chars = @($required + $rest) | Sort-Object { Get-Random }
    return -join $chars
}

# -Encoding UTF8 ajoute le BOM sous Windows PowerShell 5.1 mais pas sous PowerShell 7+, où
# Excel (locale FR) lit alors les accents comme du Windows-1252 et les corrompt. On force le
# BOM sur les deux versions — et "utf8BOM" n'existe même pas comme valeur valide pour -Encoding
# sous Windows PowerShell 5.1, il faut donc bien passer par cette variable, pas la coder en dur.
$fileEncoding = if ($PSVersionTable.PSVersion.Major -ge 6) { 'utf8BOM' } else { 'UTF8' }

$result = [PSCustomObject]@{
    SecretName     = $SecretName
    SamAccountName = ""
    LastRotated    = ""
    Status         = "Failed"
    Error          = ""
}

try {
    if (-not (Test-Path $KeyFile)) { throw "Clé de coffre-fort introuvable : $KeyFile" }
    if (-not (Test-Path $VaultJson)) { throw "Coffre-fort introuvable : $VaultJson" }

    $keyBytes = [System.IO.File]::ReadAllBytes((Resolve-Path $KeyFile))
    $vaultEntries = @(Get-Content $VaultJson -Raw | ConvertFrom-Json)
    $entry = $vaultEntries | Where-Object { $_.SecretName -eq $SecretName } | Select-Object -First 1
    if (-not $entry) { throw "Secret introuvable dans le coffre-fort : $SecretName" }

    $result.SamAccountName = $entry.SamAccountName

    if (-not $Credential) {
        $Credential = Get-Credential -Message "Identifiants pour le bind sur $Server"
    }

    $newPasswordPlain = New-RandomPassword
    $newPasswordSecure = ConvertTo-SecureString $newPasswordPlain -AsPlainText -Force

    Set-ADAccountPassword -Identity $entry.SamAccountName -NewPassword $newPasswordSecure -Reset -Server $Server -Credential $Credential -ErrorAction Stop

    $encrypted = ConvertFrom-SecureString -SecureString $newPasswordSecure -Key $keyBytes
    $now = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $entry.EncryptedSecret = $encrypted
    $entry.LastRotated = $now

    $vaultEntries | ConvertTo-Json -Depth 5 | Out-File $VaultJson -Encoding $fileEncoding

    $result.LastRotated = $now
    $result.Status = "Success"
    Write-Host "=== Secret $SecretName tourné : mot de passe de $($entry.SamAccountName) changé côté AD et coffre-fort mis à jour ===" -ForegroundColor Green
}
catch {
    $result.Error = $_.Exception.Message
    Write-Host "ERREUR Rotate-VaultSecret $SecretName : $($_.Exception.Message)" -ForegroundColor Red
}

$result
