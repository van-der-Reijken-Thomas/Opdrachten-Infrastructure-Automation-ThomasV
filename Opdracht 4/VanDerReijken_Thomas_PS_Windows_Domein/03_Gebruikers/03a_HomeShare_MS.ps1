<#
.SYNOPSIS
    Deelopdracht 3a - Home share aanmaken op de memberserver (MS) met de juiste rechten.

.DESCRIPTION
    Uitvoeren op MS (WIN00-MS) als domeinadministrator (HQ\Administrator).
    Moet uitgevoerd zijn VOOR 03b_Gebruikers.ps1 (dat script controleert of de share bestaat).

    Rechten volgens de opdracht:
      Share-rechten : Everyone             - Full Control
      NTFS-rechten  : Administrator        - Full Control (deze map, submappen en bestanden)
                      Authenticated Users  - Read, enkel "This folder only"
    Overerving op de hoofdmap wordt uitgeschakeld zodat enkel deze twee regels overblijven.
    Doordat Authenticated Users enkel op de hoofdmap leesrecht krijgt, kan een gebruiker
    wel de share openen maar niet in de homemap van een ander kijken.

.NOTES
    Auteur : Thomas van der Reijken
    Datum  : november 2026
#>
#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [string]$HomePad      = 'C:\Home',
    [string]$ShareNaam    = 'Home$',              # $ = verborgen share
    [string]$AdminAccount = 'HQ\Administrator',
    [string]$LogMap       = 'C:\Opdracht'
)

New-Item -ItemType Directory -Path $LogMap -Force | Out-Null
Start-Transcript -Path (Join-Path $LogMap ("03a_HomeShare_MS_{0:yyyyMMdd_HHmmss}.txt" -f (Get-Date))) | Out-Null

try {
    # --- 1. Map -------------------------------------------------------------
    if (Test-Path $HomePad) {
        Write-Host "[OK]  Map $HomePad bestaat al." -ForegroundColor Green
    }
    else {
        New-Item -ItemType Directory -Path $HomePad | Out-Null
        Write-Host "[DOE] Map $HomePad aangemaakt." -ForegroundColor Yellow
    }

    # --- 2. NTFS-rechten ----------------------------------------------------
    $acl = Get-Acl -Path $HomePad
    $acl.SetAccessRuleProtection($true, $false)           # overerving uit, geen kopie
    foreach ($regel in @($acl.Access)) {
        $acl.PurgeAccessRules($regel.IdentityReference)    # alle bestaande regels weg
    }

    $authUsers = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-11')  # Authenticated Users

    $regelAdmin = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $AdminAccount, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
    $regelAuth  = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $authUsers, 'Read', 'None', 'None', 'Allow')       # None/None = This folder only

    $acl.AddAccessRule($regelAdmin)
    $acl.AddAccessRule($regelAuth)
    Set-Acl -Path $HomePad -AclObject $acl
    Write-Host '[OK]  NTFS-rechten ingesteld.' -ForegroundColor Green

    # --- 3. Share -----------------------------------------------------------
    $share = Get-SmbShare -Name $ShareNaam -ErrorAction SilentlyContinue
    if ($share -and $share.Path -ne $HomePad) {
        throw "Share $ShareNaam bestaat al maar wijst naar $($share.Path)."
    }
    if (-not $share) {
        New-SmbShare -Name $ShareNaam -Path $HomePad -FullAccess 'Everyone' `
            -Description 'Homefolders gebruikers HQ' | Out-Null
        Write-Host "[DOE] Share \\$env:COMPUTERNAME\$ShareNaam aangemaakt." -ForegroundColor Yellow
    }
    else {
        # Share bestaat al: zorgen dat enkel Everyone - Full overblijft
        Get-SmbShareAccess -Name $ShareNaam |
            Where-Object { $_.AccountName -ne 'Everyone' } |
            ForEach-Object { Revoke-SmbShareAccess -Name $ShareNaam -AccountName $_.AccountName -Force | Out-Null }
        Grant-SmbShareAccess -Name $ShareNaam -AccountName 'Everyone' -AccessRight Full -Force | Out-Null
        Write-Host "[OK]  Share $ShareNaam bestond al, rechten gecontroleerd." -ForegroundColor Green
    }

    # --- 4. Controle --------------------------------------------------------
    Write-Host "`nShare-rechten:" -ForegroundColor Cyan
    Get-SmbShareAccess -Name $ShareNaam | Format-Table Name, AccountName, AccessControlType, AccessRight -AutoSize

    Write-Host 'NTFS-rechten:' -ForegroundColor Cyan
    (Get-Acl -Path $HomePad).Access |
        Format-Table IdentityReference, FileSystemRights, InheritanceFlags, PropagationFlags, IsInherited -AutoSize
}
catch {
    Write-Host "[FOUT] $($_.Exception.Message)" -ForegroundColor Red
}
finally {
    Stop-Transcript | Out-Null
}
