#Requires -Version 7
[CmdletBinding()]
param(
    [string]$Project = "",
    [string]$EngineRoot = "",
    [string]$GameExe = "",
    [string]$Config = "Development",
    [switch]$SkipBuild,
    [switch]$Full,
    [switch]$ValidateOnly,
    [string]$CloudRoot = "",
    [string]$SigningKey = ""
)

$ErrorActionPreference = "Stop"

function Resolve-ProjectFile([string]$ExplicitProject) {
    if ($ExplicitProject) {
        $Item = Get-Item -LiteralPath $ExplicitProject -ErrorAction Stop
        if ($Item.PSIsContainer -or $Item.Extension -ne ".uproject") {
            throw "-Project must point to a .uproject file: $ExplicitProject"
        }
        return $Item.FullName
    }

    $Visited = @{}
    foreach ($Start in @((Get-Location).Path, $PSScriptRoot)) {
        $Directory = Get-Item -LiteralPath $Start
        while ($null -ne $Directory) {
            if (-not $Visited.ContainsKey($Directory.FullName)) {
                $Visited[$Directory.FullName] = $true
                $Found = @(Get-ChildItem -LiteralPath $Directory.FullName -Filter *.uproject -File -ErrorAction SilentlyContinue)
                if ($Found.Count -eq 1) { return $Found[0].FullName }
                if ($Found.Count -gt 1) {
                    throw "Multiple .uproject files found in $($Directory.FullName). Specify -Project."
                }
            }
            $Directory = $Directory.Parent
        }
    }

    throw "No .uproject found from the current directory or plugin directory. Specify -Project <path>."
}

function Resolve-EngineInstallation([string]$ProjectFile, [string]$ExplicitRoot) {
    if ($ExplicitRoot) {
        $RootItem = Get-Item -LiteralPath $ExplicitRoot -ErrorAction Stop
        $UatPath = Join-Path $RootItem.FullName "Engine\Build\BatchFiles\RunUAT.bat"
        if (-not (Test-Path -LiteralPath $UatPath -PathType Leaf)) {
            throw "RunUAT.bat not found under -EngineRoot: $($RootItem.FullName)"
        }
        return $RootItem.FullName
    }

    $ProjectData = Get-Content -LiteralPath $ProjectFile -Raw | ConvertFrom-Json
    $Association = [string]$ProjectData.EngineAssociation
    if (-not $Association) {
        throw "EngineAssociation is empty in $ProjectFile. Specify -EngineRoot."
    }

    $Candidates = [System.Collections.Generic.List[string]]::new()
    $LauncherData = "C:\ProgramData\Epic\UnrealEngineLauncher\LauncherInstalled.dat"
    if (Test-Path -LiteralPath $LauncherData -PathType Leaf) {
        $Installations = (Get-Content -LiteralPath $LauncherData -Raw | ConvertFrom-Json).InstallationList
        foreach ($Installation in $Installations) {
            if ($Installation.ArtifactId -eq "UE_$Association" -or $Installation.AppName -eq "UE_$Association") {
                $Candidates.Add([string]$Installation.InstallLocation)
            }
        }
    }

    $BuildsKey = "HKCU:\Software\Epic Games\Unreal Engine\Builds"
    if (Test-Path $BuildsKey) {
        $Builds = Get-ItemProperty $BuildsKey
        $Registered = $Builds.PSObject.Properties[$Association]
        if ($null -ne $Registered) { $Candidates.Add([string]$Registered.Value) }
    }

    $Candidates.Add("C:\Program Files\Epic Games\UE_$Association")
    $Candidates.Add("C:\UnrealEngine\UE_$Association")

    $Valid = @($Candidates |
        Where-Object { $_ -and (Test-Path -LiteralPath (Join-Path $_ "Engine\Build\BatchFiles\RunUAT.bat") -PathType Leaf) } |
        ForEach-Object { (Get-Item -LiteralPath $_).FullName } |
        Select-Object -Unique)

    if ($Valid.Count -eq 1) { return $Valid[0] }
    if ($Valid.Count -gt 1) {
        throw "Multiple Unreal Engine $Association installations found. Specify -EngineRoot."
    }
    throw "Unreal Engine $Association was not found. Specify -EngineRoot <UE install directory>."
}

