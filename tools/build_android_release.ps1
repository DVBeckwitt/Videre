[CmdletBinding()]
param(
    [string]$OutputDir,
    [string]$WorkDir,
    [string]$SourceArchive,
    [string]$SourceTarGz,
    [string]$ToolDir = (Join-Path $env:USERPROFILE ".videre-build-tools"),
    [string]$KeyPropertiesPath = $env:ANDROID_KEY_FILE,
    [switch]$SkipToolInstall,
    [switch]$ArtifactsOnly,
    [switch]$ValidateOnly
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$SourceRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$RepoRoot = $SourceRoot
$FlutterSdkRoot = $null
$WorkDirMarker = ".videre-release-work"
$ToolDirMarker = ".videre-build-tools"
if (-not $OutputDir) {
    $OutputDir = Join-Path (Split-Path $SourceRoot -Parent) "Videre-release-artifacts"
}
if (-not $WorkDir) {
    $WorkDir = Join-Path (Split-Path $SourceRoot -Parent) "Videre-release-work"
}

$JdkDir = Join-Path $ToolDir "jdk-21.0.11_10"
$GradleDir = Join-Path $ToolDir "gradle-8.7"
$SdkRoot = Join-Path $ToolDir "android-sdk"
$BundletoolVersion = "1.18.3"
$BundletoolFileName = "bundletool-all-$BundletoolVersion.jar"
$BundletoolJar = Join-Path $ToolDir "bundletool\$BundletoolFileName"
$SigningProperties = $null

$JdkDownload = @{
    Uri = "https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.11%2B10/OpenJDK21U-jdk_x64_windows_hotspot_21.0.11_10.zip"
    FileName = "OpenJDK21U-jdk_x64_windows_hotspot_21.0.11_10.zip"
    Sha256 = "d3625e7cadf23787ea540229544b6e2ab494b3b54da1801879e583e1dfee0a64"
}
$GradleDownload = @{
    Uri = "https://services.gradle.org/distributions/gradle-8.7-bin.zip"
    FileName = "gradle-8.7-bin.zip"
    Sha256 = "544c35d6bd849ae8a5ed0bcea39ba677dc40f49df7d1835561582da2009b961d"
}
$AndroidToolsDownload = @{
    Uri = "https://dl.google.com/android/repository/commandlinetools-win-14742923_latest.zip"
    FileName = "commandlinetools-win-14742923_latest.zip"
    Sha256 = "cc610ccbe83faddb58e1aa68e8fc8743bb30aa5e83577eceb4cc168dae95f9ee"
}
$BundletoolDownload = @{
    Uri = "https://github.com/google/bundletool/releases/download/$BundletoolVersion/$BundletoolFileName"
    FileName = $BundletoolFileName
    Sha256 = "a099cfa1543f55593bc2ed16a70a7c67fe54b1747bb7301f37fdfd6d91028e29"
}
$PortableToolDownloads = @(
    $JdkDownload,
    $GradleDownload,
    $AndroidToolsDownload,
    $BundletoolDownload
)

function New-Directory {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
    }
}

function Get-NormalizedPath {
    param([Parameter(Mandatory)][string]$Path)

    $FullPath = [System.IO.Path]::GetFullPath($Path)
    $Root = [System.IO.Path]::GetPathRoot($FullPath)
    if ($FullPath.Length -eq $Root.Length) {
        return $Root
    }

    return $FullPath.TrimEnd([char[]]@(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    ))
}

