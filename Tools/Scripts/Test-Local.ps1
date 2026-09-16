#Requires -Version 7
[CmdletBinding()]
param(
    [string]$Project = "",
    [string]$EngineRoot = "",
    [string]$GameExe = "",
    [switch]$SkipBuild
)

$ErrorActionPreference = "Stop"
$PluginRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not $Project) {
    $ProjectRoot = Split-Path -Parent (Split-Path -Parent $PluginRoot)
    $Projects = @(Get-ChildItem -LiteralPath $ProjectRoot -Filter *.uproject -File)
    if ($Projects.Count -ne 1) { throw "프로젝트의 Plugins/SimpleLauncherPatch 폴더에서 실행해 주세요." }
    $Project = $Projects[0].FullName
} else {
    $Project = (Get-Item -LiteralPath $Project -ErrorAction Stop).FullName
    $ProjectRoot = Split-Path -Parent $Project
}

$TestRoot = Join-Path $ProjectRoot "Saved\SimpleLauncherPatchTest"
$CloudRoot = Join-Path $TestRoot "Cloud"
$InstallRoot = Join-Path $TestRoot "Install"
$PublishArgs = @{ Project = $Project; Full = $true; CloudRoot = $CloudRoot }
if ($EngineRoot) { $PublishArgs.EngineRoot = $EngineRoot }
if ($GameExe) { $PublishArgs.GameExe = $GameExe }
if ($SkipBuild) { $PublishArgs.SkipBuild = $true }

& (Join-Path $PSScriptRoot "Publish-Patch.ps1") @PublishArgs
& (Join-Path $PSScriptRoot "Serve-CDN.ps1") -CloudRoot $CloudRoot -NoPause

New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null
foreach ($Name in @("Launcher.exe", "Launcher.ini")) {
    $Destination = Join-Path $InstallRoot $Name
    if (-not (Test-Path -LiteralPath $Destination)) {
        Copy-Item -LiteralPath (Join-Path $CloudRoot "Full\$Name") -Destination $Destination
    }
}

Write-Host "로컬 테스트 준비 완료: $InstallRoot" -ForegroundColor Green
Start-Process -FilePath (Join-Path $InstallRoot "Launcher.exe") -WorkingDirectory $InstallRoot
