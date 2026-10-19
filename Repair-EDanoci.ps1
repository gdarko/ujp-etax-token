<#
.SYNOPSIS
    Checks and repairs the e-Danoci signing setup made by Install-EDanoci.ps1.

.DESCRIPTION
    Re-applies the configuration that a SafeNet/Gemalto repair, a Java update
    or Firefox can silently undo:
      - 32-bit IDPrime PKCS#11 library as ...\Classic Client\BIN\gclib.dll
      - java.security patch in every 32-bit Java 8
      - Firefox 52 updater removed, updates and plugin blocklist locked
      - Java auto-update disabled
      - Smart Card service set to Automatic
      - Per-user Java settings, exception site and policy grant (-UserProfile)

    Install-EDanoci.ps1 runs it during setup and registers it as the scheduled
    task "e-Danoci watchdog" (SYSTEM, at startup and daily). Every run is
    logged to C:\ProgramData\EDanoci\repair.log.

    Exit code: 0 all OK, 1 something was repaired, 2 a check failed.

.PARAMETER UserProfile
    Profile folder of the Windows user who files the returns, for the per-user
    Java settings. Defaults to the current user's profile.

.PARAMETER CheckOnly
    Report only, change nothing.

.EXAMPLE
    .\Repair-EDanoci.ps1 -CheckOnly
#>
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$InstallDir  = 'C:\FF52',
    [string]$EtaxUrl     = 'https://etax-fl.ujp.gov.mk',
    [string]$UserProfile = $env:USERPROFILE,
    [switch]$CheckOnly,
    [switch]$EnableJavaDebug
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$FirefoxVersion = '52.9.0'
$GemaltoBin     = 'C:\Program Files\Gemalto\Classic Client\BIN'   # hardcoded in UJP Signer.jar
$LogFile        = 'C:\ProgramData\EDanoci\repair.log'
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
$FirefoxUpdaterFiles = @('updater.exe', 'updater.ini', 'maintenanceservice.exe', 'maintenanceservice_installer.exe')
$AutoconfigJs = @(
    'pref("general.config.filename", "mozilla.cfg");'
    'pref("general.config.obscure_value", 0);'
)
$MozillaCfg = @(
    '// e-Danoci lockdown. Firefox skips this first line, keep it a comment.'
    'lockPref("app.update.enabled", false);'
    'lockPref("app.update.auto", false);'
    'lockPref("app.update.service.enabled", false);'
    'lockPref("app.update.url", "");'
    'lockPref("app.update.url.override", "");'
    'lockPref("extensions.blocklist.enabled", false);'
    'lockPref("plugin.state.java", 2);'
    'lockPref("security.enterprise_roots.enabled", true);'
    'lockPref("plugin.load_flash_only", false);'
    'lockPref("browser.shell.checkDefaultBrowser", false);'
    'lockPref("extensions.update.enabled", false);'
    'lockPref("datareporting.healthreport.uploadEnabled", false);'
    'lockPref("datareporting.policy.dataSubmissionEnabled", false);'
    'lockPref("toolkit.telemetry.enabled", false);'
    "pref(`"browser.startup.homepage`", `"$EtaxUrl`");"
)
$JavaUpdatePolicy = 'HKLM:\SOFTWARE\WOW6432Node\JavaSoft\Java Update\Policy'
$JavaUpdateRunKey = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
$Results = New-Object System.Collections.Generic.List[object]
$script:Repaired = $false

function Add-Result([string]$Check, [string]$Status, [string]$Detail) {
    $Results.Add([pscustomobject]@{ Check = $Check; Status = $Status; Detail = $Detail })
}

# Runs $Test; if it fails and this is not -CheckOnly, runs $Repair and tests again.
function Test-AndRepair([string]$Check, [scriptblock]$Test, [scriptblock]$Repair, [string]$Detail = '') {
    try {
        if (& $Test) { Add-Result $Check 'OK' $Detail; return }
        if ($CheckOnly) { Add-Result $Check 'NEEDS REPAIR' $Detail; return }
        & $Repair
        if (& $Test) { Add-Result $Check 'REPAIRED' $Detail; $script:Repaired = $true }
        else { Add-Result $Check 'FAILED' "Still wrong after repair. $Detail" }
    } catch {
        Add-Result $Check 'FAILED' $_.Exception.Message
    }
}

function Get-RegValue([string]$Path, [string]$Name) {
    try { (Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop).$Name } catch { $null }
}

