<#
.SYNOPSIS
    Sets up a Windows 10/11 x64 machine for signing in the old UJP e-Danoci
    system (https://etax-fl.ujp.gov.mk) with a KIBSTrust Gemalto/Thales IDPrime token.

.DESCRIPTION
    Installs, in this order:
      1. KIBSTrust SafeNet Authentication Client 10.9-R1 (x64)
      2. Gemalto IDGo 800 PKCS#11 library (x64 package, includes the 32-bit DLL)
      3. Oracle Java 8, 32-bit (latest from java.com), auto-update disabled
      4. Firefox 52.9.0 ESR, 32-bit, into C:\FF52

    Then runs Repair-EDanoci.ps1, which applies the configuration:
      - Firefox updater removed, updates and plugin blocklist locked
      - java.security patch (accept the applet's SHA-1 era signature)
      - 32-bit IDPrime PKCS#11 library copied to the path the applet hardcodes:
        C:\Program Files\Gemalto\Classic Client\BIN\gclib.dll
      - Per-user Java settings: security level HIGH, exception site, policy grant
      - Java auto-update off, Smart Card service on

    Finally creates the Firefox profile "edanoci" and a desktop shortcut, and
    registers Repair-EDanoci.ps1 as the scheduled task "e-Danoci watchdog"
    (SYSTEM, at startup and daily), so the configuration is restored if a
    driver repair or Java update undoes it.

    Safe to re-run. Already installed components are skipped, configuration is
    re-applied. Keep Repair-EDanoci.ps1 in the same folder as this script.

    Run from an elevated PowerShell, logged in as the Windows user who will file
    the returns. Per-user settings are written to the profile of the account
    running the script.

.PARAMETER EnableJavaDebug
    Turn on Java tracing, logging and the Java console for troubleshooting.

.PARAMETER Force
    Reinstall components even if they are already present.

.EXAMPLE
    Set-ExecutionPolicy -Scope Process Bypass -Force
    .\Install-EDanoci.ps1

.EXAMPLE
    .\Install-EDanoci.ps1 -EnableJavaDebug
#>
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$InstallDir  = 'C:\FF52',
    [string]$ProfileName = 'edanoci',
    [string]$EtaxUrl     = 'https://etax-fl.ujp.gov.mk',
    [string]$WorkDir     = (Join-Path $env:TEMP 'edanoci-setup'),
    [switch]$EnableJavaDebug,
    [switch]$Force
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ---------------------------------------------------------------------------
# Sources
# ---------------------------------------------------------------------------
$Src = @{
    SAC          = 'https://www.kibstrust.mk/Storage/Support/Software/KIBSTrust-SAC-x64-10.9-R1.msi'
    IDGoPkcs11   = 'https://www.kibstrust.mk/Storage/Support/Software/IDGo800_PKCS11_Library_x64.msi'
    Firefox      = @(
        'https://ftp.mozilla.org/pub/firefox/releases/52.9.0esr/win32/en-US/Firefox%20Setup%2052.9.0esr.exe',
        'https://archive.mozilla.org/pub/firefox/releases/52.9.0esr/win32/en-US/Firefox%20Setup%2052.9.0esr.exe'
    )
    JavaPage     = 'https://www.java.com/en/download/manual.jsp'
    # 8u503 "Windows Offline" (32-bit). Used only if java.com can't be parsed.
    JavaFallback = 'https://javadl.oracle.com/webapps/download/AutoDL?BundleId=253607_2fde65a2208f40a5b5f4c844b0dff092'
}

$FirefoxVersion = '52.9.0'
$RepairScript   = Join-Path $PSScriptRoot 'Repair-EDanoci.ps1'
$DataDir        = 'C:\ProgramData\EDanoci'
$TaskName       = 'e-Danoci watchdog'
$IdPrime32Candidates = @(
    'C:\Program Files (x86)\Gemalto\IDGo 800 PKCS#11\IDPrimePKCS11.dll',
    'C:\Program Files\Gemalto\IDGo 800 PKCS#11\IDPrimePKCS11.dll'
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Write-Step([string]$Text) { Write-Host "`n==> $Text" -ForegroundColor Cyan }
function Write-Info([string]$Text) { Write-Host "    $Text" }
function Write-Warn2([string]$Text) { Write-Host "    ! $Text" -ForegroundColor Yellow }

function Get-InstalledApp([string]$NamePattern) {
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    Get-ItemProperty -Path $keys -ErrorAction SilentlyContinue |
        Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -like $NamePattern }
}

function Assert-Signature([string]$Path) {
    $sig = Get-AuthenticodeSignature -LiteralPath $Path
    if ($sig.Status -ne 'Valid') {
        Remove-Item -LiteralPath $Path -Force
        throw "Signature status for $(Split-Path $Path -Leaf) is '$($sig.Status)'. The file was deleted. Check the source."
    }
    Write-Info "Signature OK: $($sig.SignerCertificate.Subject)"
}

function Get-File([string[]]$Urls, [string]$FileName) {
    $dest = Join-Path $WorkDir $FileName
    if ((Test-Path -LiteralPath $dest) -and -not $Force) {
        Write-Info "Using cached $FileName"
        Assert-Signature $dest
        return $dest
    }
    foreach ($u in $Urls) {
        try {
            Write-Info "Downloading $u"
            Invoke-WebRequest -Uri $u -OutFile $dest -UseBasicParsing
        } catch {
            Write-Warn2 "Download failed: $($_.Exception.Message)"
            continue
        }
        Assert-Signature $dest
        return $dest
    }
    throw "Could not download $FileName"
}

function Install-Msi([string]$Path, [string]$Name) {
    $log  = Join-Path $WorkDir ("{0}.msi.log" -f $Name)
    $msiArgs = @('/i', "`"$Path`"", '/qn', '/norestart', '/l*v', "`"$log`"")
    $p = Start-Process msiexec.exe -ArgumentList $msiArgs -Wait -PassThru
    switch ($p.ExitCode) {
        0       { Write-Info "${Name} installed" }
        3010    { Write-Info "${Name} installed (reboot required)"; $script:RebootNeeded = $true }
        1638    { Write-Info "${Name}: another version is already installed, skipped" }
        default { throw "${Name} install failed with exit code $($p.ExitCode). See $log" }
    }
}

function Get-Jre32Dirs {
    @(Get-ChildItem -Path 'C:\Program Files (x86)\Java' -Directory -Filter 'jre*1.8*' -ErrorAction SilentlyContinue |
        ForEach-Object { $_.FullName })
}

function Stop-SigningProcesses {
    Get-Process jp2launcher -ErrorAction SilentlyContinue | Stop-Process -Force
    Get-Process firefox -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -and $_.Path -like "$InstallDir\*" } | Stop-Process -Force
}

# ---------------------------------------------------------------------------
# Start
# ---------------------------------------------------------------------------
if (-not [Environment]::Is64BitOperatingSystem) { throw 'This script targets 64-bit Windows.' }
if (-not (Test-Path -LiteralPath $RepairScript)) { throw "Repair-EDanoci.ps1 not found next to this script ($PSScriptRoot)." }
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
Start-Transcript -Path (Join-Path $WorkDir 'install.log') -Append | Out-Null
$script:RebootNeeded = $false

try {
    Write-Host "e-Danoci setup. Per-user settings go to: $env:USERPROFILE" -ForegroundColor Green
    Stop-SigningProcesses

    # 1. SafeNet Authentication Client ------------------------------------
    Write-Step 'SafeNet Authentication Client (KIBSTrust 10.9-R1, x64)'
    if ((Get-InstalledApp '*SafeNet Authentication Client*') -and -not $Force) {
        Write-Info 'Already installed'
    } else {
        Install-Msi (Get-File @($Src.SAC) 'KIBSTrust-SAC-x64-10.9-R1.msi') 'SAC'
    }

    # 2. IDGo 800 PKCS#11 library -----------------------------------------
    Write-Step 'Gemalto IDGo 800 PKCS#11 library'
    $haveIdPrime32 = $IdPrime32Candidates | Where-Object { Test-Path -LiteralPath $_ }
    if ($haveIdPrime32 -and -not $Force) {
        Write-Info 'Already installed'
    } else {
        Install-Msi (Get-File @($Src.IDGoPkcs11) 'IDGo800_PKCS11_Library_x64.msi') 'IDGoPKCS11'
    }

    # 3. Java 8, 32-bit ---------------------------------------------------
    Write-Step 'Oracle Java 8 (32-bit)'
    if (@(Get-Jre32Dirs).Count -gt 0 -and -not $Force) {
        Write-Info "Already installed: $((Get-Jre32Dirs) -join ', ')"
    } else {
        $javaUrl = $Src.JavaFallback
        try {
            $html = (Invoke-WebRequest -Uri $Src.JavaPage -UseBasicParsing).Content
            $m = [regex]::Match($html, '<a[^>]*href="([^"]+)"[^>]*title="Download Java software for Windows Offline"')
            if (-not $m.Success) {
                $m = [regex]::Match($html, '<a[^>]*title="Download Java software for Windows Offline"[^>]*href="([^"]+)"')
            }
            if ($m.Success) { $javaUrl = [Net.WebUtility]::HtmlDecode($m.Groups[1].Value) }
            else { Write-Warn2 'Could not parse java.com, using pinned 8u503 link' }
        } catch {
            Write-Warn2 "java.com unreachable, using pinned 8u503 link: $($_.Exception.Message)"
        }
        $jre = Get-File @($javaUrl) 'jre8-windows-i586.exe'
        # Auto-update off: an update installs a new JRE with an unpatched java.security
        $jargs = @('/s', 'INSTALL_SILENT=Enable', 'AUTO_UPDATE=Disable', 'WEB_JAVA=Enable',
                   'WEB_JAVA_SECURITY_LEVEL=H', 'SPONSORS=Disable', 'REBOOT=Disable')
        $p = Start-Process -FilePath $jre -ArgumentList $jargs -Wait -PassThru
        if ($p.ExitCode -ne 0) { throw "Java installer exited with $($p.ExitCode)" }
        if (@(Get-Jre32Dirs).Count -eq 0) {
            throw 'Java installed, but no 32-bit JRE was found in C:\Program Files (x86)\Java. The download may have been the 64-bit build.'
        }
        Write-Info "Installed: $((Get-Jre32Dirs) -join ', ')"
    }

    # 4. Firefox 52.9.0 ESR ------------------------------------------------
    Write-Step "Firefox $FirefoxVersion ESR (32-bit) into $InstallDir"
    $ffExe = Join-Path $InstallDir 'firefox.exe'
    $appIni = Join-Path $InstallDir 'application.ini'
    $ffOk = (Test-Path -LiteralPath $appIni) -and
            ((Get-Content -LiteralPath $appIni) -contains "Version=$FirefoxVersion")
    if ($ffOk -and -not $Force) {
        Write-Info 'Already installed'
    } else {
        if (Test-Path -LiteralPath $InstallDir) {
            Write-Warn2 "Removing existing $InstallDir (wrong version or -Force)"
            Remove-Item -LiteralPath $InstallDir -Recurse -Force
        }
        $ffSetup = Get-File $Src.Firefox 'Firefox-Setup-52.9.0esr.exe'
        $ini = Join-Path $WorkDir 'firefox-install.ini'
        @(
            '[Install]'
            "InstallDirectoryPath=$InstallDir"
            'QuickLaunchShortcut=false'
            'DesktopShortcut=false'
            'StartMenuShortcuts=false'
            'TaskbarShortcut=false'
            'MaintenanceService=false'
        ) | Set-Content -LiteralPath $ini -Encoding ASCII
        $p = Start-Process -FilePath $ffSetup -ArgumentList "/INI=`"$ini`"" -Wait -PassThru
        if ($p.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $ffExe)) {
            throw "Firefox install failed (exit $($p.ExitCode))"
        }
        Write-Info 'Installed'
    }

    # 5. Configuration, before Firefox ever runs -----------------------------
    Write-Step 'Configuration (Repair-EDanoci.ps1)'
    $repairArgs = @{
        InstallDir      = $InstallDir
        EtaxUrl         = $EtaxUrl
        UserProfile     = $env:USERPROFILE
        EnableJavaDebug = $EnableJavaDebug
    }
    $applied = @(& $RepairScript @repairArgs)
    $applied | Format-Table -AutoSize | Out-String | Write-Host

    # 6. Firefox profile and shortcut ----------------------------------------
    Write-Step "Firefox profile '$ProfileName'"
    $profilesIni = Join-Path $env:APPDATA 'Mozilla\Firefox\profiles.ini'
    $hasProfile = (Test-Path -LiteralPath $profilesIni) -and
                  ((Get-Content -LiteralPath $profilesIni) -contains "Name=$ProfileName")
    if ($hasProfile) {
        Write-Info 'Already exists'
    } else {
        Start-Process -FilePath $ffExe -ArgumentList @('-CreateProfile', $ProfileName) -Wait
        Write-Info 'Created'
    }

    Write-Step 'Desktop shortcut'
    $lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'e-Danoci (Firefox 52).lnk'
    $ws = New-Object -ComObject WScript.Shell
    $sc = $ws.CreateShortcut($lnk)
    $sc.TargetPath = $ffExe
    $sc.Arguments = "-no-remote -P $ProfileName $EtaxUrl"
    $sc.WorkingDirectory = $InstallDir
    $sc.IconLocation = "$ffExe,0"
    $sc.Description = 'UJP e-Danoci (Firefox 52 ESR + Java)'
    $sc.Save()
    Write-Info $lnk

    # 7. Watchdog -------------------------------------------------------------
    Write-Step "Scheduled task '$TaskName'"
    New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
    # The task runs as SYSTEM, so only SYSTEM and Administrators may change the script
    & icacls.exe $DataDir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls failed on $DataDir" }
    $taskScript = Join-Path $DataDir 'Repair-EDanoci.ps1'
    Copy-Item -LiteralPath $RepairScript -Destination $taskScript -Force
    $taskArgs = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -InstallDir "{1}" -EtaxUrl "{2}" -UserProfile "{3}"' -f
        $taskScript, $InstallDir, $EtaxUrl, $env:USERPROFILE
    $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $taskArgs
    $triggers  = @(
        (New-ScheduledTaskTrigger -AtStartup),
        (New-ScheduledTaskTrigger -Daily -At '07:30')
    )
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                    -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $triggers -Principal $principal -Settings $settings `
        -Description "Restores the UJP e-Danoci signing setup. Log: $DataDir\repair.log" -Force | Out-Null
    Write-Info "Registered: at startup and daily 07:30, as SYSTEM, for $env:USERPROFILE"

    # Verification ----------------------------------------------------------
    Write-Step 'Verification'
    $checks = New-Object System.Collections.Generic.List[object]
    foreach ($r in @(& $RepairScript @repairArgs -CheckOnly)) { $checks.Add($r) }
    $checks.Add([pscustomobject]@{
        Check  = 'Desktop shortcut'
        Status = $(if (Test-Path -LiteralPath $lnk) { 'OK' } else { 'FAILED' })
        Detail = Split-Path $lnk -Leaf
    })
    $checks.Add([pscustomobject]@{
        Check  = 'Watchdog task'
        Status = $(if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) { 'OK' } else { 'FAILED' })
        Detail = $TaskName
    })
    $checks | Format-Table -AutoSize | Out-String | Write-Host

    if ($checks | Where-Object { $_.Status -ne 'OK' }) {
        Write-Host 'Some checks failed. See the table above and the runbook.' -ForegroundColor Red
    } else {
        Write-Host 'All checks passed.' -ForegroundColor Green
    }
    if ($script:RebootNeeded) { Write-Host 'Reboot required before first use (driver install).' -ForegroundColor Yellow }
    Write-Host @"

Next:
  1. Plug in the token.
  2. Open the 'e-Danoci (Firefox 52)' shortcut on the desktop.
  3. On first use, accept the Java security prompt for the UJP applet.
"@
}
finally {
    Stop-Transcript | Out-Null
}
