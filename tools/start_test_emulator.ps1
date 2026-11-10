#requires -Version 7.0
[CmdletBinding()]
param(
    [string]$AvdName = 'Videre_NerdVPN_Test',
    [int]$Port = 5596,
    [string]$SdkRoot,
    [string]$AvdHome,
    [string]$ApkPath,
    [int]$BootTimeoutSeconds = 300
)

# Dot-sourcing exposes the launcher and its process boundaries for offline tests.
# It never starts a device until Start-VidereTestEmulator is invoked.
function Invoke-VidereTool {
    param([string]$Executable, [string[]]$Arguments, [int]$TimeoutSeconds = 15)

    $start = [System.Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $Executable
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw 'Could not start an Android SDK tool.' }
        $output = $process.StandardOutput.ReadToEndAsync()
        $errors = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            # Only this short-lived SDK command is terminated, never an emulator.
            $process.Kill()
            throw "Android SDK command timed out after $TimeoutSeconds seconds."
        }
        [pscustomobject]@{
            ExitCode = $process.ExitCode
            Output = ($output.GetAwaiter().GetResult() + $errors.GetAwaiter().GetResult()).Trim()
        }
    }
    finally { $process.Dispose() }
}

function Start-VidereEmulatorProcess {
    param([string]$Executable, [string[]]$Arguments)

    # All arguments here are fixed flags or validated AVD/port values, with no
    # whitespace or quoting. APK paths use ProcessStartInfo.ArgumentList above.
    Start-Process -FilePath $Executable -ArgumentList $Arguments -WindowStyle Hidden | Out-Null
}

function Test-VidereEmulatorPortsFree {
    param([int]$Port)
    $listeners = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()
    return -not ($listeners | Where-Object { $_.Port -eq $Port -or $_.Port -eq ($Port + 1) })
}

function Get-VidereNow { [DateTime]::UtcNow }
function Wait-ViderePoll { Start-Sleep -Milliseconds 500 }

function Get-VidereAvdName {
    param([string]$Adb, [string]$Serial, [int]$TimeoutSeconds = 10)
    $result = Invoke-VidereTool $Adb @('-s', $Serial, 'emu', 'avd', 'name') $TimeoutSeconds
    if ($result.ExitCode -ne 0) { return $null }
    $names = @($result.Output -split '\r?\n' | ForEach-Object { $_.Trim() } |
        Where-Object { $_ -match '^[A-Za-z0-9_-]+$' -and $_ -ne 'OK' })
    if ($names.Count -ne 1) { return $null }
    return $names[0]
}

