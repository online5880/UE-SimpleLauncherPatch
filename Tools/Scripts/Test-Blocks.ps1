#Requires -Version 7
$ErrorActionPreference = 'Stop'
$LauncherDir = Join-Path (Split-Path $PSScriptRoot) 'Launcher'
$TestRoot = Join-Path ([IO.Path]::GetTempPath()) ('LauncherBlocks-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $TestRoot | Out-Null
Write-Host "Test artifacts: $TestRoot"
$Csc = Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
& $Csc /nologo /target:exe /main:BlockTests "/out:$TestRoot/BlockTests.exe" /r:System.Windows.Forms.dll /r:System.IO.Compression.dll /r:System.IO.Compression.FileSystem.dll (Join-Path $LauncherDir 'Launcher.cs') (Join-Path $LauncherDir 'BlockTests.cs')
if ($LASTEXITCODE -ne 0) { throw 'Test compilation failed' }
& "$TestRoot/BlockTests.exe"
if ($LASTEXITCODE -ne 0) { throw 'Block regression failed' }

$Stage = Join-Path $TestRoot 'Saved/StagedBuilds/Windows'
$Paks = Join-Path $Stage 'Fixture/Content/Paks'
$Cloud = Join-Path $TestRoot 'Cloud'
$Install = Join-Path $TestRoot 'Install'
New-Item -ItemType Directory -Path $Paks, $Install | Out-Null
[IO.File]::WriteAllText("$TestRoot/Fixture.uproject", '{"FileVersion":3,"EngineAssociation":"5.6"}')
[IO.File]::WriteAllText("$TestRoot/Game.cs", 'class Game { static void Main() {} }')
& $Csc /nologo /target:exe ("/out:" + (Join-Path $Stage 'Fixture.exe')) (Join-Path $TestRoot 'Game.cs')
if ($LASTEXITCODE -ne 0) { throw 'Fixture compilation failed' }
$Data = [byte[]]::new(12MB + 17)
$Data[4MB] = 1
$Data[8MB] = 2
$Data[-1] = 3
$Pak = Join-Path $Paks 'pakchunk1001-Windows.pak'
[IO.File]::WriteAllBytes($Pak, $Data)
& (Join-Path $PSScriptRoot 'New-SigningKey.ps1') -OutputDir "$TestRoot/Keys"
$Key = (Get-ChildItem "$TestRoot/Keys" -Filter *.private.xml).FullName
$Publish = @{ Project = "$TestRoot/Fixture.uproject"; SkipBuild = $true; Full = $true; CloudRoot = $Cloud; SigningKey = $Key; KeepFullVersions = 2 }
& (Join-Path $PSScriptRoot 'Publish-Patch.ps1') @Publish
Copy-Item "$Stage/*" $Install -Recurse
Copy-Item "$Cloud/Full/Launcher.exe", "$Cloud/Full/Launcher.ini", "$Cloud/Full/FullVersion.txt" $Install
Copy-Item "$Cloud/Full/1.0.1/FullManifest.txt" $Install
$Data[4MB] = 9
[IO.File]::WriteAllBytes($Pak, $Data)
& (Join-Path $PSScriptRoot 'Publish-Patch.ps1') @Publish

# Bind an unused loopback port and keep server/process ownership local to this check.
$Probe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
$Probe.Start()
$Port = $Probe.LocalEndpoint.Port
$Probe.Stop()
$Ini = [IO.File]::ReadAllText("$Install/Launcher.ini") -replace '(?m)^CdnUrl=.*', "CdnUrl=http://127.0.0.1:$Port"
[IO.File]::WriteAllText("$Install/Launcher.ini", $Ini)
$Python = (Get-Command python -ErrorAction Stop).Source
$Server = Start-Process $Python -ArgumentList "-m http.server $Port --bind 127.0.0.1 --directory `"$Cloud`"" -WindowStyle Hidden -PassThru -RedirectStandardError "$TestRoot/http.log"
try {
    $Ready = $false
    for ($i = 0; $i -lt 20; $i++) {
        try { $null = Invoke-WebRequest "http://127.0.0.1:$Port/Live.txt" -TimeoutSec 1; $Ready = $true; break }
        catch { Start-Sleep -Milliseconds 100 }
    }
    if (-not $Ready) { throw 'Test CDN did not start' }
    $Process = Start-Process "$Install/Launcher.exe" -ArgumentList '--play' -WindowStyle Hidden -PassThru
    if (-not $Process.WaitForExit(30000)) { Stop-Process -Id $Process.Id; throw 'Launcher update timed out; inspect artifacts' }
    $Log = Get-Content "$Install/Launcher.log" -Raw
    $ObjectRequests = @(Get-Content "$TestRoot/http.log" | Where-Object { $_ -match 'GET /Full/Objects/' })
    if ($ObjectRequests.Count -ne 1) { throw 'Expected exactly one block object HTTP request' }
    if ($Log -notmatch 'block update: .+, downloaded=4194304, reused=8388625' -or
        (Get-FileHash "$Install/Fixture/Content/Paks/pakchunk1001-Windows.pak").Hash -ne (Get-FileHash $Pak).Hash -or
        (Get-Content "$Install/FullVersion.txt") -ne '1.0.2') { throw "HTTP delta assertion failed: $Log" }
    Write-Host 'PASS: signed HTTP update downloaded 4MB of 12MB + 17 bytes; final SHA-256 matches'
    # Another publish prunes v1 while preserving every block referenced by retained versions.
    & (Join-Path $PSScriptRoot 'Publish-Patch.ps1') @Publish
    if (Test-Path "$Cloud/Full/1.0.1") { throw 'Old version was not pruned' }
    foreach ($Map in Get-ChildItem "$Cloud/Full/*/Blocks/*.txt") {
        foreach ($Line in Get-Content $Map | Select-Object -Skip 2) {
            $Hash = ($Line -split 'SHA256:')[1].ToLowerInvariant()
            $Object = "$Cloud/Full/Objects/$($Hash.Substring(0,2))/$Hash"
            if (-not (Test-Path $Object) -or (Get-FileHash $Object).Hash -ne $Hash) { throw 'Referenced block was pruned or corrupted' }
        }
    }
    Write-Host 'PASS: retained-version block objects survive garbage collection'
} finally { if (-not $Server.HasExited) { Stop-Process -Id $Server.Id } }
