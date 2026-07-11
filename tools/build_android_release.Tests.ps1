$ErrorActionPreference = "Stop"

$ScriptPath = Join-Path $PSScriptRoot "build_android_release.ps1"
$PowerShellPath = (Get-Process -Id $PID).Path
$TempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
$TestRoot = Join-Path $TempRoot "videre-release-tests-$([System.Guid]::NewGuid())"
$FailedTests = 0

function Assert-True {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-Matches {
    param(
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][string]$Pattern,
        [Parameter(Mandatory)][string]$Message
    )

    Assert-True ([regex]::IsMatch($Value, $Pattern)) $Message
}

function Assert-DoesNotMatch {
    param(
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][string]$Pattern,
        [Parameter(Mandatory)][string]$Message
    )

    Assert-True (-not [regex]::IsMatch($Value, $Pattern)) $Message
}

function Invoke-Test {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Test
    )

    try {
        & $Test
        Write-Output "PASS: $Name"
    }
    catch {
        $script:FailedTests++
        Write-Output "FAIL: $Name"
        Write-Output "  $($_.Exception.Message)"
    }
}

function Invoke-BuildValidation {
    param(
        [Parameter(Mandatory)][string]$WorkDir,
        [Parameter(Mandatory)][string]$OutputDir,
        [Parameter(Mandatory)][string]$ToolDir
    )

    $Output = & $PowerShellPath -NoProfile -File $ScriptPath `
        -ValidateOnly `
        -WorkDir $WorkDir `
        -OutputDir $OutputDir `
        -ToolDir $ToolDir 2>&1

    [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output = ($Output | Out-String)
    }
}