function Start-VidereTestEmulator {
    [CmdletBinding()]
    param(
        [string]$AvdName = 'Videre_NerdVPN_Test',
        [int]$Port = 5596,
        [string]$SdkRoot,
        [string]$AvdHome,
        [string]$ApkPath,
        [int]$BootTimeoutSeconds = 300
    )

    $ErrorActionPreference = 'Stop'
    if ($AvdName -notmatch '^[A-Za-z0-9_-]+$') { throw 'AvdName must contain only letters, digits, underscores or hyphens.' }
    if ($Port -lt 5554 -or $Port -gt 5682 -or $Port % 2 -ne 0) {
        throw 'Port must be an even Android emulator console port from 5554 through 5682.'
    }
    if ($BootTimeoutSeconds -lt 1 -or $BootTimeoutSeconds -gt 900) {
        throw 'BootTimeoutSeconds must be between 1 and 900.'
    }
    if (-not $SdkRoot) {
        $SdkRoot = if ($env:ANDROID_HOME) { $env:ANDROID_HOME }
        elseif ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'Android/Sdk' }
        else { throw 'Set ANDROID_HOME or supply -SdkRoot for the installed Android SDK.' }
    }
    if (-not $AvdHome) {
        if (-not $env:LOCALAPPDATA) { throw 'Supply -AvdHome for the existing persistent test AVD directory.' }
        $AvdHome = Join-Path $env:LOCALAPPDATA 'Videre/testing/avd-home'
    }
    $SdkRoot = [System.IO.Path]::GetFullPath($SdkRoot)
    $AvdHome = [System.IO.Path]::GetFullPath($AvdHome)
    $adb = Join-Path $SdkRoot 'platform-tools/adb.exe'
    $emulator = Join-Path $SdkRoot 'emulator/emulator.exe'
    foreach ($tool in @($adb, $emulator)) {
        if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) { throw "Android SDK tool is missing: $tool" }
    }
    if ($ApkPath) {
        if ([System.IO.Path]::GetExtension($ApkPath) -ine '.apk' -or
            -not (Test-Path -LiteralPath $ApkPath -PathType Leaf)) {
            throw 'ApkPath must name an existing APK file. No device changes were made.'
        }
        $ApkPath = (Resolve-Path -LiteralPath $ApkPath).Path
    }

    $registration = Join-Path $AvdHome "$AvdName.ini"
    $setupMessage = "The persistent test AVD '$AvdName' is not registered in '$AvdHome'. See README: Persistent NerdVPN test emulator. The launcher never creates or resets an AVD."
    if (-not (Test-Path -LiteralPath $registration -PathType Leaf)) { throw $setupMessage }
    $paths = @(Get-Content -LiteralPath $registration | Where-Object { $_ -match '^path=' } |
        ForEach-Object { $_.Substring(5).Trim() })
    if ($paths.Count -ne 1 -or -not [System.IO.Path]::IsPathFullyQualified($paths[0]) -or
        -not (Test-Path -LiteralPath (Join-Path $paths[0] 'config.ini') -PathType Leaf)) {
        throw $setupMessage
    }

    $previousHome = $env:ANDROID_AVD_HOME
    try {
        $env:ANDROID_AVD_HOME = $AvdHome
        $listed = Invoke-VidereTool $emulator @('-list-avds')
        if ($listed.ExitCode -ne 0 -or
            $AvdName -cnotin @($listed.Output -split '\r?\n' | ForEach-Object { $_.Trim() })) {
            throw $setupMessage
        }
        $serial = "emulator-$Port"
        $devices = Invoke-VidereTool $adb @('devices')
        if ($devices.ExitCode -ne 0) { throw 'Could not inspect connected Android devices. No emulator was started.' }
        $present = $devices.Output -match "(?m)^$([regex]::Escape($serial))\s+\S+"
        if (-not $present) {
            if (-not (Test-VidereEmulatorPortsFree $Port)) {
                throw "Port $Port or $($Port + 1) is occupied and its AVD identity cannot be verified. No process was stopped or replaced."
            }
            Start-VidereEmulatorProcess $emulator @('-avd', $AvdName, '-port', "$Port", '-no-snapshot', '-no-audio', '-gpu', 'swiftshader')
            Write-Host "Starting persistent test AVD '$AvdName' on $serial."
        }
        else { Write-Host "Checking existing emulator $serial." }

        $deadline = (Get-VidereNow).AddSeconds($BootTimeoutSeconds)
        $ready = $false
        while ((Get-VidereNow) -lt $deadline) {
            $remaining = [Math]::Max(1, [Math]::Min(10, [Math]::Ceiling(($deadline - (Get-VidereNow)).TotalSeconds)))
            $name = Get-VidereAvdName $adb $serial $remaining
            if ($name) {
                if ($name -cne $AvdName) {
                    throw "Emulator $serial belongs to AVD '$name', not '$AvdName'. No installation or reset was performed."
                }
                $boot = Invoke-VidereTool $adb @('-s', $serial, 'shell', 'getprop', 'sys.boot_completed') $remaining
                if ($boot.ExitCode -eq 0 -and $boot.Output.Trim() -eq '1') {
                    $ready = $true
                    break
                }
            }
            Wait-ViderePoll
        }
        if (-not $ready) {
            throw "AVD '$AvdName' did not finish booting within $BootTimeoutSeconds seconds. It was left running with its data unchanged."
        }
        # A device can disappear or be replaced while booting. Never install
        # into a serial solely because it matched at an earlier poll.
        if ((Get-VidereAvdName $adb $serial) -cne $AvdName) {
            throw "AVD identity changed on $serial. No APK was installed."
        }
        if ($ApkPath) {
            $install = Invoke-VidereTool $adb @('-s', $serial, 'install', '-r', $ApkPath) 120
            if ($install.ExitCode -ne 0 -or $install.Output -notmatch '(?m)^Success\s*$') {
                throw 'APK update failed. Existing app data was preserved; the launcher will not uninstall or reset it.'
            }
        }
        Write-Host "Ready: $serial ($AvdName). Existing app data is retained; verify current server access in the app."
        [pscustomobject]@{ Serial = $serial; AvdName = $AvdName; AvdHome = $AvdHome; InstalledApk = $ApkPath }
    }
    finally { $env:ANDROID_AVD_HOME = $previousHome }
}

if ($MyInvocation.InvocationName -ne '.') { Start-VidereTestEmulator @PSBoundParameters }
