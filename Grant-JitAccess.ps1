<#
.SYNOPSIS
    Accorde une appartenance temporaire à un groupe à privilège (accès juste-à-temps), avec
    expiration enregistrée dans un registre pour révocation ultérieure.

.DESCRIPTION
    Active Directory n'a pas de mécanisme natif d'appartenance à groupe à durée limitée
    accessible simplement (la fonctionnalité PAM de Microsoft nécessite une forêt bastion MIM
    PAM séparée). Ce script construit le mécanisme lui-même : il ajoute la personne au groupe
    demandé, puis enregistre l'accord (qui, quel groupe, jusqu'à quand, pourquoi, par qui) dans
    un registre CSV — Revoke-ExpiredJitAccess.ps1 s'appuie ensuite sur ce registre pour retirer
    l'accès à l'expiration.

    Ne crée jamais le groupe cible s'il n'existe pas : un groupe à privilège doit déjà exister
    avec ses délégations réelles, ce script ne gère que l'appartenance temporaire, pas la
    création de périmètres à privilège.

.PARAMETER SamAccountName
    Compte à qui accorder l'accès temporaire.

.PARAMETER GroupName
    Groupe à privilège cible. Ne jamais utiliser sur Domain Admins ou un groupe sensible réel
    en dehors d'un lab de test.

.PARAMETER DurationMinutes
    Durée de l'accès en minutes. Obligatoire — pas de valeur par défaut implicite qui masquerait
    un oubli de préciser la durée (un accès à privilège sans limite de temps n'est pas du JIT).

.PARAMETER Reason
    Justification de la demande — obligatoire, un accès à privilège sans motif n'est pas
    auditable.

.PARAMETER Server
    Contrôleur de domaine cible. DC1.society.local par défaut.

.PARAMETER Credential
    Identifiants pour le bind AD. Si omis, demandés interactivement.

.PARAMETER LedgerCsv
    Registre des accords JIT. JIT_Access_Ledger.csv par défaut, créé avec ses en-têtes s'il
    n'existe pas encore.

.EXAMPLE
    .\Grant-JitAccess.ps1 -SamAccountName "jdupont" -GroupName "PAM-Privileged-Test" -DurationMinutes 2 -Reason "Test JIT"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$SamAccountName,

    [Parameter(Mandatory)]
    [string]$GroupName,

    [Parameter(Mandatory)]
    [int]$DurationMinutes,

    [Parameter(Mandatory)]
    [string]$Reason,

    [string]$Server = "DC1.society.local",

    [System.Management.Automation.PSCredential]$Credential,

    [string]$LedgerCsv = "JIT_Access_Ledger.csv"
)

# -Encoding UTF8 ajoute le BOM sous Windows PowerShell 5.1 mais pas sous PowerShell 7+, où
# Excel (locale FR) lit alors les accents comme du Windows-1252 et les corrompt. On force le
# BOM sur les deux versions.
$csvEncoding = if ($PSVersionTable.PSVersion.Major -ge 6) { 'utf8BOM' } else { 'UTF8' }

$result = [PSCustomObject]@{
    SamAccountName = $SamAccountName
    GroupName      = $GroupName
    GrantedAt      = ""
    ExpiresAt      = ""
    Status         = "Failed"
    Error          = ""
}

try {
    if (-not $Credential) {
        $Credential = Get-Credential -Message "Identifiants pour le bind sur $Server"
    }

    Add-ADPrincipalGroupMembership -Identity $SamAccountName -MemberOf $GroupName -Server $Server -Credential $Credential -ErrorAction Stop

    $grantedAt = Get-Date
    $expiresAt = $grantedAt.AddMinutes($DurationMinutes)
    $result.GrantedAt = $grantedAt.ToString("yyyy-MM-dd HH:mm:ss")
    $result.ExpiresAt = $expiresAt.ToString("yyyy-MM-dd HH:mm:ss")

    $ledgerRows = if (Test-Path $LedgerCsv) { @(Import-Csv $LedgerCsv) } else { @() }
    $ledgerRows += [PSCustomObject]@{
        Person    = $SamAccountName
        Group     = $GroupName
        GrantedAt = $result.GrantedAt
        ExpiresAt = $result.ExpiresAt
        Reason    = $Reason
        GrantedBy = $Credential.UserName
        Status    = "Active"
    }
    $ledgerRows | Export-Csv $LedgerCsv -NoTypeInformation -Encoding $csvEncoding

    $result.Status = "Success"
    Write-Host "=== Accès JIT accordé : $SamAccountName -> $GroupName jusqu'au $($result.ExpiresAt) ===" -ForegroundColor Green
}
catch {
    $result.Error = $_.Exception.Message
    Write-Host "ERREUR Grant-JitAccess $SamAccountName -> $GroupName : $($_.Exception.Message)" -ForegroundColor Red
}

$result