New-Item -ItemType Directory -Path $TestRoot | Out-Null
try {
    Invoke-Test "rejects a filesystem root" {
        $Root = [System.IO.Path]::GetPathRoot($TestRoot)
        $Result = Invoke-BuildValidation `
            -WorkDir $Root `
            -OutputDir (Join-Path $TestRoot "root-output") `
            -ToolDir (Join-Path $TestRoot "root-tools")

        Assert-True ($Result.ExitCode -ne 0) "Filesystem root validation unexpectedly succeeded."
        Assert-Matches $Result.Output "filesystem root" "Filesystem root error was not descriptive."
    }

    Invoke-Test "does not touch an unmanaged non-empty directory" {
        $WorkDir = Join-Path $TestRoot "unmanaged"
        $Sentinel = Join-Path $WorkDir "keep.txt"
        New-Item -ItemType Directory -Path $WorkDir | Out-Null
        Set-Content -LiteralPath $Sentinel -Value "keep"

        $Result = Invoke-BuildValidation `
            -WorkDir $WorkDir `
            -OutputDir (Join-Path $TestRoot "unmanaged-output") `
            -ToolDir (Join-Path $TestRoot "unmanaged-tools")

        Assert-True ($Result.ExitCode -ne 0) "Unmanaged directory validation unexpectedly succeeded."
        Assert-Matches $Result.Output "unmanaged" "Unmanaged directory error was not descriptive."
        Assert-True (Test-Path -LiteralPath $Sentinel) "Validation modified the unmanaged directory."
    }

    Invoke-Test "accepts a marked workspace without modifying it" {
        $WorkDir = Join-Path $TestRoot "managed"
        $Marker = Join-Path $WorkDir ".videre-release-work"
        New-Item -ItemType Directory -Path $WorkDir | Out-Null
        Set-Content -LiteralPath $Marker -Value "managed by Videre"

        $Result = Invoke-BuildValidation `
            -WorkDir $WorkDir `
            -OutputDir (Join-Path $TestRoot "managed-output") `
            -ToolDir (Join-Path $TestRoot "managed-tools")

        Assert-True ($Result.ExitCode -eq 0) "Marked workspace validation failed: $($Result.Output)"
        Assert-True (Test-Path -LiteralPath $Marker) "Validation removed the workspace marker."
    }

    Invoke-Test "requires external signing configuration before running tools" {
        $WorkDir = Join-Path $TestRoot "signing-work"
        $ToolDir = Join-Path $TestRoot "signing-tools"
        New-Item -ItemType Directory -Path $WorkDir | Out-Null
        New-Item -ItemType Directory -Path $ToolDir | Out-Null
        Set-Content -LiteralPath (Join-Path $WorkDir ".videre-release-work") -Value "managed by Videre"
        Set-Content -LiteralPath (Join-Path $ToolDir ".videre-build-tools") -Value "managed by Videre"

        $PreviousKeyFile = $env:ANDROID_KEY_FILE
        try {
            Remove-Item Env:ANDROID_KEY_FILE -ErrorAction SilentlyContinue
            $Output = & $PowerShellPath -NoProfile -File $ScriptPath `
                -SkipToolInstall `
                -WorkDir $WorkDir `
                -OutputDir (Join-Path $TestRoot "signing-output") `
                -ToolDir $ToolDir 2>&1
            $ExitCode = $LASTEXITCODE
        }
        finally {
            $env:ANDROID_KEY_FILE = $PreviousKeyFile
        }

        Assert-True ($ExitCode -ne 0) "Build unexpectedly ran without signing configuration."
        Assert-Matches ($Output | Out-String) "ANDROID_KEY_FILE" "Missing signing error was not descriptive."
    }

    Invoke-Test "does not echo malformed signing content" {
        $WorkDir = Join-Path $TestRoot "malformed-signing-work"
        $ToolDir = Join-Path $TestRoot "malformed-signing-tools"
        $KeyProperties = Join-Path $TestRoot "malformed-key.properties"
        $SecretText = "leaked-secret-without-equals"
        New-Item -ItemType Directory -Path $WorkDir | Out-Null
        New-Item -ItemType Directory -Path $ToolDir | Out-Null
        Set-Content -LiteralPath (Join-Path $WorkDir ".videre-release-work") -Value "managed by Videre"
        Set-Content -LiteralPath (Join-Path $ToolDir ".videre-build-tools") -Value "managed by Videre"
        Set-Content -LiteralPath $KeyProperties -Value $SecretText

        $Output = & $PowerShellPath -NoProfile -File $ScriptPath `
            -SkipToolInstall `
            -KeyPropertiesPath $KeyProperties `
            -WorkDir $WorkDir `
            -OutputDir (Join-Path $TestRoot "malformed-signing-output") `
            -ToolDir $ToolDir 2>&1
        $ExitCode = $LASTEXITCODE
        $OutputText = $Output | Out-String

        Assert-True ($ExitCode -ne 0) "Malformed signing properties unexpectedly succeeded."
        Assert-Matches $OutputText "Unable to parse signing properties" "Malformed signing error was not descriptive."
        Assert-DoesNotMatch $OutputText $SecretText "Malformed signing content leaked into command output."
    }

    Invoke-Test "rejects signing material inside a managed build directory" {
        $WorkDir = Join-Path $TestRoot "nested-signing-work"
        $ToolDir = Join-Path $TestRoot "nested-signing-tools"
        $KeyProperties = Join-Path $WorkDir "key.properties"
        $Keystore = Join-Path $TestRoot "nested-signing.jks"
        New-Item -ItemType Directory -Path $WorkDir | Out-Null
        New-Item -ItemType Directory -Path $ToolDir | Out-Null
        Set-Content -LiteralPath (Join-Path $WorkDir ".videre-release-work") -Value "managed by Videre"
        Set-Content -LiteralPath (Join-Path $ToolDir ".videre-build-tools") -Value "managed by Videre"
        Set-Content -LiteralPath $Keystore -Value "test keystore"
        @(
            "storeFile=$($Keystore.Replace('\', '/'))",
            "storePassword=test-store-password",
            "keyPassword=test-key-password",
            "keyAlias=test"
        ) | Set-Content -LiteralPath $KeyProperties

        $Output = & $PowerShellPath -NoProfile -File $ScriptPath `
            -SkipToolInstall `
            -KeyPropertiesPath $KeyProperties `
            -WorkDir $WorkDir `
            -OutputDir (Join-Path $TestRoot "nested-signing-output") `
            -ToolDir $ToolDir 2>&1
        $ExitCode = $LASTEXITCODE

        Assert-True ($ExitCode -ne 0) "Signing material inside WorkDir unexpectedly passed validation."
        Assert-Matches ($Output | Out-String) "WorkDir" "Signing path error did not identify WorkDir."
    }

    $Source = Get-Content -LiteralPath $ScriptPath -Raw

    Invoke-Test "contains no embedded or inline signing passwords" {
        Assert-DoesNotMatch $Source "videre-local-(store|key)-password" "Embedded signing password found."
        Assert-DoesNotMatch $Source "--(ks|key)-pass=pass:" "Inline bundletool password found."
        Assert-Matches $Source "--ks-pass=file:" "Bundletool store password file is missing."
        Assert-Matches $Source "--key-pass=file:" "Bundletool key password file is missing."
        Assert-Matches $Source 'SetAccessRuleProtection\(\$true,\s*\$false\)' "Password directory does not disable inherited ACLs."
    }

    Invoke-Test "uses SHA-256 for downloads and release sidecars" {
        Assert-DoesNotMatch $Source "(?i)Write-Sha1Sidecars|Cryptography\.SHA1|Algorithm\s+SHA1" "SHA-1 generation remains."
        Assert-Matches $Source "Get-FileHash[^\r\n]+-Algorithm SHA256" "SHA-256 hashing is missing."
        Assert-Matches $Source "\.sha256" "SHA-256 artifact sidecars are missing."
    }

    Invoke-Test "routes recursive deletion through the checked helper" {
        $RecursiveDeletes = [regex]::Matches($Source, 'Remove-Item[^\r\n]+-Recurse')

        Assert-True ($RecursiveDeletes.Count -eq 1) "Expected one guarded recursive delete; found $($RecursiveDeletes.Count)."
        Assert-Matches $Source 'function Remove-SafeChildDirectory' "Checked recursive-delete helper is missing."
    }

    Invoke-Test "pins every portable tool to a SHA-256 digest" {
        $Digests = [regex]::Matches($Source, 'Sha256\s*=\s*"[a-fA-F0-9]{64}"')

        Assert-True ($Digests.Count -eq 4) "Expected four pinned SHA-256 tool digests; found $($Digests.Count)."
        Assert-DoesNotMatch $Source "binary/latest" "Mutable latest JDK endpoint remains."
    }
}
finally {
    $FullTestRoot = [System.IO.Path]::GetFullPath($TestRoot)
    $TempPrefix = "$($TempRoot.TrimEnd('\'))\"
    if (-not $FullTestRoot.StartsWith($TempPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to clean test directory outside the temp root: $FullTestRoot"
    }
    Remove-Item -LiteralPath $FullTestRoot -Recurse -Force
}

if ($FailedTests -gt 0) {
    throw "$FailedTests release script test(s) failed."
}

exit 0
