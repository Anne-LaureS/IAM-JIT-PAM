<#
.SYNOPSIS
    Retire l'appartenance aux groupes à privilège dont l'accès juste-à-temps a expiré, d'après
    le registre tenu par Grant-JitAccess.ps1.

.DESCRIPTION
    Pensé pour tourner périodiquement (tâche planifiée en production, ex: toutes les 5 minutes)
    — ce script est le mécanisme de révocation qui referme la boucle ouverte par
    Grant-JitAccess.ps1. Ne casse jamais sur une ligne : un accès déjà retiré manuellement entre
    temps est signalé, pas traité comme une erreur bloquante pour le reste du lot.

.PARAMETER Server
    Contrôleur de domaine cible. DC1.society.local par défaut.

.PARAMETER Credential
    Identifiants pour le bind AD. Si omis, demandés interactivement.

.PARAMETER LedgerCsv
    Registre des accords JIT tenu par Grant-JitAccess.ps1. JIT_Access_Ledger.csv par défaut.

.EXAMPLE
    .\Revoke-ExpiredJitAccess.ps1
#>

[CmdletBinding()]
param(
    [string]$Server = "DC1.society.local",

    [System.Management.Automation.PSCredential]$Credential,

    [string]$LedgerCsv = "JIT_Access_Ledger.csv"
)

# -Encoding UTF8 ajoute le BOM sous Windows PowerShell 5.1 mais pas sous PowerShell 7+, où
# Excel (locale FR) lit alors les accents comme du Windows-1252 et les corrompt. On force le
# BOM sur les deux versions.
$csvEncoding = if ($PSVersionTable.PSVersion.Major -ge 6) { 'utf8BOM' } else { 'UTF8' }

if (-not (Test-Path $LedgerCsv)) {
    Write-Host "Aucun registre trouvé ($LedgerCsv) — rien à traiter." -ForegroundColor Green
    exit 0
}

if (-not $Credential) {
    $Credential = Get-Credential -Message "Identifiants pour le bind sur $Server"
}

$ledgerRows = @(Import-Csv $LedgerCsv)
$now = Get-Date

$expiredCount = 0
$alreadyRemovedCount = 0
$stillActiveCount = 0

foreach ($row in $ledgerRows) {
    if ($row.Status -ne "Active") { continue }

    $expiresAt = [datetime]::ParseExact($row.ExpiresAt, "yyyy-MM-dd HH:mm:ss", $null)
    if ($expiresAt -gt $now) {
        $stillActiveCount++
        continue
    }

    try {
        Remove-ADPrincipalGroupMembership -Identity $row.Person -MemberOf $row.Group -Server $Server -Credential $Credential -Confirm:$false -ErrorAction Stop
        $row.Status = "Expired"
        $expiredCount++
        Write-Host "=== Accès JIT révoqué : $($row.Person) -> $($row.Group) (expiré le $($row.ExpiresAt)) ===" -ForegroundColor Green
    }
    catch {
        # Déjà retiré manuellement entre-temps, ou le compte/groupe n'existe plus — on le note
        # dans le registre sans faire échouer le traitement des autres lignes.
        $row.Status = "ExpiredManually"
        $alreadyRemovedCount++
        Write-Host "ATTENTION : $($row.Person) -> $($row.Group) déjà retiré ou introuvable ($($_.Exception.Message)) — marqué ExpiredManually." -ForegroundColor Yellow
    }
}

$ledgerRows | Export-Csv $LedgerCsv -NoTypeInformation -Encoding $csvEncoding

Write-Host ""
Write-Host "=== Résumé ===" -ForegroundColor Cyan
Write-Host "Accès révoqués à l'expiration : $expiredCount" -ForegroundColor Green
Write-Host "Déjà retirés manuellement (signalés) : $alreadyRemovedCount" -ForegroundColor Yellow
Write-Host "Toujours actifs (pas encore expirés) : $stillActiveCount"
