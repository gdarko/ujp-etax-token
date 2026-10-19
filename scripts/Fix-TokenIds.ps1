<#
.SYNOPSIS
    Fixes "Потписот не е ваш" on KIBSTrust tokens whose CA certificates share
    the private key's label and ID.

.DESCRIPTION
    New KIBSTrust tokens store Root CA G2, Qseal CA G3 and Qsig CA G3 with the
    same CKA_LABEL / CKA_ID as the user's key. The e-Danoci applet then signs
    with the key but attaches a CA certificate, and UJP rejects the signature.

    Fix-TokenIds.js (run with the 32-bit Java's jjs.exe) gives the CA
    certificates their own label and ID. Nothing is deleted, and the user's
    certificate and key are never modified. A backup is written to
    %USERPROFILE%\Documents\KIBSTrust-token-fix\backup before any change.

    Run in an ordinary PowerShell window (no admin needed). The PIN is typed in
    that window and never shown.

.PARAMETER Mode
    check  list the token and the planned change. No PIN, no changes.
    apply  back up, then relabel the CA certificates. Asks for YES and the PIN.
    undo   restore the original labels and IDs from the backup.

.EXAMPLE
    .\Fix-TokenIds.ps1 check
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('check', 'apply', 'undo')]
    [string]$Mode = 'check'
)

$ErrorActionPreference = 'Stop'

$jjs = Get-ChildItem -Path 'C:\Program Files (x86)\Java\jre*1.8*\bin\jjs.exe' -ErrorAction SilentlyContinue |
    Sort-Object { $_.VersionInfo.FileVersionRaw } | Select-Object -Last 1
if (-not $jjs) { throw 'No 32-bit Java 8 found (jjs.exe in C:\Program Files (x86)\Java). Run Install-EDanoci.ps1 first.' }

Get-Process jp2launcher -ErrorAction SilentlyContinue | ForEach-Object {
    Write-Warning 'The e-Danoci applet is running. Close Firefox 52 before apply/undo.'
}

& $jjs.FullName (Join-Path $PSScriptRoot 'Fix-TokenIds.js') -- $Mode
exit $LASTEXITCODE