function Test-FileContent([string]$Path, [string[]]$Expected) {
    (Test-Path -LiteralPath $Path) -and
        ((@(Get-Content -LiteralPath $Path) -join "`n") -eq ($Expected -join "`n"))
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

$Latin1 = [Text.Encoding]::GetEncoding(28591)   # java.security is ISO-8859-1

function Test-JavaSecurity([string]$JreHome) {
    $lines = [IO.File]::ReadAllLines((Join-Path $JreHome 'lib\security\java.security'), $Latin1)
    foreach ($key in $JavaSecurityProps.Keys) {
        if ((Get-JavaSecurityActiveValue $lines $key) -ne $JavaSecurityProps[$key]) { return $false }
    }
    return $true
}

function Set-JavaSecurity([string]$JreHome) {
    $file  = Join-Path $JreHome 'lib\security\java.security'
    $lines = [IO.File]::ReadAllLines($file, $Latin1)
    foreach ($key in $JavaSecurityProps.Keys) {
        if ((Get-JavaSecurityActiveValue $lines $key) -ne $JavaSecurityProps[$key]) {
            $lines = Update-JavaSecurityLines $lines $key $JavaSecurityProps[$key]
        }
    }
    $backup = "$file.orig"
    if (-not (Test-Path -LiteralPath $backup)) { Copy-Item -LiteralPath $file -Destination $backup }
    [IO.File]::WriteAllLines($file, $lines, $Latin1)
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

# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------

# PKCS#11 library at the path Signer.jar expects
$gclib   = Join-Path $GemaltoBin 'gclib.dll'
$idPrime = $IdPrimeCandidates |
    Where-Object { (Test-Path -LiteralPath $_) -and (Get-PEArch $_) -eq 'x86' } |
    Select-Object -First 1
if (-not $idPrime) {
    Add-Result 'gclib.dll is 32-bit IDPrime' 'FAILED' 'No 32-bit IDPrimePKCS11.dll found. Reinstall SAC and IDGo 800 PKCS#11.'
} else {
    Test-AndRepair 'gclib.dll is 32-bit IDPrime' {
        (Test-Path -LiteralPath $gclib) -and
            (Get-FileHash -LiteralPath $gclib).Hash -eq (Get-FileHash -LiteralPath $idPrime).Hash
    } {
        New-Item -ItemType Directory -Force -Path $GemaltoBin | Out-Null
        if (Test-Path -LiteralPath $gclib) {
            $bak = Join-Path $GemaltoBin ('gclib.dll.bak-{0:yyyyMMdd-HHmmss}' -f (Get-Date))
            Move-Item -LiteralPath $gclib -Destination $bak
        }
        Copy-Item -LiteralPath $idPrime -Destination $gclib
    } $idPrime
}

# java.security in every 32-bit Java 8
$jres = @(Get-Jre32Homes)
if ($jres.Count -eq 0) {
    Add-Result 'java.security patched' 'FAILED' 'No 32-bit Java 8 found in C:\Program Files (x86)\Java.'
}
foreach ($jh in $jres) {
    Test-AndRepair 'java.security patched' { Test-JavaSecurity $jh } { Set-JavaSecurity $jh } (Split-Path $jh -Leaf)
}

# Java auto-update off
Test-AndRepair 'Java auto-update disabled' {
    (Get-RegValue $JavaUpdatePolicy 'EnableJavaUpdate') -eq 0 -and
        $null -eq (Get-RegValue $JavaUpdateRunKey 'SunJavaUpdateSched')
} {
    New-Item -Path $JavaUpdatePolicy -Force | Out-Null
    Set-ItemProperty -LiteralPath $JavaUpdatePolicy -Name EnableJavaUpdate -Value 0 -Type DWord
    Set-ItemProperty -LiteralPath $JavaUpdatePolicy -Name EnableAutoUpdateCheck -Value 0 -Type DWord
    Set-ItemProperty -LiteralPath $JavaUpdatePolicy -Name NotifyDownload -Value 0 -Type DWord
    Remove-ItemProperty -LiteralPath $JavaUpdateRunKey -Name SunJavaUpdateSched -ErrorAction SilentlyContinue
}

# Firefox finds the Java plugin through this key. Uninstalling another Java 8
# (or its auto-updater) can remove it while the JRE files stay in place.
$javaPlugin = Get-ChildItem 'HKLM:\SOFTWARE\WOW6432Node\MozillaPlugins' -ErrorAction SilentlyContinue |
    Where-Object { $_.PSChildName -like '@java.com/JavaPlugin*' } |
    ForEach-Object { Get-RegValue $_.PSPath 'Path' } |
    Where-Object { $_ -and (Test-Path -LiteralPath $_) } |
    Select-Object -First 1
if ($javaPlugin) {
    Add-Result 'Java plugin registered' 'OK' $javaPlugin
} else {
    Add-Result 'Java plugin registered' 'FAILED' 'MozillaPlugins key missing. Reinstall Java 8 (32-bit), then run this script.'
}

# Firefox 52
$appIni = Join-Path $InstallDir 'application.ini'
$ffVer = if (Test-Path -LiteralPath $appIni) {
    (Get-Content -LiteralPath $appIni) | Where-Object { $_ -like 'Version=*' } | Select-Object -First 1
} else { 'missing' }
if ($ffVer -eq "Version=$FirefoxVersion") {
    Add-Result "Firefox $FirefoxVersion ESR" 'OK' $InstallDir
} else {
    Add-Result "Firefox $FirefoxVersion ESR" 'FAILED' "$ffVer. Run Install-EDanoci.ps1 -Force."
}
Test-AndRepair 'Firefox updater removed' {
    -not ($FirefoxUpdaterFiles | Where-Object { Test-Path -LiteralPath (Join-Path $InstallDir $_) })
} {
    foreach ($f in $FirefoxUpdaterFiles) {
        $fp = Join-Path $InstallDir $f
        if (Test-Path -LiteralPath $fp) { Remove-Item -LiteralPath $fp -Force }
    }
} $InstallDir
$autoconfig = Join-Path $InstallDir 'defaults\pref\autoconfig.js'
$mozCfg     = Join-Path $InstallDir 'mozilla.cfg'
Test-AndRepair 'Firefox prefs locked' {
    (Test-FileContent $autoconfig $AutoconfigJs) -and (Test-FileContent $mozCfg $MozillaCfg)
} {
    New-Item -ItemType Directory -Force -Path (Split-Path $autoconfig) | Out-Null
    Set-Content -LiteralPath $autoconfig -Value $AutoconfigJs -Encoding ASCII
    Set-Content -LiteralPath $mozCfg -Value $MozillaCfg -Encoding ASCII
} 'autoconfig.js, mozilla.cfg'

# Smart Card service
Test-AndRepair 'Smart Card service' {
    $svc = Get-Service SCardSvr
    $svc.StartType -eq 'Automatic' -and $svc.Status -eq 'Running'
} {
    Set-Service -Name SCardSvr -StartupType Automatic
    Start-Service -Name SCardSvr
}

# Per-user Java settings
$deployDir = Join-Path $UserProfile 'AppData\LocalLow\Sun\Java\Deployment'
if (-not (Test-Path -LiteralPath $UserProfile)) {
    Add-Result 'Per-user Java settings' 'FAILED' "Profile not found: $UserProfile"
} else {
    $props = [ordered]@{
        'deployment.security.level'           = 'HIGH'
        'deployment.webjava.enabled'          = 'true'
        'deployment.expiration.check.enabled' = 'false'
    }
    if ($EnableJavaDebug) {
        $props['deployment.trace'] = 'true'
        $props['deployment.log'] = 'true'
        $props['deployment.console.startup.mode'] = 'SHOW'
    }
    $propsFile = Join-Path $deployDir 'deployment.properties'
    Test-AndRepair 'Java deployment.properties' {
        $have = @()
        if (Test-Path -LiteralPath $propsFile) { $have = @(Get-Content -LiteralPath $propsFile) }
        -not ($props.Keys | Where-Object { $have -notcontains "$_=$($props[$_])" })
    } { Set-PropertiesFile $propsFile $props } $propsFile

    $sites = Join-Path $deployDir 'security\exception.sites'
    Test-AndRepair 'Exception site listed' {
        (Test-Path -LiteralPath $sites) -and (@(Get-Content -LiteralPath $sites) -contains $EtaxUrl)
    } {
        New-Item -ItemType Directory -Force -Path (Split-Path $sites) | Out-Null
        Add-Content -LiteralPath $sites -Value $EtaxUrl -Encoding ASCII
    } $EtaxUrl

    $grantLine = "grant codeBase `"$EtaxUrl/-`" {"
    $grant = @(
        $grantLine
        '    permission java.security.AllPermission;'
        '};'
    )
    foreach ($pf in @((Join-Path $UserProfile '.java.policy'), (Join-Path $deployDir 'security\java.policy'))) {
        Test-AndRepair 'Java policy grant' {
            (Test-Path -LiteralPath $pf) -and (Select-String -LiteralPath $pf -SimpleMatch $grantLine -Quiet)
        } {
            New-Item -ItemType Directory -Force -Path (Split-Path $pf) | Out-Null
            Add-Content -LiteralPath $pf -Value $grant -Encoding ASCII
        } $pf
    }

    # A changed library or policy only takes effect once the applet is re-downloaded
    $cache = Join-Path $deployDir 'cache'
    if ($script:Repaired -and (Test-Path -LiteralPath $cache)) {
        Remove-Item -LiteralPath $cache -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# Log and report
# ---------------------------------------------------------------------------
try {
    New-Item -ItemType Directory -Force -Path (Split-Path $LogFile) | Out-Null
    if ((Test-Path -LiteralPath $LogFile) -and (Get-Item -LiteralPath $LogFile).Length -gt 1MB) {
        Move-Item -LiteralPath $LogFile -Destination "$LogFile.old" -Force
    }
    $mode = if ($CheckOnly) { 'check' } else { 'repair' }
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $entry = @("$stamp [$mode] user profile: $UserProfile")
    $entry += $Results | ForEach-Object { "$stamp   {0,-12} {1} {2}" -f $_.Status, $_.Check, $_.Detail }
    Add-Content -LiteralPath $LogFile -Value $entry -Encoding UTF8
} catch {
    Write-Warning "Could not write $LogFile`: $($_.Exception.Message)"
}

$Results
if ($Results | Where-Object { $_.Status -in 'FAILED', 'NEEDS REPAIR' }) { exit 2 }
if ($script:Repaired) { exit 1 }
exit 0