function Test-PathIsSameOrChild {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Parent
    )

    $FullPath = Get-NormalizedPath $Path
    $FullParent = Get-NormalizedPath $Parent
    if ($FullPath.Equals($FullParent, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }

    $Prefix = "$FullParent$([System.IO.Path]::DirectorySeparatorChar)"
    return $FullPath.StartsWith($Prefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Assert-NotFileSystemRoot {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name
    )

    $FullPath = Get-NormalizedPath $Path
    if ($FullPath.Equals(
            [System.IO.Path]::GetPathRoot($FullPath),
            [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "$Name cannot be a filesystem root: $FullPath"
    }
}

function Assert-ManagedDirectory {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Marker,
        [Parameter(Mandatory)][string]$Name
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "$Name must be a directory: $Path"
    }

    $Entries = @(Get-ChildItem -LiteralPath $Path -Force)
    if ($Entries.Count -gt 0 -and
        -not (Test-Path -LiteralPath (Join-Path $Path $Marker) -PathType Leaf)) {
        throw "$Name is an unmanaged non-empty directory: $Path"
    }
}

function Initialize-ManagedDirectory {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Marker,
        [Parameter(Mandatory)][string]$Name
    )

    Assert-ManagedDirectory $Path $Marker $Name
    New-Directory $Path
    $MarkerPath = Join-Path $Path $Marker
    if (-not (Test-Path -LiteralPath $MarkerPath)) {
        [System.IO.File]::WriteAllText(
            $MarkerPath,
            "Managed by tools/build_android_release.ps1",
            [System.Text.UTF8Encoding]::new($false)
        )
    }
}

function Remove-SafeChildDirectory {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Parent
    )

    $FullPath = Get-NormalizedPath $Path
    $FullParent = Get-NormalizedPath $Parent
    if ($FullPath.Equals($FullParent, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-PathIsSameOrChild $FullPath $FullParent)) {
        throw "Refusing to remove directory outside its managed parent: $FullPath"
    }

    if (Test-Path -LiteralPath $FullPath) {
        Remove-Item -LiteralPath $FullPath -Recurse -Force
    }
}

