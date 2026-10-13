<#
.SYNOPSIS
    Sets up a Windows 10/11 x64 machine for signing in the old UJP e-Danoci
    system (https://etax-fl.ujp.gov.mk) with a KIBSTrust Gemalto/Thales IDPrime token.

.DESCRIPTION
    Installs and configures, in this order:
      1. KIBSTrust SafeNet Authentication Client 10.9-R1 (x64)
      2. Gemalto IDGo 800 PKCS#11 library (x64 package, includes the 32-bit DLL)
      3. Oracle Java 8, 32-bit (latest from java.com)
      4. Firefox 52.9.0 ESR, 32-bit, into C:\FF52, with updates removed and locked
      5. java.security patch (accept the applet's SHA-1 era signature)
      6. 32-bit IDPrime PKCS#11 library copied to the path the applet hardcodes:
         C:\Program Files\Gemalto\Classic Client\BIN\gclib.dll
      7. Per-user Java settings: security level HIGH, exception site, policy grant
      8. Smart Card service, Firefox profile "edanoci", desktop shortcut

    Safe to re-run. Already installed components are skipped, configuration is
    re-applied. Re-run it after every Java update, because each Java update
    installs into a new folder with a fresh, unpatched java.security.

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
$GemaltoBin     = 'C:\Program Files\Gemalto\Classic Client\BIN'   # hardcoded in UJP Signer.jar
$JavaDeployDir  = Join-Path $env:USERPROFILE 'AppData\LocalLow\Sun\Java\Deployment'
$PatchMarker    = '# e-Danoci: patched by Install-EDanoci.ps1'
$JavaSecurityProps = [ordered]@{
    'jdk.jar.disabledAlgorithms'      = 'MD2'
    'jdk.certpath.disabledAlgorithms' = 'MD2, RSA keySize < 1024, DSA keySize < 1024'
}
$IdPrimeCandidates = @(
    'C:\Program Files (x86)\Gemalto\IDGo 800 PKCS#11\IDPrimePKCS11.dll',
    'C:\Program Files\Gemalto\IDGo 800 PKCS#11\IDPrimePKCS11.dll',
    'C:\Program Files\SafeNet\Authentication\SAC\x32\IDPrimePKCS11.dll'
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

function Get-PEArch([string]$Path) {
    $fs = [IO.File]::OpenRead($Path)
    try {
        $br = New-Object IO.BinaryReader($fs)
        [void]$fs.Seek(0x3C, 'Begin')
        $peOffset = $br.ReadInt32()
        [void]$fs.Seek($peOffset + 4, 'Begin')
        switch ($br.ReadUInt16()) {
            0x014C  { 'x86' }
            0x8664  { 'x64' }
            0xAA64  { 'arm64' }
            default { 'unknown' }
        }
    } finally { $fs.Dispose() }
}

function Get-File([string[]]$Urls, [string]$FileName) {
    $dest = Join-Path $WorkDir $FileName
    if ((Test-Path -LiteralPath $dest) -and -not $Force) {
        Write-Info "Using cached $FileName"
        return $dest
    }
    foreach ($u in $Urls) {
        try {
            Write-Info "Downloading $u"
            Invoke-WebRequest -Uri $u -OutFile $dest -UseBasicParsing
            $sig = Get-AuthenticodeSignature -LiteralPath $dest
            if ($sig.Status -eq 'Valid') {
                Write-Info "Signature OK: $($sig.SignerCertificate.Subject)"
            } else {
                Write-Warn2 "Signature status for $FileName is '$($sig.Status)'. Check the source if this is unexpected."
            }
            return $dest
        } catch {
            Write-Warn2 "Download failed: $($_.Exception.Message)"
        }
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

function Get-Jre32Homes {
    $root = 'C:\Program Files (x86)\Java'
    if (-not (Test-Path -LiteralPath $root)) { return @() }
    @(Get-ChildItem -LiteralPath $root -Directory |
        Where-Object { $_.Name -like 'jre1.8.0_*' -or $_.Name -like 'jre-1.8*' } |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'lib\security\java.security') } |
        Sort-Object Name | ForEach-Object { $_.FullName })
}

function Get-JavaSecurityActiveValue([string[]]$Lines, [string]$Key) {
    $rx = '^\s*' + [regex]::Escape($Key) + '\s*='
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match $rx) {
            $block = $Lines[$i]
            while ($Lines[$i].TrimEnd().EndsWith('\') -and ($i + 1) -lt $Lines.Count) {
                $i++
                $block = $block.TrimEnd().TrimEnd('\') + ' ' + $Lines[$i]
            }
            return (($block -replace $rx, '') -replace '\s+', ' ').Trim()
        }
    }
    return $null
}

function Update-JavaSecurityLines([string[]]$Lines, [string]$Key, [string]$Value) {
    $rx  = '^\s*' + [regex]::Escape($Key) + '\s*='
    $out = New-Object System.Collections.Generic.List[string]
    $done = $false
    $i = 0
    while ($i -lt $Lines.Count) {
        $line = $Lines[$i]
        if ($line -match $rx) {
            $out.Add('#' + $line)
            while ($line.TrimEnd().EndsWith('\') -and ($i + 1) -lt $Lines.Count) {
                $i++
                $line = $Lines[$i]
                $out.Add('#' + $line)
            }
            if (-not $done) {
                $out.Add($PatchMarker)
                $out.Add("$Key=$Value")
                $done = $true
            }
        } else {
            $out.Add($line)
        }
        $i++
    }
    if (-not $done) {
        $out.Add('')
        $out.Add($PatchMarker)
        $out.Add("$Key=$Value")
    }
    return ,$out.ToArray()
}

function Set-JavaSecurity([string]$JreHome) {
    $file = Join-Path $JreHome 'lib\security\java.security'
    $enc  = [Text.Encoding]::GetEncoding(28591)   # java.security is ISO-8859-1
    $lines = [IO.File]::ReadAllLines($file, $enc)
    $changed = $false
    foreach ($key in $JavaSecurityProps.Keys) {
        $want = $JavaSecurityProps[$key]
        $have = Get-JavaSecurityActiveValue $lines $key
        if ($have -ne $want) {
            $lines = Update-JavaSecurityLines $lines $key $want
            $changed = $true
        }
    }
    if ($changed) {
        $backup = "$file.orig"
        if (-not (Test-Path -LiteralPath $backup)) { Copy-Item -LiteralPath $file -Destination $backup }
        [IO.File]::WriteAllLines($file, $lines, $enc)
        Write-Info "Patched $file (original kept as java.security.orig)"
    } else {
        Write-Info "Already patched: $file"
    }
}

function Set-PropertiesFile([string]$Path, [System.Collections.IDictionary]$Pairs) {
    $lines = @()
    if (Test-Path -LiteralPath $Path) { $lines = @(Get-Content -LiteralPath $Path) }
    foreach ($k in $Pairs.Keys) {
        $rx = '^' + [regex]::Escape($k) + '='
        $lines = @($lines | Where-Object { $_ -notmatch $rx })
        $lines += "$k=$($Pairs[$k])"
    }
    New-Item -ItemType Directory -Force -Path (Split-Path $Path) | Out-Null
    Set-Content -LiteralPath $Path -Value $lines -Encoding ASCII
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
    $haveIdPrime32 = $IdPrimeCandidates[0..1] | Where-Object { Test-Path -LiteralPath $_ }
    if ($haveIdPrime32 -and -not $Force) {
        Write-Info 'Already installed'
    } else {
        Install-Msi (Get-File @($Src.IDGoPkcs11) 'IDGo800_PKCS11_Library_x64.msi') 'IDGoPKCS11'
    }

    # 3. Java 8, 32-bit ---------------------------------------------------
    Write-Step 'Oracle Java 8 (32-bit)'
    if (@(Get-Jre32Homes).Count -gt 0 -and -not $Force) {
        Write-Info "Already installed: $((Get-Jre32Homes) -join ', ')"
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
        $jargs = @('/s', 'INSTALL_SILENT=Enable', 'AUTO_UPDATE=Enable', 'WEB_JAVA=Enable',
                   'WEB_JAVA_SECURITY_LEVEL=H', 'SPONSORS=Disable', 'REBOOT=Disable')
        $p = Start-Process -FilePath $jre -ArgumentList $jargs -Wait -PassThru
        if ($p.ExitCode -ne 0) { throw "Java installer exited with $($p.ExitCode)" }
        if (@(Get-Jre32Homes).Count -eq 0) {
            throw 'Java installed, but no 32-bit JRE was found in C:\Program Files (x86)\Java. The download may have been the 64-bit build.'
        }
        Write-Info "Installed: $((Get-Jre32Homes) -join ', ')"
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

    # Lock Firefox before it ever runs
    Write-Step 'Locking Firefox updates (AutoConfig)'
    foreach ($f in @('updater.exe', 'updater.ini', 'maintenanceservice.exe', 'maintenanceservice_installer.exe')) {
        $fp = Join-Path $InstallDir $f
        if (Test-Path -LiteralPath $fp) { Remove-Item -LiteralPath $fp -Force; Write-Info "Removed $f" }
    }
    New-Item -ItemType Directory -Force -Path (Join-Path $InstallDir 'defaults\pref') | Out-Null
    @(
        'pref("general.config.filename", "mozilla.cfg");'
        'pref("general.config.obscure_value", 0);'
    ) | Set-Content -LiteralPath (Join-Path $InstallDir 'defaults\pref\autoconfig.js') -Encoding ASCII
    @(
        '// e-Danoci lockdown. Firefox skips this first line, keep it a comment.'
        'lockPref("app.update.enabled", false);'
        'lockPref("app.update.auto", false);'
        'lockPref("app.update.service.enabled", false);'
        'lockPref("app.update.url", "");'
        'lockPref("app.update.url.override", "");'
        'lockPref("security.enterprise_roots.enabled", true);'
        'lockPref("plugin.load_flash_only", false);'
        'lockPref("browser.shell.checkDefaultBrowser", false);'
        'lockPref("extensions.update.enabled", false);'
        'lockPref("datareporting.healthreport.uploadEnabled", false);'
        'lockPref("datareporting.policy.dataSubmissionEnabled", false);'
        'lockPref("toolkit.telemetry.enabled", false);'
        "pref(`"browser.startup.homepage`", `"$EtaxUrl`");"
    ) | Set-Content -LiteralPath (Join-Path $InstallDir 'mozilla.cfg') -Encoding ASCII
    Write-Info 'autoconfig.js and mozilla.cfg written'

    # 5. java.security ------------------------------------------------------
    Write-Step 'Patching java.security in every 32-bit Java 8'
    foreach ($jh in Get-Jre32Homes) { Set-JavaSecurity $jh }

    # 6. PKCS#11 library at the path Signer.jar expects ------------------------
    Write-Step "Placing 32-bit IDPrime PKCS#11 library as $GemaltoBin\gclib.dll"
    $idPrime = $IdPrimeCandidates |
        Where-Object { (Test-Path -LiteralPath $_) -and (Get-PEArch $_) -eq 'x86' } |
        Select-Object -First 1
    if (-not $idPrime) { throw 'No 32-bit IDPrimePKCS11.dll found. Check the SAC and IDGo 800 PKCS#11 installs.' }
    Write-Info "Source: $idPrime"
    New-Item -ItemType Directory -Force -Path $GemaltoBin | Out-Null
    $gclib = Join-Path $GemaltoBin 'gclib.dll'
    $srcHash = (Get-FileHash -LiteralPath $idPrime).Hash
    if ((Test-Path -LiteralPath $gclib) -and (Get-FileHash -LiteralPath $gclib).Hash -eq $srcHash) {
        Write-Info 'Already in place'
    } else {
        if (Test-Path -LiteralPath $gclib) {
            $bak = Join-Path $GemaltoBin ('gclib.dll.bak-{0:yyyyMMdd-HHmmss}' -f (Get-Date))
            Move-Item -LiteralPath $gclib -Destination $bak
            Write-Info "Previous gclib.dll moved to $(Split-Path $bak -Leaf)"
        }
        Copy-Item -LiteralPath $idPrime -Destination $gclib
        Write-Info 'Copied'
    }

    # 7. Per-user Java settings --------------------------------------------
    Write-Step "Java settings for $env:USERNAME"
    $props = [ordered]@{
        'deployment.security.level' = 'HIGH'
        'deployment.webjava.enabled' = 'true'
    }
    if ($EnableJavaDebug) {
        $props['deployment.trace'] = 'true'
        $props['deployment.log'] = 'true'
        $props['deployment.console.startup.mode'] = 'SHOW'
    }
    Set-PropertiesFile (Join-Path $JavaDeployDir 'deployment.properties') $props
    Write-Info 'deployment.properties updated'

    $sites = Join-Path $JavaDeployDir 'security\exception.sites'
    New-Item -ItemType Directory -Force -Path (Split-Path $sites) | Out-Null
    $existing = @()
    if (Test-Path -LiteralPath $sites) { $existing = @(Get-Content -LiteralPath $sites) }
    if ($existing -notcontains $EtaxUrl) {
        Add-Content -LiteralPath $sites -Value $EtaxUrl -Encoding ASCII
        Write-Info "Added $EtaxUrl to exception site list"
    } else {
        Write-Info 'Exception site already listed'
    }

    $policy = @(
        "grant codeBase `"$EtaxUrl/-`" {"
        '    permission java.security.AllPermission;'
        '};'
    )
    foreach ($pf in @((Join-Path $env:USERPROFILE '.java.policy'), (Join-Path $JavaDeployDir 'security\java.policy'))) {
        Set-Content -LiteralPath $pf -Value $policy -Encoding ASCII
    }
    Write-Info 'Policy grant written'

    $cache = Join-Path $JavaDeployDir 'cache'
    if (Test-Path -LiteralPath $cache) {
        Remove-Item -LiteralPath $cache -Recurse -Force -ErrorAction SilentlyContinue
        Write-Info 'Java cache cleared'
    }

    # 8. Smart card service, profile, shortcut --------------------------------
    Write-Step 'Smart Card service'
    Set-Service -Name SCardSvr -StartupType Automatic
    Start-Service -Name SCardSvr -ErrorAction SilentlyContinue
    Write-Info "SCardSvr: $((Get-Service SCardSvr).Status)"

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

    # Verification ----------------------------------------------------------
    Write-Step 'Verification'
    $checks = New-Object System.Collections.Generic.List[object]
    function Add-Check($Name, [bool]$Ok, $Detail) {
        $checks.Add([pscustomobject]@{ Check = $Name; OK = $(if ($Ok) { 'yes' } else { 'NO' }); Detail = $Detail })
    }
    $ffVer = if (Test-Path -LiteralPath $appIni) { ((Get-Content -LiteralPath $appIni) | Where-Object { $_ -like 'Version=*' } | Select-Object -First 1) } else { 'missing' }
    Add-Check 'Firefox 52.9.0 ESR'    ($ffVer -eq "Version=$FirefoxVersion") $ffVer
    Add-Check 'Firefox updater removed' (-not (Test-Path -LiteralPath (Join-Path $InstallDir 'updater.exe'))) $InstallDir
    Add-Check 'Updates locked (mozilla.cfg)' ((Select-String -LiteralPath (Join-Path $InstallDir 'mozilla.cfg') -SimpleMatch 'lockPref("app.update.enabled", false)' -Quiet)) 'mozilla.cfg'
    $jres = @(Get-Jre32Homes)
    Add-Check 'Java 8 32-bit' ($jres.Count -gt 0) ($jres -join ', ')
    foreach ($jh in $jres) {
        $l = [IO.File]::ReadAllLines((Join-Path $jh 'lib\security\java.security'), [Text.Encoding]::GetEncoding(28591))
        $ok = $true
        foreach ($k in $JavaSecurityProps.Keys) { if ((Get-JavaSecurityActiveValue $l $k) -ne $JavaSecurityProps[$k]) { $ok = $false } }
        Add-Check "java.security patched" $ok (Split-Path $jh -Leaf)
    }
    $gArch = if (Test-Path -LiteralPath $gclib) { Get-PEArch $gclib } else { 'missing' }
    Add-Check 'gclib.dll is 32-bit IDPrime' ($gArch -eq 'x86') $gArch
    Add-Check 'SafeNet 32-bit PKCS#11' (Test-Path -LiteralPath 'C:\Windows\SysWOW64\eTPKCS11.dll') 'SysWOW64\eTPKCS11.dll'
    Add-Check 'Smart Card service running' ((Get-Service SCardSvr).Status -eq 'Running') ''
    Add-Check 'Exception site listed' ((Get-Content -LiteralPath $sites) -contains $EtaxUrl) $EtaxUrl
    Add-Check 'Desktop shortcut' (Test-Path -LiteralPath $lnk) (Split-Path $lnk -Leaf)
    $checks | Format-Table -AutoSize | Out-String | Write-Host

    if ($checks | Where-Object { $_.OK -eq 'NO' }) {
        Write-Host 'Some checks failed. See the table above and the runbook.' -ForegroundColor Red
    } else {
        Write-Host 'All checks passed.' -ForegroundColor Green
    }
    if ($script:RebootNeeded) { Write-Host 'Reboot required before first use (driver install).' -ForegroundColor Yellow }
    Write-Host @"

Next:
  1. Plug in the token.
  2. Open the 'e-Danoci (Firefox 52)' shortcut on the desktop.
  3. On first use, allow the Java plugin for the site ('Allow and Remember')
     and accept the Java security prompt for the UJP applet.
"@
}
finally {
    Stop-Transcript | Out-Null
}
