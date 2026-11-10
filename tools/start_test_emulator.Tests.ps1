#requires -Version 7.0
$ErrorActionPreference = 'Stop'

# Dot-sourcing declares the launcher without starting a device. All command,
# process, port and clock boundaries below are replaced by local fakes.
. (Join-Path $PSScriptRoot 'start_test_emulator.ps1')

$TempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
$TestRoot = Join-Path $TempRoot "videre-emulator-tests-$([Guid]::NewGuid())"
$FailedTests = 0
$PassedTests = 0
$PreviousAvdHome = $env:ANDROID_AVD_HOME

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$Pattern)
    try { & $Action | Out-Null }
    catch {
        Assert-True ($_.Exception.Message -match $Pattern) "Unexpected error: $($_.Exception.Message)"
        return
    }
    throw 'The launcher unexpectedly succeeded.'
}

function Invoke-Test {
    param([string]$Name, [scriptblock]$Action)
    try {
        & $Action
        $script:PassedTests++
        Write-Output "PASS: $Name"
    }
    catch {
        $script:FailedTests++
        Write-Output "FAIL: $Name"
        Write-Output "  $($_.Exception.Message)"
    }
}

function New-LauncherFixture {
    $root = Join-Path $TestRoot ([Guid]::NewGuid().ToString())
    $sdk = Join-Path $root 'Android SDK'
    $avdHome = Join-Path $root 'persistent avd home'
    $avd = Join-Path $avdHome 'Videre_NerdVPN_Test.avd'
    foreach ($directory in @((Join-Path $sdk 'emulator'), (Join-Path $sdk 'platform-tools'), $avd)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    Set-Content -LiteralPath (Join-Path $sdk 'emulator/emulator.exe') -Value 'fake executable; never run'
    Set-Content -LiteralPath (Join-Path $sdk 'platform-tools/adb.exe') -Value 'fake executable; never run'
    Set-Content -LiteralPath (Join-Path $avdHome 'Videre_NerdVPN_Test.ini') -Value "path=$avd"
    Set-Content -LiteralPath (Join-Path $avd 'config.ini') -Value 'AvdId=Videre_NerdVPN_Test'
    $data = Join-Path $avd 'userdata-qemu.img'
    Set-Content -LiteralPath $data -Value 'preserved signed-in fixture data'
    $apk = Join-Path $root 'test app with spaces.apk'
    Set-Content -LiteralPath $apk -Value 'fake APK; never installed'
    $script:Fixture = [pscustomobject]@{
        SdkRoot = $sdk
        AvdHome = $avdHome
        AvdDirectory = $avd
        Data = $data
        DataHash = (Get-FileHash -LiteralPath $data -Algorithm SHA256).Hash
        ApkPath = $apk
    }
    $script:Calls = [System.Collections.Generic.List[object]]::new()
    $script:Starts = [System.Collections.Generic.List[object]]::new()
    $script:Running = $true
    $script:DeviceStatus = 'device'
    $script:PortsFree = $true
    $script:BootComplete = $true
    $script:InstallExitCode = 0
    $script:ListedAvds = 'Videre_NerdVPN_Test'
    $script:Names = [System.Collections.Generic.Queue[string]]::new()
    $script:DefaultAvdName = 'Videre_NerdVPN_Test'
    $script:FakeNow = [DateTime]::SpecifyKind([DateTime]'2026-01-01T00:00:00', [DateTimeKind]::Utc)
    $script:Polls = 0
    $env:ANDROID_AVD_HOME = 'pre-existing-avd-home'
}

function Invoke-VidereTool {
    param([string]$Executable, [string[]]$Arguments, [int]$TimeoutSeconds = 15)
    $script:Calls.Add([pscustomobject]@{
        Executable = $Executable
        Arguments = @($Arguments)
        AvdHome = $env:ANDROID_AVD_HOME
        TimeoutSeconds = $TimeoutSeconds
    })
    $command = $Arguments -join '|'
    if ([IO.Path]::GetFileName($Executable) -eq 'emulator.exe' -and $command -eq '-list-avds') {
        return [pscustomobject]@{ ExitCode = 0; Output = $script:ListedAvds }
    }
    Assert-True ([IO.Path]::GetFileName($Executable) -eq 'adb.exe') 'Unexpected executable reached the fake runner.'
    switch ($command) {
        'devices' {
            $line = if ($script:Running) { "emulator-5596`t$script:DeviceStatus`n" } else { '' }
            return [pscustomobject]@{ ExitCode = 0; Output = "List of devices attached`n$line" }
        }
        '-s|emulator-5596|emu|avd|name' {
            $name = if ($script:Names.Count) { $script:Names.Dequeue() } else { $script:DefaultAvdName }
            return [pscustomobject]@{ ExitCode = 0; Output = "$name`nOK" }
        }
        '-s|emulator-5596|shell|getprop|sys.boot_completed' {
            return [pscustomobject]@{ ExitCode = 0; Output = $(if ($script:BootComplete) { '1' } else { '' }) }
        }
        default {
            if ($Arguments.Count -eq 5 -and ($Arguments[0..3] -join '|') -eq '-s|emulator-5596|install|-r') {
                return [pscustomobject]@{
                    ExitCode = $script:InstallExitCode
                    Output = $(if ($script:InstallExitCode) { 'Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE]' } else { 'Success' })
                }
            }
            throw "Unexpected fake command: $command"
        }
    }
}

function Start-VidereEmulatorProcess {
    param([string]$Executable, [string[]]$Arguments)
    $script:Starts.Add([pscustomobject]@{
        Executable = $Executable
        Arguments = @($Arguments)
        AvdHome = $env:ANDROID_AVD_HOME
    })
    $script:Running = $true
    return [pscustomobject]@{ HasExited = $false; Id = 12345 }
}

function Test-VidereEmulatorPortsFree {
    param([int]$Port)
    Assert-True ($Port -eq 5596) 'The launcher checked an unexpected port.'
    return $script:PortsFree
}

function Get-VidereNow { return $script:FakeNow }
function Wait-ViderePoll {
    $script:Polls++
    $script:FakeNow = $script:FakeNow.AddSeconds(1)
}

function Invoke-FixtureLauncher {
    param([string]$ApkPath)
    $parameters = @{
        SdkRoot = $script:Fixture.SdkRoot
        AvdHome = $script:Fixture.AvdHome
        BootTimeoutSeconds = 5
    }
    if ($ApkPath) { $parameters.ApkPath = $ApkPath }
    Start-VidereTestEmulator @parameters
}

function Assert-PreservedFixture {
    Assert-True ((Get-FileHash -LiteralPath $script:Fixture.Data -Algorithm SHA256).Hash -eq $script:Fixture.DataHash) 'The launcher changed the existing user data.'
    Assert-True ($env:ANDROID_AVD_HOME -eq 'pre-existing-avd-home') 'The launcher did not restore ANDROID_AVD_HOME.'
    foreach ($call in $script:Calls) {
        Assert-True (-not ($call.Arguments -contains 'uninstall')) 'The launcher attempted an uninstall.'
        Assert-True (-not ($call.Arguments -contains 'wipe-data')) 'The launcher attempted to wipe user data.'
        Assert-True (-not ($call.Arguments -contains 'clear')) 'The launcher attempted to clear app data.'
    }
}

New-Item -ItemType Directory -Path $TestRoot | Out-Null
try {
    Invoke-Test 'reuses the matching running AVD without installing or restarting' {
        New-LauncherFixture
        Invoke-FixtureLauncher | Out-Null
        Assert-True ($script:Starts.Count -eq 0) 'An already running AVD was started again.'
        Assert-True (@($script:Calls | Where-Object { $_.Arguments -contains 'install' }).Count -eq 0) 'The default run attempted an installation.'
        Assert-PreservedFixture
    }

    Invoke-Test 'cold boots existing disk data with the persistent AVD home' {
        New-LauncherFixture
        $script:Running = $false
        Invoke-FixtureLauncher | Out-Null
        Assert-True ($script:Starts.Count -eq 1) 'The launcher did not start exactly one emulator.'
        $start = $script:Starts[0]
        Assert-True ($start.AvdHome -eq $script:Fixture.AvdHome) 'The emulator did not inherit the persistent AVD home.'
        foreach ($flag in @('-no-snapshot', '-no-audio', '-gpu', 'swiftshader')) {
            Assert-True ($start.Arguments -contains $flag) "Required startup option is missing: $flag"
        }
        Assert-True (($start.Arguments -join '|') -match '-avd\|Videre_NerdVPN_Test') 'The configured AVD was not selected.'
        Assert-True (($start.Arguments -join '|') -match '-port\|5596') 'The configured emulator port was not selected.'
        Assert-True (-not ($start.Arguments -contains '-wipe-data')) 'The emulator was launched with data wiping.'
        Assert-PreservedFixture
    }

    Invoke-Test 'refuses a different AVD occupying the target serial' {
        New-LauncherFixture
        $script:DefaultAvdName = 'Another_AVD'
        Assert-Throws { Invoke-FixtureLauncher -ApkPath $script:Fixture.ApkPath } 'AVD|emulator|device'
        Assert-True ($script:Starts.Count -eq 0) 'The launcher started an emulator on an occupied serial.'
        Assert-True (@($script:Calls | Where-Object { $_.Arguments -contains 'install' }).Count -eq 0) 'The launcher installed into another AVD.'
        Assert-PreservedFixture
    }

    Invoke-Test 'refuses an occupied port that adb cannot identify' {
        New-LauncherFixture
        $script:Running = $false
        $script:PortsFree = $false
        Assert-Throws { Invoke-FixtureLauncher } 'port|5596'
        Assert-True ($script:Starts.Count -eq 0) 'The launcher attempted to take over an occupied port.'
        Assert-PreservedFixture
    }

    Invoke-Test 'missing AVD registration fails without creating or launching it' {
        New-LauncherFixture
        Remove-Item -LiteralPath (Join-Path $script:Fixture.AvdHome 'Videre_NerdVPN_Test.ini')
        Assert-Throws { Invoke-FixtureLauncher } 'AVD|README|register'
        Assert-True ($script:Starts.Count -eq 0) 'A missing AVD was launched.'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $script:Fixture.AvdHome 'Videre_NerdVPN_Test.ini'))) 'The launcher created an AVD registration.'
        Assert-PreservedFixture
    }

    Invoke-Test 'unregistered emulator listing cannot launch an unrelated AVD' {
        New-LauncherFixture
        $script:ListedAvds = 'Unrelated_AVD'
        Assert-Throws { Invoke-FixtureLauncher } 'AVD|registered|available'
        Assert-True ($script:Starts.Count -eq 0) 'An unregistered AVD was launched.'
        Assert-PreservedFixture
    }

    Invoke-Test 'boot polling times out without resetting the device' {
        New-LauncherFixture
        $script:BootComplete = $false
        Assert-Throws { Invoke-FixtureLauncher -ApkPath $script:Fixture.ApkPath } 'boot|timed|timeout'
        Assert-True ($script:Polls -gt 0 -and $script:Polls -le 6) 'Boot polling was not bounded by the configured timeout.'
        Assert-True ($script:Starts.Count -eq 0) 'A stalled existing device was restarted.'
        Assert-True (@($script:Calls | Where-Object { $_.Arguments -contains 'install' }).Count -eq 0) 'Installation ran before boot completed.'
        Assert-PreservedFixture
    }

    Invoke-Test 'missing APK is rejected before an emulator is started' {
        New-LauncherFixture
        $script:Running = $false
        Assert-Throws { Invoke-FixtureLauncher -ApkPath (Join-Path $TestRoot 'missing.apk') } 'APK|exist|file'
        Assert-True ($script:Starts.Count -eq 0) 'An invalid APK triggered emulator startup.'
        Assert-True ($script:Calls.Count -eq 0) 'Tools ran before the optional APK was validated.'
        Assert-PreservedFixture
    }

    Invoke-Test 'optional APK update uses install -r with the intact spaced path' {
        New-LauncherFixture
        Invoke-FixtureLauncher -ApkPath $script:Fixture.ApkPath | Out-Null
        $installs = @($script:Calls | Where-Object { $_.Arguments -contains 'install' })
        Assert-True ($installs.Count -eq 1) 'The optional APK was not installed exactly once.'
        Assert-True (($installs[0].Arguments[0..3] -join '|') -eq '-s|emulator-5596|install|-r') 'Installation did not preserve app data with install -r.'
        Assert-True ($installs[0].Arguments[4] -eq $script:Fixture.ApkPath) 'The APK path was split or changed.'
        Assert-PreservedFixture
    }

    Invoke-Test 'identity is rechecked before installing into the booted device' {
        New-LauncherFixture
        $script:Names.Enqueue('Videre_NerdVPN_Test')
        $script:DefaultAvdName = 'Another_AVD'
        Assert-Throws { Invoke-FixtureLauncher -ApkPath $script:Fixture.ApkPath } 'AVD|emulator|device'
        Assert-True (@($script:Calls | Where-Object { $_.Arguments -contains 'install' }).Count -eq 0) 'A changed device identity received the APK.'
        Assert-PreservedFixture
    }

    Invoke-Test 'a signing mismatch stops without uninstall or retry' {
        New-LauncherFixture
        $script:InstallExitCode = 1
        Assert-Throws { Invoke-FixtureLauncher -ApkPath $script:Fixture.ApkPath } 'install|APK|update'
        Assert-True (@($script:Calls | Where-Object { $_.Arguments -contains 'install' }).Count -eq 1) 'A failed install was retried.'
        Assert-PreservedFixture
    }
}
finally {
    $env:ANDROID_AVD_HOME = $PreviousAvdHome
    $fullRoot = [IO.Path]::GetFullPath($TestRoot)
    $prefix = $TempRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $fullRoot.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Refusing to clean a test directory outside the temporary root.'
    }
    Remove-Item -LiteralPath $fullRoot -Recurse -Force
}

if ($FailedTests) { throw "$FailedTests emulator launcher test(s) failed." }
Write-Output "$PassedTests emulator launcher tests passed."
