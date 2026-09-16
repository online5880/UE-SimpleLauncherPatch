#Requires -Version 7
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$EngineRoot,
    [string]$OutputDir = ""
)

$ErrorActionPreference = "Stop"
$PluginRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$PluginFile = Join-Path $PluginRoot "SimpleLauncherPatch.uplugin"
$RunUat = Join-Path $EngineRoot "Engine\Build\BatchFiles\RunUAT.bat"
if (-not (Test-Path -LiteralPath $RunUat -PathType Leaf)) {
    throw "RunUAT.bat not found under -EngineRoot: $EngineRoot"
}

$Plugin = Get-Content -LiteralPath $PluginFile -Raw | ConvertFrom-Json
$BuildVersion = Get-Content -LiteralPath (Join-Path $EngineRoot "Engine\Build\Build.version") -Raw | ConvertFrom-Json
$EngineLabel = "UE$($BuildVersion.MajorVersion).$($BuildVersion.MinorVersion)"
if (-not $OutputDir) {
    $OutputDir = Join-Path (Split-Path -Parent $PluginRoot) "SimpleLauncherPatch-Releases"
}
$OutputDir = [IO.Path]::GetFullPath($OutputDir, (Get-Location).Path)
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

$LauncherDir = Join-Path $PluginRoot "Tools\Launcher"
& (Join-Path $LauncherDir "build.cmd")
if ($LASTEXITCODE -ne 0) { throw "Launcher build failed with exit code $LASTEXITCODE" }

$TempRoot = Join-Path ([IO.Path]::GetTempPath()) ("SimpleLauncherPatch-" + [Guid]::NewGuid().ToString("N"))
$TempPackage = Join-Path $TempRoot "Package"
try {
    & $RunUat BuildPlugin "-Plugin=$PluginFile" "-Package=$TempPackage" -TargetPlatforms=Win64 -NoHostPlatform -Rocket
    if ($LASTEXITCODE -ne 0) { throw "BuildPlugin failed with exit code $LASTEXITCODE" }

    # UE 5.6 BuildPlugin can fail while generating its content-only editor host.
    # Build the editor module through a tiny explicit C++ target instead.
    $HostRoot = Join-Path $TempRoot "Host"
    $HostSource = Join-Path $HostRoot "Source\SimpleLauncherPatchHost"
    $PackagedPlugin = Join-Path $HostRoot "Plugins\SimpleLauncherPatch"
    New-Item -ItemType Directory -Force -Path $HostSource, $PackagedPlugin | Out-Null
    Copy-Item -Path (Join-Path $TempPackage "*") -Destination $PackagedPlugin -Recurse -Force

    [IO.File]::WriteAllText((Join-Path $HostRoot "SimpleLauncherPatchHost.uproject"), @'
{
  "FileVersion": 3,
  "Modules": [
    { "Name": "SimpleLauncherPatchHost", "Type": "Runtime", "LoadingPhase": "Default" }
  ],
  "Plugins": [
    { "Name": "SimpleLauncherPatch", "Enabled": true }
  ]
}
'@, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $HostSource "SimpleLauncherPatchHost.Build.cs"), @'
using UnrealBuildTool;
public class SimpleLauncherPatchHost : ModuleRules
{
    public SimpleLauncherPatchHost(ReadOnlyTargetRules Target) : base(Target)
    {
        PCHUsage = PCHUsageMode.UseExplicitOrSharedPCHs;
        PrivateDependencyModuleNames.Add("Core");
    }
}
'@, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $HostSource "SimpleLauncherPatchHost.cpp"), @'
#include "Modules/ModuleManager.h"
IMPLEMENT_PRIMARY_GAME_MODULE(FDefaultModuleImpl, SimpleLauncherPatchHost, "SimpleLauncherPatchHost");
'@, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $HostRoot "Source\SimpleLauncherPatchHostEditor.Target.cs"), @'
using UnrealBuildTool;
public class SimpleLauncherPatchHostEditorTarget : TargetRules
{
    public SimpleLauncherPatchHostEditorTarget(TargetInfo Target) : base(Target)
    {
        Type = TargetType.Editor;
        DefaultBuildSettings = BuildSettingsVersion.Latest;
        IncludeOrderVersion = EngineIncludeOrderVersion.Latest;
        ExtraModuleNames.Add("SimpleLauncherPatchHost");
    }
}
'@, [Text.UTF8Encoding]::new($false))

    $BuildBat = Join-Path $EngineRoot "Engine\Build\BatchFiles\Build.bat"
    & $BuildBat SimpleLauncherPatchHostEditor Win64 Development `
        (Join-Path $HostRoot "SimpleLauncherPatchHost.uproject") -WaitMutex -NoHotReload
    if ($LASTEXITCODE -ne 0) { throw "Editor plugin build failed with exit code $LASTEXITCODE" }

    $PluginZip = Join-Path $OutputDir "SimpleLauncherPatch-$($Plugin.VersionName)-$EngineLabel-Win64.zip"
    $LauncherZip = Join-Path $OutputDir "Launcher-$($Plugin.VersionName)-Win64.zip"
    if (Test-Path -LiteralPath $PluginZip) { Remove-Item -LiteralPath $PluginZip -Force }
    if (Test-Path -LiteralPath $LauncherZip) { Remove-Item -LiteralPath $LauncherZip -Force }

    Compress-Archive -Path (Join-Path $PackagedPlugin "*") -DestinationPath $PluginZip -CompressionLevel Optimal
    Compress-Archive -LiteralPath @(
        (Join-Path $LauncherDir "Launcher.exe"),
        (Join-Path $LauncherDir "Launcher.ini")
    ) -DestinationPath $LauncherZip -CompressionLevel Optimal

    Write-Host "Plugin:   $PluginZip"
    Write-Host "Launcher: $LauncherZip"
}
finally {
    if (Test-Path -LiteralPath $TempRoot) { Remove-Item -LiteralPath $TempRoot -Recurse -Force }
}
