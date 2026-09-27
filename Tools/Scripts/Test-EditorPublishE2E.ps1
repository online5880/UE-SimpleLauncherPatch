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
$Python = (Get-Command python -ErrorAction Stop).Source
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

    $Install = Join-Path $FixtureRoot "Install"
    New-Item -ItemType Directory -Path $Install | Out-Null
    Copy-Item -LiteralPath (Join-Path $Cloud "Full\Launcher.exe"), (Join-Path $Cloud "Full\Launcher.ini") -Destination $Install
    $IniPath = Join-Path $Install "Launcher.ini"
    $Ini = Get-Content -LiteralPath $IniPath -Raw
    $GameExeMatch = [regex]::Match($Ini, '(?m)^GameExe\s*=\s*([^\r\n]+)')
    if (-not $GameExeMatch.Success) { throw "Launcher.ini has no GameExe." }
    $GameExe = $GameExeMatch.Groups[1].Value.Trim()
    $MapMatch = [regex]::Match((Get-Content -LiteralPath (Join-Path $FixtureRoot "Config\DefaultEngine.ini") -Raw), '(?m)^GameDefaultMap\s*=\s*(/Game/[^.\r\n]+)')
    if (-not $MapMatch.Success) { throw "DefaultEngine.ini has no project GameDefaultMap." }
    $ExpectedMap = $MapMatch.Groups[1].Value

    $PortProbe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $PortProbe.Start()
    $Port = $PortProbe.LocalEndpoint.Port
    $PortProbe.Stop()
    $Ini = $Ini -replace '(?m)^CdnUrl\s*=.*$', "CdnUrl=http://127.0.0.1:$Port"
    [IO.File]::WriteAllText($IniPath, $Ini)
    $HttpLog = Join-Path $FixtureRoot "LocalCDN.log"
    $Server = Start-Process $Python -ArgumentList @(
        ('"' + (Join-Path $PSScriptRoot "Throttle-CDN.py") + '"'), "128", ('"' + $Cloud + '"'), "$Port"
    ) -WindowStyle Hidden -PassThru -RedirectStandardError $HttpLog
    try {
        $Ready = $false
        for ($Attempt = 0; $Attempt -lt 30; $Attempt++) {
            try { $null = Invoke-WebRequest "http://127.0.0.1:$Port/Full/FullVersion.txt" -TimeoutSec 1; $Ready = $true; break }
            catch { Start-Sleep -Milliseconds 200 }
        }
        if (-not $Ready) { throw "Local CDN did not start: $HttpLog" }

        $LaunchStartedUtc = [datetime]::UtcNow
        $Launcher = Start-Process (Join-Path $Install "Launcher.exe") -ArgumentList "--play" -WindowStyle Hidden -PassThru
        if (-not $Launcher.WaitForExit(300000)) { Stop-Process -Id $Launcher.Id; throw "Launcher timed out: $Install\Launcher.log" }
        $LauncherLog = Join-Path $Install "Launcher.log"
        if (-not (Test-Path -LiteralPath $LauncherLog) -or
            (Get-Content -LiteralPath $LauncherLog -Raw) -notmatch 'game started' -or
            (Get-Content -LiteralPath (Join-Path $Install "FullVersion.txt") -Raw).Trim() -ne $Live -or
            -not (Test-Path -LiteralPath (Join-Path $Install $GameExe))) {
            throw "Launcher did not install and start $GameExe : $LauncherLog"
        }

        $ProjectName = [IO.Path]::GetFileNameWithoutExtension($FixtureProject)
        $GameLog = Join-Path $Install "$ProjectName\Saved\Logs\$ProjectName.log"
        $MapLoaded = $false
        $EarliestLogStamp = $LaunchStartedUtc.AddSeconds(-2).ToString('yyyy.MM.dd-HH.mm.ss')
        for ($Attempt = 0; $Attempt -lt 120; $Attempt++) {
            if (Test-Path -LiteralPath $GameLog) {
                $Loads = [regex]::Matches((Get-Content -LiteralPath $GameLog -Raw),
                    '(?m)^\[(?<time>\d{4}\.\d{2}\.\d{2}-\d{2}\.\d{2}\.\d{2}):[^\r\n]*UEngine::LoadMap Load map complete (?<map>/Game/[^\s\r\n]+)')
                foreach ($Load in $Loads) {
                    if ($Load.Groups['map'].Value -eq $ExpectedMap -and
                        [string]::CompareOrdinal($Load.Groups['time'].Value, $EarliestLogStamp) -ge 0) {
                        $MapLoaded = $true
                        break
                    }
                }
                if ($MapLoaded) { break }
            }
            Start-Sleep -Seconds 1
        }
        if (-not $MapLoaded) { throw "Game did not load $ExpectedMap : $GameLog" }
        $InstallPrefix = [IO.Path]::GetFullPath($Install).TrimEnd('\') + '\'
        $GameProcesses = @(Get-CimInstance Win32_Process | Where-Object {
            $_.ExecutablePath -and $_.ExecutablePath.StartsWith($InstallPrefix, [StringComparison]::OrdinalIgnoreCase)
        })
        if ($GameProcesses.Count -eq 0) { throw "Game exited immediately after loading $ExpectedMap : $GameLog" }
        Write-Host "E2E PASS: launcher installed $Live and game loaded $ExpectedMap"
    }
    finally {
        if ($Server -and -not $Server.HasExited) { Stop-Process -Id $Server.Id }
        $InstallPrefix = [IO.Path]::GetFullPath($Install).TrimEnd('\') + '\'
        Get-CimInstance Win32_Process | Where-Object {
            $_.ExecutablePath -and $_.ExecutablePath.StartsWith($InstallPrefix, [StringComparison]::OrdinalIgnoreCase)
        } | ForEach-Object { Stop-Process -Id $_.ProcessId -ErrorAction SilentlyContinue }
    }
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