function Resolve-StagedLayout([string]$ProjectRoot, [string]$ExplicitGameExe, [bool]$NeedGameExe) {
    $StagedBuilds = Join-Path $ProjectRoot "Saved\StagedBuilds"
    if (-not (Test-Path -LiteralPath $StagedBuilds -PathType Container)) {
        throw "Staged build not found: $StagedBuilds. Run without -SkipBuild first."
    }

    $PaksDirs = @(Get-ChildItem -LiteralPath $StagedBuilds -Directory -Recurse |
        Where-Object {
            $_.Name -eq "Paks" -and
            $_.Parent.Name -eq "Content" -and
            $_.FullName -notmatch '[\\/]Engine[\\/]Content[\\/]Paks$'
        })
    if ($PaksDirs.Count -eq 0) { throw "Content/Paks was not found under $StagedBuilds." }
    if ($PaksDirs.Count -gt 1) {
        throw "Multiple staged Content/Paks directories found. Remove stale staged builds and retry.`n$($PaksDirs.FullName -join "`n")"
    }

    $PaksDir = $PaksDirs[0]
    $StagedDir = $PaksDir.Parent.Parent.Parent.FullName
    $ResolvedGameExe = ""
    if ($NeedGameExe) {
        if ($ExplicitGameExe) {
            $ResolvedGameExe = [System.IO.Path]::GetFileName($ExplicitGameExe)
            if (-not (Test-Path -LiteralPath (Join-Path $StagedDir $ResolvedGameExe) -PathType Leaf)) {
                throw "Game executable not found at the staged root: $ResolvedGameExe"
            }
        } else {
            $Executables = @(Get-ChildItem -LiteralPath $StagedDir -Filter *.exe -File)
            if ($Executables.Count -eq 0) { throw "No game executable found in $StagedDir. Specify -GameExe." }
            if ($Executables.Count -gt 1) {
                throw "Multiple game executables found in $StagedDir. Specify -GameExe."
            }
            $ResolvedGameExe = $Executables[0].Name
        }
    }

    [PSCustomObject]@{
        PaksDir = $PaksDir.FullName
        StagedDir = $StagedDir
        GameExe = $ResolvedGameExe
    }
}

function Write-RsaSignature([string]$Path, [string]$PrivateKeyPath) {
    $Rsa = [System.Security.Cryptography.RSACryptoServiceProvider]::new()
    try {
        $Rsa.FromXmlString((Get-Content -LiteralPath $PrivateKeyPath -Raw))
        $Bytes = [System.IO.File]::ReadAllBytes($Path)
        $Signature = $Rsa.SignData($Bytes, [System.Security.Cryptography.CryptoConfig]::MapNameToOID("SHA256"))
        [System.IO.File]::WriteAllText(
            "$Path.sig",
            [Convert]::ToBase64String($Signature),
            [System.Text.UTF8Encoding]::new($false))
    } finally {
        $Rsa.PersistKeyInCsp = $false
        $Rsa.Dispose()
    }
}

$Project = Resolve-ProjectFile $Project
$ProjectRoot = Split-Path -Parent $Project
$ProjectName = [System.IO.Path]::GetFileNameWithoutExtension($Project)
$ResolvedEngineRoot = ""
if (-not $SkipBuild -or $ValidateOnly) {
    $ResolvedEngineRoot = Resolve-EngineInstallation $Project $EngineRoot
}

Write-Host "Project: $Project"
if ($ResolvedEngineRoot) { Write-Host "Engine:  $ResolvedEngineRoot" }
if ($ValidateOnly) {
    Write-Host "Automatic project and engine detection succeeded."
    return
}

if (-not $CloudRoot) { $CloudRoot = Join-Path $PSScriptRoot "Cloud" }
$CloudRoot = [System.IO.Path]::GetFullPath($CloudRoot, (Get-Location).Path)

if (-not $SkipBuild) {
    $UAT = Join-Path $ResolvedEngineRoot "Engine\Build\BatchFiles\RunUAT.bat"
    & $UAT BuildCookRun "-project=$Project" -noP4 -platform=Win64 "-clientconfig=$Config" `
        -cook -allmaps -build -stage -pak -compressed
    if ($LASTEXITCODE -ne 0) { throw "RunUAT failed with exit code $LASTEXITCODE" }
}

$Layout = Resolve-StagedLayout $ProjectRoot $GameExe $Full.IsPresent
$PaksDir = $Layout.PaksDir
$ChunkFiles = @(Get-ChildItem -LiteralPath $PaksDir -File |
    Where-Object { $_.Name -match '^pakchunk(\d+)-Windows\.(pak|utoc|ucas)$' -and [int]$Matches[1] -ge 1 } |
    Sort-Object Name)

if ($ChunkFiles.Count -eq 0) {
    throw "No patchable chunks found. Create a Primary Asset Label with Chunk ID >= 1; see CreatePatchLabel.py."
}

$NextNumber = 1
$LivePath = Join-Path $CloudRoot "Live.txt"
if (Test-Path -LiteralPath $LivePath -PathType Leaf) {
    $Previous = (Get-Content -LiteralPath $LivePath -Raw).Trim()
    if ($Previous -match '^1\.0\.(\d+)$') { $NextNumber = [int]$Matches[1] + 1 }
}
$BuildId = "1.0.$NextNumber"
Write-Host "Publishing BuildId: $BuildId"

$Sha1 = [System.Security.Cryptography.SHA1]::Create()
try {
    $Entries = @(foreach ($File in $ChunkFiles) {
        $Stream = [System.IO.File]::OpenRead($File.FullName)
        try { $HashBytes = $Sha1.ComputeHash($Stream) } finally { $Stream.Dispose() }
        $HashHex = ([System.BitConverter]::ToString($HashBytes)).Replace("-", "")
        $null = $File.Name -match '^pakchunk(\d+)-Windows\.'
        [PSCustomObject]@{
            Name = $File.Name
            Size = $File.Length
            Hash = $HashHex
            ChunkId = [int]$Matches[1]
        }
    })
} finally {
    $Sha1.Dispose()
}

$Lines = [System.Collections.Generic.List[string]]::new()
$Lines.Add("`$NUM_ENTRIES = $($Entries.Count)")
$Lines.Add("`$BUILD_ID = $BuildId")
foreach ($Entry in $Entries) {
    $Lines.Add("$($Entry.Name)`t$($Entry.Size)`tSHA1:$($Entry.Hash)`t$($Entry.ChunkId)`t/Windows/$($Entry.Name)")
}

$BuildDir = Join-Path $CloudRoot $BuildId
$BuildWinDir = Join-Path $BuildDir "Windows"
New-Item -ItemType Directory -Force -Path $BuildWinDir | Out-Null

$ManifestPath = Join-Path $BuildDir "BuildManifest-Windows.txt"
[System.IO.File]::WriteAllLines($ManifestPath, $Lines, [System.Text.UTF8Encoding]::new($false))
foreach ($Entry in $Entries) {
    Copy-Item -LiteralPath (Join-Path $PaksDir $Entry.Name) -Destination (Join-Path $BuildWinDir $Entry.Name) -Force
}
[System.IO.File]::WriteAllText($LivePath, $BuildId, [System.Text.UTF8Encoding]::new($false))

$Header = Get-Content -LiteralPath $ManifestPath -TotalCount 1
Write-Host "CDN root: $CloudRoot"
Write-Host "Manifest: $ManifestPath"
Write-Host "Published $($Entries.Count) file(s), Live.txt = $BuildId ($Header)"

if ($Full) {
    $LauncherDir = Join-Path (Split-Path -Parent $PSScriptRoot) "Launcher"
    $LauncherExe = Join-Path $LauncherDir "Launcher.exe"
    if (-not (Test-Path -LiteralPath $LauncherExe -PathType Leaf)) {
        & (Join-Path $LauncherDir "build.cmd")
        if ($LASTEXITCODE -ne 0) { throw "Launcher build failed with exit code $LASTEXITCODE" }
    }

    $FullDir = Join-Path $CloudRoot "Full"
    New-Item -ItemType Directory -Force -Path $FullDir | Out-Null

    $VersionDir = Join-Path $FullDir $BuildId
    $FilesDir = Join-Path $VersionDir "Files"
    if (Test-Path -LiteralPath $VersionDir) { Remove-Item -LiteralPath $VersionDir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $FilesDir | Out-Null
    foreach ($Item in Get-ChildItem -LiteralPath $Layout.StagedDir) {
        Copy-Item -LiteralPath $Item.FullName -Destination $FilesDir -Recurse -Force
    }
    Copy-Item -LiteralPath $LauncherExe -Destination (Join-Path $FilesDir "Launcher.exe") -Force

    $FullEntries = @(Get-ChildItem -LiteralPath $FilesDir -File -Recurse | ForEach-Object {
        [PSCustomObject]@{
            Path = $_.FullName.Substring($FilesDir.Length).TrimStart('\').Replace('\', '/')
            Size = $_.Length
            Hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
        }
    } | Sort-Object Path)
    $FullManifestLines = [System.Collections.Generic.List[string]]::new()
    $FullManifestLines.Add("`$VERSION = $BuildId")
    $FullManifestLines.Add("`$NUM_ENTRIES = $($FullEntries.Count)")
    foreach ($Entry in $FullEntries) {
        $FullManifestLines.Add("$($Entry.Path)`t$($Entry.Size)`tSHA256:$($Entry.Hash)")
    }
    $FullManifestPath = Join-Path $VersionDir "FullManifest.txt"
    [System.IO.File]::WriteAllLines($FullManifestPath, $FullManifestLines, [System.Text.UTF8Encoding]::new($false))

    $FullZip = Join-Path $FullDir "PatchGame.zip"
    if (Test-Path -LiteralPath $FullZip) { Remove-Item -LiteralPath $FullZip -Force }

    $StagedItems = @(Get-ChildItem -LiteralPath $Layout.StagedDir)
    if ($StagedItems.Count -eq 0) { throw "Staged build is empty: $($Layout.StagedDir)" }
    $TarArguments = @("-a", "-cf", $FullZip, "-C", $Layout.StagedDir) + @($StagedItems.Name)
    & tar.exe @TarArguments
    if ($LASTEXITCODE -ne 0) { throw "tar.exe failed with exit code $LASTEXITCODE" }

    $FullHash = (Get-FileHash -LiteralPath $FullZip -Algorithm SHA256).Hash.ToLowerInvariant()
    [System.IO.File]::WriteAllText("$FullZip.sha256", $FullHash, [System.Text.UTF8Encoding]::new($false))
    $ManifestPublicKey = ""
    if ($SigningKey) {
        $SigningKey = (Get-Item -LiteralPath $SigningKey -ErrorAction Stop).FullName
        Write-RsaSignature $FullManifestPath $SigningKey
        $Rsa = [System.Security.Cryptography.RSACryptoServiceProvider]::new()
        try {
            $Rsa.FromXmlString((Get-Content -LiteralPath $SigningKey -Raw))
            $ManifestPublicKey = $Rsa.ToXmlString($false)
        } finally {
            $Rsa.PersistKeyInCsp = $false
            $Rsa.Dispose()
        }
    }

    # Publish the version pointer only after its immutable manifest and signature are ready.
    $FullVersionPath = Join-Path $FullDir "FullVersion.txt"
    [System.IO.File]::WriteAllText(
        $FullVersionPath,
        $BuildId,
        [System.Text.UTF8Encoding]::new($false))
    if ($SigningKey) { Write-RsaSignature $FullVersionPath $SigningKey }

    Copy-Item -LiteralPath $LauncherExe -Destination (Join-Path $FullDir "Launcher.exe") -Force
    $LauncherIni = Get-Content -LiteralPath (Join-Path $LauncherDir "Launcher.ini") -Raw
    $LauncherIni = if ($LauncherIni -match '(?im)^GameExe\s*=') {
        $LauncherIni -replace '(?im)^GameExe\s*=.*$', "GameExe=$($Layout.GameExe)"
    } else { $LauncherIni.TrimEnd() + "`r`nGameExe=$($Layout.GameExe)`r`n" }
    $LauncherIni = if ($LauncherIni -match '(?im)^GameTitle\s*=') {
        $LauncherIni -replace '(?im)^GameTitle\s*=.*$', "GameTitle=$ProjectName"
    } else { $LauncherIni.TrimEnd() + "`r`nGameTitle=$ProjectName`r`n" }
    $LauncherIni = if ($LauncherIni -match '(?im)^ManifestPublicKey\s*=') {
        $LauncherIni -replace '(?im)^ManifestPublicKey\s*=.*$', "ManifestPublicKey=$ManifestPublicKey"
    } else { $LauncherIni.TrimEnd() + "`r`nManifestPublicKey=$ManifestPublicKey`r`n" }
    [System.IO.File]::WriteAllText(
        (Join-Path $FullDir "Launcher.ini"),
        $LauncherIni,
        [System.Text.UTF8Encoding]::new($false))

    $Size = "{0:N1} MB" -f ((Get-Item -LiteralPath $FullZip).Length / 1MB)
    Write-Host "Full build: $FullZip ($Size)"
    Write-Host "Game exe: $($Layout.GameExe)"
    Write-Host "SHA-256: $FullHash"
    Write-Host "FullVersion: $FullDir\FullVersion.txt = $BuildId"
    Write-Host "File manifest: $FullManifestPath ($($FullEntries.Count) files)"
    if ($SigningKey) { Write-Host "RSA signatures: enabled" }
}