function Assert-BuildConfiguration {
    $script:SourceRoot = Get-NormalizedPath $SourceRoot
    $script:OutputDir = Get-NormalizedPath $OutputDir
    $script:WorkDir = Get-NormalizedPath $WorkDir
    $script:ToolDir = Get-NormalizedPath $ToolDir
    $script:JdkDir = Join-Path $ToolDir "jdk-21.0.11_10"
    $script:GradleDir = Join-Path $ToolDir "gradle-8.7"
    $script:SdkRoot = Join-Path $ToolDir "android-sdk"
    $script:BundletoolJar = Join-Path $ToolDir "bundletool\$BundletoolFileName"

    Assert-NotFileSystemRoot $OutputDir "OutputDir"
    Assert-NotFileSystemRoot $WorkDir "WorkDir"
    Assert-NotFileSystemRoot $ToolDir "ToolDir"

    $Paths = @(
        @{ Name = "repository"; Path = $SourceRoot },
        @{ Name = "OutputDir"; Path = $OutputDir },
        @{ Name = "WorkDir"; Path = $WorkDir },
        @{ Name = "ToolDir"; Path = $ToolDir }
    )
    for ($LeftIndex = 0; $LeftIndex -lt $Paths.Count; $LeftIndex++) {
        for ($RightIndex = $LeftIndex + 1; $RightIndex -lt $Paths.Count; $RightIndex++) {
            $Left = $Paths[$LeftIndex]
            $Right = $Paths[$RightIndex]
            if ((Test-PathIsSameOrChild $Left.Path $Right.Path) -or
                (Test-PathIsSameOrChild $Right.Path $Left.Path)) {
                throw "$($Left.Name) and $($Right.Name) must not overlap."
            }
        }
    }

    Assert-ManagedDirectory $WorkDir $WorkDirMarker "WorkDir"
    Assert-ManagedDirectory $ToolDir $ToolDirMarker "ToolDir"

    foreach ($Download in $PortableToolDownloads) {
        if (-not $Download.Uri.StartsWith("https://", [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Portable tool downloads must use HTTPS: $($Download.Uri)"
        }
        if ($Download.Sha256 -notmatch "^[a-fA-F0-9]{64}$") {
            throw "Portable tool download has an invalid SHA-256 digest: $($Download.FileName)"
        }
    }
}

function Invoke-External {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @(),
        [string]$WorkingDirectory = $RepoRoot,
        [string]$InputText
    )

    Push-Location $WorkingDirectory
    try {
        if ($PSBoundParameters.ContainsKey("InputText")) {
            $InputText | & $FilePath @Arguments
        }
        else {
            & $FilePath @Arguments
        }

        if ($LASTEXITCODE -ne 0) {
            throw "Command failed with exit code ${LASTEXITCODE}: $FilePath $($Arguments -join ' ')"
        }
    }
    finally {
        Pop-Location
    }
}

function Test-FileSha256 {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExpectedHash
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }

    $ActualHash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    return $ActualHash.Equals($ExpectedHash, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-VerifiedDownload {
    param(
        [Parameter(Mandatory)][hashtable]$Download,
        [Parameter(Mandatory)][string]$OutFile
    )

    if (Test-FileSha256 $OutFile $Download.Sha256) {
        return
    }

    New-Directory (Split-Path $OutFile -Parent)
    $PartialFile = "$OutFile.partial"
    Remove-Item -LiteralPath $PartialFile -Force -ErrorAction SilentlyContinue
    try {
        Invoke-WebRequest -UseBasicParsing -Uri $Download.Uri -OutFile $PartialFile
        if (-not (Test-FileSha256 $PartialFile $Download.Sha256)) {
            throw "SHA-256 verification failed for $($Download.FileName)."
        }
        Move-Item -LiteralPath $PartialFile -Destination $OutFile -Force
    }
    finally {
        Remove-Item -LiteralPath $PartialFile -Force -ErrorAction SilentlyContinue
    }
}

function Expand-ZipToCleanDirectory {
    param(
        [Parameter(Mandatory)][string]$ZipPath,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$ManagedRoot
    )

    $TempRoot = Get-NormalizedPath ([System.IO.Path]::GetTempPath())
    $Temp = Join-Path $TempRoot ([System.Guid]::NewGuid().ToString())
    New-Directory $Temp
    try {
        Expand-Archive -LiteralPath $ZipPath -DestinationPath $Temp -Force
        Remove-SafeChildDirectory $Destination $ManagedRoot
        New-Directory (Split-Path $Destination -Parent)
        $Children = @(Get-ChildItem -LiteralPath $Temp)
        if ($Children.Count -eq 1 -and $Children[0].PSIsContainer) {
            Move-Item -LiteralPath $Children[0].FullName -Destination $Destination
        }
        else {
            New-Directory $Destination
            Get-ChildItem -LiteralPath $Temp | Move-Item -Destination $Destination
        }
    }
    finally {
        Remove-SafeChildDirectory $Temp $TempRoot
    }
}

function Install-VerifiedZip {
    param(
        [Parameter(Mandatory)][hashtable]$Download,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$ExpectedExecutable
    )

    $InstallMarker = Join-Path $Destination ".videre-source.sha256"
    $ExpectedPath = Join-Path $Destination $ExpectedExecutable
    if ((Test-Path -LiteralPath $ExpectedPath -PathType Leaf) -and
        (Test-Path -LiteralPath $InstallMarker -PathType Leaf) -and
        (Get-Content -LiteralPath $InstallMarker -Raw).Trim().Equals(
            $Download.Sha256,
            [System.StringComparison]::OrdinalIgnoreCase)) {
        return
    }

    $ArchivePath = Join-Path $ToolDir "downloads\$($Download.FileName)"
    Get-VerifiedDownload $Download $ArchivePath
    Expand-ZipToCleanDirectory $ArchivePath $Destination $ToolDir
    if (-not (Test-Path -LiteralPath $ExpectedPath -PathType Leaf)) {
        throw "Verified archive did not contain expected tool: $ExpectedPath"
    }
    [System.IO.File]::WriteAllText(
        $InstallMarker,
        $Download.Sha256,
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Set-LocalProperties {
    $FlutterSdk = if ($script:FlutterSdkRoot) { $script:FlutterSdkRoot } else { Join-Path $RepoRoot "submodules\flutter" }
    $LocalPropertiesPath = Join-Path $RepoRoot "android\local.properties"
    $Properties = @(
        "sdk.dir=$($SdkRoot.Replace('\', '\\'))",
        "flutter.sdk=$($FlutterSdk.Replace('\', '\\'))"
    )
    [System.IO.File]::WriteAllText($LocalPropertiesPath, ($Properties -join [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
}

function Initialize-BuildWorkspace {
    $CheckoutDir = Join-Path $WorkDir "checkout"
    Remove-SafeChildDirectory $CheckoutDir $WorkDir

    if ($SourceArchive) {
        $ArchivePath = (Resolve-Path $SourceArchive).Path
        if ($ArchivePath.EndsWith(".zip", [System.StringComparison]::OrdinalIgnoreCase)) {
            Expand-ZipToCleanDirectory $ArchivePath $CheckoutDir $WorkDir
        }
        else {
            New-Directory $CheckoutDir
            Invoke-External "tar" @("-xzf", $ArchivePath, "-C", $CheckoutDir, "--strip-components=1") $WorkDir
        }

        $FlutterReference = Join-Path $SourceRoot "submodules\flutter"
        if (-not (Test-Path -LiteralPath (Join-Path $FlutterReference "bin\flutter.bat"))) {
            throw "Flutter SDK is missing at $FlutterReference. Run once without SourceArchive or initialize the repo submodule first."
        }
        $script:FlutterSdkRoot = $FlutterReference
    }
    else {
        Invoke-External "git" @("clone", "--no-checkout", $SourceRoot, $CheckoutDir) $WorkDir
        Invoke-External "git" @("checkout", "HEAD") $CheckoutDir

        $FlutterReference = Join-Path $SourceRoot "submodules\flutter"
        if (Test-Path -LiteralPath (Join-Path $FlutterReference ".git")) {
            Invoke-External "git" @("submodule", "update", "--init", "--recursive", "--reference", $FlutterReference) $CheckoutDir
        }
        else {
            Invoke-External "git" @("submodule", "update", "--init", "--recursive") $CheckoutDir
        }
        $script:FlutterSdkRoot = Join-Path $CheckoutDir "submodules\flutter"
    }

    $script:RepoRoot = $CheckoutDir
}

function Write-Sha256Sidecars {
    param([Parameter(Mandatory)][string]$Directory)

    foreach ($File in Get-ChildItem -LiteralPath $Directory -File | Where-Object { $_.Extension -ieq ".apk" }) {
        Remove-Item -LiteralPath "$($File.FullName).sha1" -Force -ErrorAction SilentlyContinue
        $Hash = (Get-FileHash -LiteralPath $File.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        [System.IO.File]::WriteAllText(
            "$($File.FullName).sha256",
            $Hash,
            [System.Text.UTF8Encoding]::new($false)
        )
    }
}

function Write-GzipFile {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )

    $InStream = [System.IO.File]::OpenRead($Source)
    try {
        $OutStream = [System.IO.File]::Create($Destination)
        try {
            $GzipStream = [System.IO.Compression.GZipStream]::new($OutStream, [System.IO.Compression.CompressionLevel]::Optimal)
            try {
                $InStream.CopyTo($GzipStream)
            }
            finally {
                $GzipStream.Dispose()
            }
        }
        finally {
            $OutStream.Dispose()
        }
    }
    finally {
        $InStream.Dispose()
    }
}

function Install-PortableTools {
    Install-VerifiedZip $JdkDownload $JdkDir "bin\java.exe"
    Install-VerifiedZip $GradleDownload $GradleDir "bin\gradle.bat"
    Install-VerifiedZip `
        $AndroidToolsDownload `
        (Join-Path $SdkRoot "cmdline-tools\latest") `
        "bin\sdkmanager.bat"

    New-Directory (Split-Path $BundletoolJar -Parent)
    Get-VerifiedDownload $BundletoolDownload $BundletoolJar
}

function Assert-PortableToolsAvailable {
    $RequiredTools = @(
        (Join-Path $JdkDir "bin\java.exe"),
        (Join-Path $GradleDir "bin\gradle.bat"),
        (Join-Path $SdkRoot "cmdline-tools\latest\bin\sdkmanager.bat"),
        $BundletoolJar
    )
    foreach ($RequiredTool in $RequiredTools) {
        if (-not (Test-Path -LiteralPath $RequiredTool -PathType Leaf)) {
            throw "Required build tool is missing: $RequiredTool"
        }
    }
}

function Set-BuildEnvironment {
    $env:JAVA_HOME = $JdkDir
    $env:ANDROID_HOME = $SdkRoot
    $env:ANDROID_SDK_ROOT = $SdkRoot
    $env:ANDROID_KEY_FILE = $KeyPropertiesPath

    $PathParts = @(
        (Join-Path $JdkDir "bin"),
        (Join-Path $GradleDir "bin"),
        (Join-Path $SdkRoot "cmdline-tools\latest\bin"),
        (Join-Path $SdkRoot "platform-tools")
    )
    $env:PATH = (($PathParts + @($env:PATH)) -join [System.IO.Path]::PathSeparator)
}

function Install-AndroidSdkPackages {
    $SdkManager = Join-Path $SdkRoot "cmdline-tools\latest\bin\sdkmanager.bat"
    $Packages = @(
        "platform-tools",
        "platforms;android-31",
        "platforms;android-33",
        "platforms;android-34",
        "platforms;android-35",
        "platforms;android-36",
        "build-tools;34.0.0",
        "build-tools;36.0.0",
        "cmake;3.22.1",
        "ndk;26.1.10909125"
    )

    Invoke-External $SdkManager $Packages $RepoRoot ("y`n" * 100)
    Invoke-External $SdkManager @("--licenses") $RepoRoot ("y`n" * 100)
}

function Assert-SigningPathIsExternal {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name
    )

    $RestrictedRoots = @(
        @{ Name = "repository"; Path = $SourceRoot },
        @{ Name = "OutputDir"; Path = $OutputDir },
        @{ Name = "WorkDir"; Path = $WorkDir },
        @{ Name = "ToolDir"; Path = $ToolDir }
    )
    foreach ($RestrictedRoot in $RestrictedRoots) {
        if (Test-PathIsSameOrChild $Path $RestrictedRoot.Path) {
            throw "$Name must be stored outside $($RestrictedRoot.Name): $Path"
        }
    }
}

function Initialize-SigningConfiguration {
    if (-not $KeyPropertiesPath) {
        throw "Set ANDROID_KEY_FILE or pass -KeyPropertiesPath with an external Gradle signing properties file."
    }

    $ResolvedKeyProperties = (Resolve-Path -LiteralPath $KeyPropertiesPath).Path
    Assert-SigningPathIsExternal $ResolvedKeyProperties "Signing properties"

    try {
        $Properties = ConvertFrom-StringData -StringData (
            Get-Content -LiteralPath $ResolvedKeyProperties -Raw
        )
    }
    catch {
        throw "Unable to parse signing properties at $ResolvedKeyProperties."
    }

    $RequiredProperties = @("storeFile", "storePassword", "keyPassword", "keyAlias")
    foreach ($PropertyName in $RequiredProperties) {
        if (-not $Properties.ContainsKey($PropertyName) -or
            [string]::IsNullOrWhiteSpace([string]$Properties[$PropertyName])) {
            throw "Signing properties must define $PropertyName."
        }
    }

    $StoreFile = [string]$Properties.storeFile
    if (-not [System.IO.Path]::IsPathRooted($StoreFile)) {
        throw "Signing storeFile must be an absolute path."
    }
    $ResolvedStoreFile = (Resolve-Path -LiteralPath $StoreFile).Path
    Assert-SigningPathIsExternal $ResolvedStoreFile "Signing keystore"

    $script:KeyPropertiesPath = $ResolvedKeyProperties
    $script:SigningProperties = @{
        KeystorePath = $ResolvedStoreFile
        StorePassword = [string]$Properties.storePassword
        KeyPassword = [string]$Properties.keyPassword
        KeyAlias = [string]$Properties.keyAlias
    }
}

function Initialize-GradleWrapper {
    $GradlewBat = Join-Path $RepoRoot "android\gradlew.bat"
    if (Test-Path -LiteralPath $GradlewBat) {
        return
    }

    $Gradle = Join-Path $GradleDir "bin\gradle.bat"
    Invoke-External $Gradle @("wrapper", "--gradle-version", "8.7", "--distribution-type", "bin") (Join-Path $RepoRoot "android")
}

function New-SourceArchives {
    param([Parameter(Mandatory)][string]$Directory)

    if ($SourceArchive) {
        Copy-Item -LiteralPath (Resolve-Path $SourceArchive).Path -Destination (Join-Path $Directory ([IO.Path]::GetFileName($SourceArchive))) -Force
        if ($SourceTarGz) {
            Copy-Item -LiteralPath (Resolve-Path $SourceTarGz).Path -Destination (Join-Path $Directory ([IO.Path]::GetFileName($SourceTarGz))) -Force
        }
        return
    }

    $ZipPath = Join-Path $Directory "source-code.zip"
    $TarPath = Join-Path $Directory "source-code.tar"
    $TarGzPath = Join-Path $Directory "source-code.tar.gz"

    Invoke-External "git" @("archive", "--format=zip", "--output=$ZipPath", "HEAD") $RepoRoot
    Invoke-External "git" @("archive", "--format=tar", "--output=$TarPath", "HEAD") $RepoRoot
    Write-GzipFile $TarPath $TarGzPath
    Remove-Item -LiteralPath $TarPath -Force
}

function Copy-ReleaseArtifacts {
    param([Parameter(Mandatory)][string]$Directory)

    Get-ChildItem -LiteralPath (Join-Path $RepoRoot "build\app\outputs\flutter-apk") -Filter "*.apk" |
        Copy-Item -Destination $Directory -Force

    Copy-Item -LiteralPath (Join-Path $RepoRoot "build\app\outputs\bundle\release\app-release.aab") -Destination $Directory -Force
    Write-Sha256Sidecars $Directory
}

function New-ApksArchive {
    param([Parameter(Mandatory)][string]$Directory)

    $Aab = Join-Path $Directory "app-release.aab"
    $Apks = Join-Path $Directory "app-release.apks"
    $Aapt2 = Join-Path $SdkRoot "build-tools\36.0.0\aapt2.exe"

    if (Test-Path -LiteralPath $Apks) {
        Remove-Item -LiteralPath $Apks -Force
    }

    $TempRoot = Get-NormalizedPath ([System.IO.Path]::GetTempPath())
    $PasswordDirectory = Join-Path $TempRoot "videre-bundletool-$([System.Guid]::NewGuid())"
    $StorePasswordFile = Join-Path $PasswordDirectory "store-password.txt"
    $KeyPasswordFile = Join-Path $PasswordDirectory "key-password.txt"
    New-Directory $PasswordDirectory
    $PasswordAcl = Get-Acl -LiteralPath $PasswordDirectory
    $PasswordAcl.SetAccessRuleProtection($true, $false)
    $InheritanceFlags = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
        [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
    $PasswordAccessRule = [System.Security.AccessControl.FileSystemAccessRule]::new(
        [System.Security.Principal.WindowsIdentity]::GetCurrent().User,
        [System.Security.AccessControl.FileSystemRights]::FullControl,
        $InheritanceFlags,
        [System.Security.AccessControl.PropagationFlags]::None,
        [System.Security.AccessControl.AccessControlType]::Allow
    )
    $PasswordAcl.AddAccessRule($PasswordAccessRule)
    Set-Acl -LiteralPath $PasswordDirectory -AclObject $PasswordAcl
    try {
        [System.IO.File]::WriteAllText(
            $StorePasswordFile,
            $SigningProperties.StorePassword,
            [System.Text.UTF8Encoding]::new($false)
        )
        [System.IO.File]::WriteAllText(
            $KeyPasswordFile,
            $SigningProperties.KeyPassword,
            [System.Text.UTF8Encoding]::new($false)
        )

        Invoke-External (Join-Path $JdkDir "bin\java.exe") @(
            "-jar", $BundletoolJar,
            "build-apks",
            "--bundle=$Aab",
            "--output=$Apks",
            "--ks=$($SigningProperties.KeystorePath)",
            "--ks-pass=file:$StorePasswordFile",
            "--ks-key-alias=$($SigningProperties.KeyAlias)",
            "--key-pass=file:$KeyPasswordFile",
            "--aapt2=$Aapt2"
        )
    }
    finally {
        Remove-SafeChildDirectory $PasswordDirectory $TempRoot
    }
}

Assert-BuildConfiguration
if ($ValidateOnly) {
    Write-Output "Build configuration is valid."
    return
}

Initialize-SigningConfiguration
New-Directory $OutputDir
Initialize-ManagedDirectory $ToolDir $ToolDirMarker "ToolDir"
if (-not $ArtifactsOnly) {
    Initialize-ManagedDirectory $WorkDir $WorkDirMarker "WorkDir"
}

if (-not $SkipToolInstall) {
    Install-PortableTools
}

Assert-PortableToolsAvailable
Set-BuildEnvironment
Install-AndroidSdkPackages

if ($ArtifactsOnly) {
    if (-not (Test-Path -LiteralPath (Join-Path $OutputDir "app-release.aab"))) {
        throw "ArtifactsOnly requires app-release.aab to already exist in $OutputDir."
    }
    Write-Sha256Sidecars $OutputDir
    New-ApksArchive $OutputDir
}
else {
    Initialize-BuildWorkspace
    Set-LocalProperties

    $Flutter = Join-Path $script:FlutterSdkRoot "bin\flutter.bat"
    Invoke-External $Flutter @("config", "--no-analytics") $RepoRoot
    Invoke-External $Flutter @("config", "--jdk-dir", $JdkDir) $RepoRoot
    Invoke-External $Flutter @("precache", "--android") $RepoRoot
    Initialize-GradleWrapper
    Invoke-External $Flutter @("pub", "get") $RepoRoot
    Invoke-External $Flutter @("pub", "run", "flutter_native_splash:create") $RepoRoot
    Invoke-External $Flutter @("build", "apk", "--split-per-abi") $RepoRoot
    Invoke-External $Flutter @("build", "apk") $RepoRoot
    Invoke-External $Flutter @("build", "appbundle") $RepoRoot

    Copy-ReleaseArtifacts $OutputDir
    New-ApksArchive $OutputDir
    New-SourceArchives $OutputDir
}

Get-ChildItem -LiteralPath $OutputDir |
    Sort-Object Name |
    Select-Object Name, Length, FullName |
    Format-Table -AutoSize
