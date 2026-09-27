#Requires -Version 7
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$Project,
    [Parameter(Mandatory)] [string]$EngineRoot,
    [switch]$KeepArtifacts
)

$ErrorActionPreference = "Stop"
$ProjectFile = (Get-Item -LiteralPath $Project -ErrorAction Stop).FullName
if ([IO.Path]::GetExtension($ProjectFile) -ne ".uproject") { throw "-Project must be a .uproject file." }
$ProjectRoot = Split-Path -Parent $ProjectFile
$EditorCmd = Join-Path $EngineRoot "Engine\Binaries\Win64\UnrealEditor-Cmd.exe"
$BuildBat = Join-Path $EngineRoot "Engine\Build\BatchFiles\Build.bat"
foreach ($Path in @($EditorCmd, $BuildBat)) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Required Unreal file is missing: $Path" }
}
foreach ($Name in @("Source", "Config", "Content")) {
    if (-not (Test-Path -LiteralPath (Join-Path $ProjectRoot $Name) -PathType Container)) {
        throw "Project directory is missing: $Name"
    }
}
$EditorTargets = @(Get-ChildItem -LiteralPath (Join-Path $ProjectRoot "Source") -Filter "*Editor.Target.cs" -File)
if ($EditorTargets.Count -ne 1) { throw "Expected exactly one Editor target in $ProjectRoot\Source." }
$EditorTarget = $EditorTargets[0].Name -replace '\.Target\.cs$', ''

$TempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$FixtureRoot = Join-Path $TempBase ("SimpleLauncherPatch-E2E-" + [guid]::NewGuid().ToString("N"))
$FixtureRoot = [IO.Path]::GetFullPath($FixtureRoot)
if (-not $FixtureRoot.StartsWith($TempBase + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw "Fixture must stay inside the temporary directory."
}
$Succeeded = $false
New-Item -ItemType Directory -Path $FixtureRoot | Out-Null
try {
    foreach ($Name in @("Source", "Config", "Content")) {
        Copy-Item -LiteralPath (Join-Path $ProjectRoot $Name) -Destination $FixtureRoot -Recurse -Force
    }
    $FixtureProject = Join-Path $FixtureRoot (Split-Path -Leaf $ProjectFile)
    $ProjectData = Get-Content -LiteralPath $ProjectFile -Raw | ConvertFrom-Json
    $ExistingPlugin = @($ProjectData.Plugins | Where-Object Name -eq "SimpleLauncherPatch")
    if ($ExistingPlugin.Count -gt 0) {
        $ExistingPlugin[0].Enabled = $true
    } else {
        $ProjectData.Plugins = @($ProjectData.Plugins) + [pscustomobject]@{ Name = "SimpleLauncherPatch"; Enabled = $true }
    }
    $ProjectData | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $FixtureProject -Encoding utf8

    $ReleaseDir = Join-Path $FixtureRoot "Releases"
    & (Join-Path $PSScriptRoot "Package-Release.ps1") -EngineRoot $EngineRoot -OutputDir $ReleaseDir
    if ($LASTEXITCODE -ne 0) { throw "Plugin packaging failed." }
    $PluginZip = @(Get-ChildItem -LiteralPath $ReleaseDir -Filter "SimpleLauncherPatch-*-Win64.zip" -File)
    if ($PluginZip.Count -ne 1) { throw "Expected one plugin ZIP in $ReleaseDir." }
    $FixturePlugin = Join-Path $FixtureRoot "Plugins\SimpleLauncherPatch"
    New-Item -ItemType Directory -Path $FixturePlugin -Force | Out-Null
    Expand-Archive -LiteralPath $PluginZip[0].FullName -DestinationPath $FixturePlugin -Force

    & $BuildBat $EditorTarget Win64 Development $FixtureProject -WaitMutex -NoHotReload
    if ($LASTEXITCODE -ne 0) { throw "Fixture editor build failed (exit $LASTEXITCODE)." }

    $EditorLog = Join-Path $FixtureRoot "EditorE2E.log"
    & $EditorCmd $FixtureProject -unattended -nop4 -NullRHI -NoSplash -UTF8Output -SimpleLauncherPatchE2E `
        "-ExecCmds=Automation RunTests SimpleLauncherPatch.Editor.LocalPublish;Quit" "-abslog=$EditorLog"
    if ($LASTEXITCODE -ne 0) { throw "Editor E2E failed (exit $LASTEXITCODE). Log: $EditorLog" }

    $Cloud = Join-Path $FixtureRoot "Saved\SimpleLauncherPatch\Cloud"
    $Live = (Get-Content -LiteralPath (Join-Path $Cloud "Live.txt") -Raw).Trim()
    $Full = (Get-Content -LiteralPath (Join-Path $Cloud "Full\FullVersion.txt") -Raw).Trim()
    if ($Live -ne $Full -or -not (Test-Path -LiteralPath (Join-Path $Cloud "Full\$Live\FullManifest.txt"))) {
        throw "E2E output pointers or manifest are invalid. Log: $EditorLog"
    }
    Write-Host "E2E PASS: editor button published $Live to $Cloud"
    $Succeeded = $true
}
finally {
    if ($Succeeded -and -not $KeepArtifacts) {
        if (-not $FixtureRoot.StartsWith($TempBase + '\', [StringComparison]::OrdinalIgnoreCase)) { throw "Unsafe fixture cleanup path." }
        Remove-Item -LiteralPath $FixtureRoot -Recurse -Force
    } else {
        Write-Host "E2E artifacts: $FixtureRoot"
    }
}
