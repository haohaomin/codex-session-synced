param(
    [string]$Version = "1.3.0",
    [string]$Configuration = "Release",
    [string]$Runtime = "win-x64",
    [string]$OutputRoot = "artifacts\local",
    [switch]$NoRestore,
    [switch]$KeepPublish
)

$ErrorActionPreference = "Stop"

function Invoke-Native {
    param(
        [string]$FilePath,
        [string[]]$Arguments
    )

    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$FilePath failed with exit code $LASTEXITCODE"
    }
}

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$project = Join-Path $repoRoot "Windows\CodexSynced.Windows\CodexSynced.Windows.csproj"
$installer = Join-Path $repoRoot "Windows\Installer\Package.wxs"
$outputRootPath = Join-Path $repoRoot $OutputRoot
if (Test-Path -LiteralPath $outputRootPath) {
    $repoRootPath = [System.IO.Path]::GetFullPath($repoRoot)
    $resolvedOutputRoot = [System.IO.Path]::GetFullPath($outputRootPath)
    if (-not $resolvedOutputRoot.StartsWith($repoRootPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to clean output directory outside repository: $resolvedOutputRoot"
    }
    Remove-Item -LiteralPath $resolvedOutputRoot -Recurse -Force
    $outputRootPath = $resolvedOutputRoot
}
$publishDir = Join-Path $outputRootPath "publish"
$msiPath = Join-Path $outputRootPath "Codex-Synced-Windows-x64-$Version.msi"
$zipPath = Join-Path $outputRootPath "Codex-Synced-Windows-x64-$Version.zip"
$checksumsPath = Join-Path $outputRootPath "SHA256SUMS-windows-$Version.txt"

if (-not $NoRestore) {
    Invoke-Native "dotnet" @("restore", $project)
}

New-Item -ItemType Directory -Path $outputRootPath | Out-Null

$restoreArgs = @()
if ($NoRestore) {
    $restoreArgs += "--no-restore"
}

Invoke-Native "dotnet" (@("run") + $restoreArgs + @("--project", $project, "-c", $Configuration, "--", "--self-test"))

Invoke-Native "dotnet" (@(
    "publish",
    $project
) + $restoreArgs + @(
    "-c", $Configuration,
    "-r", $Runtime,
    "--self-contained", "true",
    "-p:Version=$Version",
    "-p:PublishSingleFile=false",
    "-p:DebugType=None",
    "-p:DebugSymbols=false",
    "-o", $publishDir
))

$requiredRuntimeFiles = @("coreclr.dll", "hostfxr.dll", "hostpolicy.dll")
foreach ($runtimeFile in $requiredRuntimeFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $publishDir $runtimeFile))) {
        throw "Self-contained publish is missing required runtime file: $runtimeFile"
    }
}

$wix = Get-Command wix -ErrorAction Stop
Invoke-Native $wix.Source @(
    "build", $installer,
    "-ext", "WixToolset.UI.wixext",
    "-culture", "en-US",
    "-d", "ProductVersion=$Version",
    "-d", "PublishDir=$publishDir",
    "-arch", "x64",
    "-o", $msiPath
)

Compress-Archive -Path (Join-Path $publishDir "*") -DestinationPath $zipPath -Force

$files = @($msiPath, $zipPath)
$lines = foreach ($file in $files) {
    $hash = (Get-FileHash -Algorithm SHA256 $file).Hash.ToLowerInvariant()
    "$hash  $([System.IO.Path]::GetFileName($file))"
}
Set-Content -Path $checksumsPath -Value $lines -Encoding ascii

if (-not $KeepPublish) {
    try {
        Remove-Item -LiteralPath $publishDir -Recurse -Force
        $wixPdb = [System.IO.Path]::ChangeExtension($msiPath, ".wixpdb")
        if (Test-Path -LiteralPath $wixPdb) {
            Remove-Item -LiteralPath $wixPdb -Force
        }
    }
    catch {
        Write-Warning "Package was created, but cleanup of intermediate files failed: $($_.Exception.Message)"
    }
}

Write-Host "Local package ready:"
Write-Host "  MSI: $msiPath"
Write-Host "  ZIP: $zipPath"
Write-Host "  SHA256: $checksumsPath"
