# ⏱️ IAM JIT PAM

![PowerShell](https://img.shields.io/badge/PowerShell-5391FE?style=for-the-badge&logo=powershell&logoColor=white)
![ActiveDirectory](https://img.shields.io/badge/Active%20Directory-0078D4?style=for-the-badge&logo=windows&logoColor=white)
![PAM](https://img.shields.io/badge/PAM-Just--In--Time%20Access-0d1117?style=for-the-badge)

Premier volet PAM (Privileged Access Management) du portfolio : l'accès **juste-à-temps**
(JIT) — une appartenance à un groupe à privilège accordée pour une durée limitée, avec
révocation automatique à l'expiration, plutôt qu'un accès permanent qui traîne indéfiniment
une fois la tâche terminée.

Active Directory n'a pas de mécanisme natif d'appartenance à groupe à durée limitée simple
d'accès — la vraie fonctionnalité PAM de Microsoft (Privileged Access Management dans
Microsoft Identity Manager) nécessite une forêt bastion séparée, hors de portée d'un lab
mono-domaine. Ce repo construit le mécanisme lui-même : un registre des accords + un script de
révocation à exécuter périodiquement — une pratique réelle et courante en entreprise avant
l'adoption d'un outil PAM du marché (CyberArk, BeyondTrust...).

Testé contre le même lab Active Directory (Windows Server 2022, `DC1.society.local`) que le
reste du portfolio — géré au quotidien par
[IAM-JML-Lifecycle](https://github.com/Anne-LaureS/IAM-JML-Lifecycle) pour l'appartenance
standard, ce repo pour l'appartenance temporaire à privilège. Phase 4 (PAM) de
[IAM-Governance-Roadmap](https://github.com/Anne-LaureS/IAM-Governance-Roadmap).

## ⚙️ Les scripts

| Script | Rôle |
|---|---|
| [`Grant-JitAccess.ps1`](Grant-JitAccess.ps1) | Ajoute une personne à un groupe à privilège pour une durée donnée, avec justification obligatoire, et l'enregistre dans le registre |
| [`Revoke-ExpiredJitAccess.ps1`](Revoke-ExpiredJitAccess.ps1) | Retire l'accès de toutes les lignes du registre dont l'expiration est dépassée |

`Revoke-ExpiredJitAccess.ps1` est pensé pour tourner périodiquement (tâche planifiée en
production, ex: toutes les 5 minutes) — dans cette démo, il se relance à la main après avoir
laissé un accès de test expirer.

## ▶️ Utilisation

```powershell
# Accorder un accès de 2 minutes (court exprès, pour observer l'expiration sans attendre)
.\Grant-JitAccess.ps1 -SamAccountName "jdupont" -GroupName "PAM-Privileged-Test" -DurationMinutes 2 -Reason "Test JIT"

# Attendre l'expiration, puis :
.\Revoke-ExpiredJitAccess.ps1
```

Chaque script demande les identifiants du bind AD interactivement (`Get-Credential`) s'ils ne
sont pas fournis via `-Credential`.

**`PAM-Privileged-Test`** est un groupe dédié à ce lab, créé manuellement au préalable dans
`OU=Applications` ou équivalent — ce script ne crée jamais le groupe cible : un groupe à
privilège doit déjà exister avec ses délégations réelles, seule l'appartenance temporaire est
gérée ici. **Ne jamais utiliser ces scripts sur Domain Admins ou un groupe sensible réel** en
dehors d'un groupe de test dédié.

## 📊 Exemple de bout en bout

Testé pour de vrai contre le lab (`jdupont` → `PAM-Privileged-Test`, 2 minutes) :

```powershell
.\Grant-JitAccess.ps1 -SamAccountName "jdupont" -GroupName "PAM-Privileged-Test" -DurationMinutes 2 -Reason "Test JIT"
```

![Accès JIT accordé](screenshots/grant-success.png)

Un `Revoke-ExpiredJitAccess.ps1` lancé avant l'expiration confirme correctement qu'il n'y a
rien à faire (`Toujours actifs : 1`, `Accès révoqués : 0`) — il ne révoque jamais un accès en
avance. Une fois l'expiration passée :

```powershell
.\Revoke-ExpiredJitAccess.ps1
```

![Accès JIT révoqué à l'expiration](screenshots/revoke-success.png)

`jdupont` a bien perdu l'appartenance à `PAM-Privileged-Test`, et le registre
([`JIT_Access_Ledger.csv`](JIT_Access_Ledger.csv)) marque la ligne `Expired`.

## 🔐 Sécurité & précautions

- Groupe cible jamais créé automatiquement — seule l'appartenance temporaire est gérée, pas la
  création de périmètres à privilège.
- `-DurationMinutes` et `-Reason` sont obligatoires, sans valeur par défaut : un accès à
  privilège sans limite de temps ni justification n'est pas un JIT, et n'est pas auditable.
- Le registre (`JIT_Access_Ledger.csv`) trace qui a demandé quoi, jusqu'à quand, pourquoi, et
  qui a autorisé — c'est la piste d'audit du dispositif, pas un simple journal technique.
- `Revoke-ExpiredJitAccess.ps1` ne casse jamais sur une ligne : un accès déjà retiré
  manuellement entre-temps est signalé (`ExpiredManually`) plutôt que de faire échouer le
  traitement des autres lignes du lot.
- **Fichiers `.ps1`/`.csv` en UTF-8 avec BOM** dès leur création, comme le reste du portfolio —
  Windows PowerShell 5.1 lit mal les accents sans ce marqueur en tête de fichier.
