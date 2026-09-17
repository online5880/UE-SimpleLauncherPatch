#Requires -Version 7
[CmdletBinding()]
param(
    [string]$Project = "",
    [string]$EngineRoot = "",
    [string]$GameExe = "",
    [string]$Config = "Development",
    [switch]$SkipBuild,
    [switch]$Full,
    [switch]$LegacyFiles,
    [switch]$LegacyZip,
    [switch]$ValidateOnly,
    [switch]$EnforceHealthCheck,
    [string]$CloudRoot = "",
    [string]$SigningKey = "",
    [ValidateRange(1, 100)]
    [int]$KeepFullVersions = 3
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
# 발행자 PC 전용 사전 점검. TYPESAFE_API_KEY 가 없으면 조용히 건너뛴다(플러그인 런타임과 무관).
# 경고 전용이 기본이고, -EnforceHealthCheck 를 주어야 실제로 발행을 막는다. Live.txt 를 쓰기 직전에 둔다.
# ponytail: 자식 프로세스로 돌린다. 같은 세션에서 & 로 부르면 자식 스크립트의 exit 이 프로세스 코드로 올라오지 않는다.
$HealthArgs = @("-NoProfile", "-File", (Join-Path $PSScriptRoot "Test-BuildHealth.ps1"),
    "-LogPath", (Join-Path $Layout.StagedDir "$ProjectName\Saved\Logs\$ProjectName.log"),
    "-BuildId", $BuildId,
    "-OutDir", (Join-Path $ProjectRoot "Saved\HealthChecks"))
if ($EnforceHealthCheck) { $HealthArgs += "-Enforce" }
& (Join-Path $PSHOME "pwsh.exe") @HealthArgs
if ($LASTEXITCODE -ne 0) {
    throw "Build health check blocked publishing of $BuildId. See $ProjectRoot\Saved\HealthChecks."
}

[System.IO.File]::WriteAllText($LivePath, $BuildId, [System.Text.UTF8Encoding]::new($false))

$Header = Get-Content -LiteralPath $ManifestPath -TotalCount 1
Write-Host "CDN root: $CloudRoot"
Write-Host "Manifest: $ManifestPath"
Write-Host "Published $($Entries.Count) file(s), Live.txt = $BuildId ($Header)"

if ($Full) {
    $LauncherDir = Join-Path (Split-Path -Parent $PSScriptRoot) "Launcher"
    $LauncherExe = Join-Path $LauncherDir "Launcher.exe"
    if (-not (Test-Path -LiteralPath $LauncherExe -PathType Leaf) -or
        (Get-Item (Join-Path $LauncherDir "Launcher.cs")).LastWriteTimeUtc -gt (Get-Item $LauncherExe).LastWriteTimeUtc) {
        & (Join-Path $LauncherDir "build.cmd")
        if ($LASTEXITCODE -ne 0) { throw "Launcher build failed with exit code $LASTEXITCODE" }
    }

    $FullDir = Join-Path $CloudRoot "Full"
    New-Item -ItemType Directory -Force -Path $FullDir | Out-Null

    $VersionDir = Join-Path $FullDir $BuildId
    $ObjectsDir = Join-Path $FullDir "Objects"
    if (Test-Path -LiteralPath $VersionDir) { Remove-Item -LiteralPath $VersionDir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $VersionDir, $ObjectsDir | Out-Null

    $FullEntries = @(Get-ChildItem -LiteralPath $Layout.StagedDir -File -Recurse | ForEach-Object {
        [PSCustomObject]@{
            Path = $_.FullName.Substring($Layout.StagedDir.Length).TrimStart('\').Replace('\', '/')
            Source = $_.FullName
            Size = $_.Length
            Hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
        }
    })
    $FullEntries = @($FullEntries | Where-Object { $_.Path -ne "Launcher.exe" }) + @(
        [PSCustomObject]@{
            Path = "Launcher.exe"
            Source = $LauncherExe
            Size = (Get-Item -LiteralPath $LauncherExe).Length
            Hash = (Get-FileHash -LiteralPath $LauncherExe -Algorithm SHA256).Hash
        })
    $FullEntries = @($FullEntries | Sort-Object Path)

    $NewObjects = 0
    $ReusedObjects = 0
    foreach ($Entry in $FullEntries) {
        $ObjectDir = Join-Path $ObjectsDir $Entry.Hash.Substring(0, 2).ToLowerInvariant()
        $ObjectPath = Join-Path $ObjectDir $Entry.Hash.ToLowerInvariant()
        New-Item -ItemType Directory -Force -Path $ObjectDir | Out-Null
        $ObjectValid = (Test-Path -LiteralPath $ObjectPath -PathType Leaf) -and
            (Get-Item -LiteralPath $ObjectPath).Length -eq $Entry.Size -and
            (Get-FileHash -LiteralPath $ObjectPath -Algorithm SHA256).Hash -eq $Entry.Hash
        if ($ObjectValid) {
            $ReusedObjects++
        } else {
            Copy-Item -LiteralPath $Entry.Source -Destination $ObjectPath -Force
            if ((Get-FileHash -LiteralPath $ObjectPath -Algorithm SHA256).Hash -ne $Entry.Hash) {
                Remove-Item -LiteralPath $ObjectPath -Force
                throw "Object copy verification failed: $($Entry.Path)"
            }
            $NewObjects++
        }
    }
    $FullManifestLines = [System.Collections.Generic.List[string]]::new()
    $FullManifestLines.Add("`$VERSION = $BuildId")
    $FullManifestLines.Add("`$NUM_ENTRIES = $($FullEntries.Count)")
    foreach ($Entry in $FullEntries) {
        $FullManifestLines.Add("$($Entry.Path)`t$($Entry.Size)`tSHA256:$($Entry.Hash)")
    }
    $FullManifestPath = Join-Path $VersionDir "FullManifest.txt"
    [System.IO.File]::WriteAllLines($FullManifestPath, $FullManifestLines, [System.Text.UTF8Encoding]::new($false))

    # ponytail: fixed offsets reuse aligned blocks; use content-defined chunks if cooked offsets shift heavily.
    $BlockMaps = Join-Path $VersionDir "Blocks"
    foreach ($Entry in $FullEntries | Where-Object { $_.Size -gt 4MB -and $_.Path -match '\.(pak|ucas)$' }) {
        New-Item -ItemType Directory -Force -Path $BlockMaps | Out-Null
        $BlockLines = [System.Collections.Generic.List[string]]::new()
        $BlockLines.Add("`$VERSION = $($Entry.Hash)")
        $BlockLines.Add("`$NUM_ENTRIES = $([long][Math]::Ceiling($Entry.Size / 4MB))")
        $InputStream = [IO.File]::OpenRead($Entry.Source)
        $Buffer = [byte[]]::new(4MB)
        $Index = 0
        try {
            while ($InputStream.Position -lt $InputStream.Length) {
                $Count = 0
                while ($Count -lt $Buffer.Length) {
                    $Read = $InputStream.Read($Buffer, $Count, $Buffer.Length - $Count)
                    if ($Read -eq 0) { break }
                    $Count += $Read
                }
                $Sha = [Security.Cryptography.SHA256]::Create()
                try { $Hash = [Convert]::ToHexString($Sha.ComputeHash($Buffer, 0, $Count)) } finally { $Sha.Dispose() }
                $BlockDir = Join-Path $ObjectsDir $Hash.Substring(0, 2).ToLowerInvariant()
                $BlockPath = Join-Path $BlockDir $Hash.ToLowerInvariant()
                New-Item -ItemType Directory -Force -Path $BlockDir | Out-Null
                if (-not (Test-Path -LiteralPath $BlockPath) -or (Get-FileHash -LiteralPath $BlockPath).Hash -ne $Hash) {
                    $OutputStream = [IO.File]::Create($BlockPath)
                    try { $OutputStream.Write($Buffer, 0, $Count) } finally { $OutputStream.Dispose() }
                }
                $BlockLines.Add("$Index`t$Count`tSHA256:$Hash")
                $Index++
            }
        } finally { $InputStream.Dispose() }
        if ((Get-FileHash -LiteralPath $Entry.Source).Hash -ne $Entry.Hash) { throw "Staged file changed during block publishing: $($Entry.Path)" }
        $BlockMap = Join-Path $BlockMaps "$($Entry.Hash.ToLowerInvariant()).txt"
        [IO.File]::WriteAllLines($BlockMap, $BlockLines, [Text.UTF8Encoding]::new($false))
        if ($SigningKey) { Write-RsaSignature $BlockMap $SigningKey }
    }

    if ($LegacyFiles) {
        $FilesDir = Join-Path $VersionDir "Files"
        foreach ($Entry in $FullEntries) {
            $ObjectPath = Join-Path (Join-Path $ObjectsDir $Entry.Hash.Substring(0, 2).ToLowerInvariant()) $Entry.Hash.ToLowerInvariant()
            $LegacyPath = Join-Path $FilesDir $Entry.Path.Replace('/', '\')
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $LegacyPath) | Out-Null
            try { New-Item -ItemType HardLink -Path $LegacyPath -Target $ObjectPath -ErrorAction Stop | Out-Null }
            catch { Copy-Item -LiteralPath $ObjectPath -Destination $LegacyPath -Force }
        }
    }

    $FullZip = Join-Path $FullDir "PatchGame.zip"
    $FullHash = ""
    if ($LegacyZip) {
        if (Test-Path -LiteralPath $FullZip) { Remove-Item -LiteralPath $FullZip -Force }
        $StagedItems = @(Get-ChildItem -LiteralPath $Layout.StagedDir)
        if ($StagedItems.Count -eq 0) { throw "Staged build is empty: $($Layout.StagedDir)" }
        $TarArguments = @("-a", "-cf", $FullZip, "-C", $Layout.StagedDir) + @($StagedItems.Name)
        & tar.exe @TarArguments
        if ($LASTEXITCODE -ne 0) { throw "tar.exe failed with exit code $LASTEXITCODE" }
        $FullHash = (Get-FileHash -LiteralPath $FullZip -Algorithm SHA256).Hash.ToLowerInvariant()
        [System.IO.File]::WriteAllText("$FullZip.sha256", $FullHash, [System.Text.UTF8Encoding]::new($false))
    }
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

    $VersionDirs = @(Get-ChildItem -LiteralPath $FullDir -Directory |
        Where-Object { $_.Name -match '^\d+\.\d+\.\d+$' } |
        Sort-Object { [version]$_.Name } -Descending)
    $RetainedVersions = @($VersionDirs | Select-Object -First $KeepFullVersions)
    $ReferencedObjects = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($Retained in $RetainedVersions) {
        $RetainedManifest = Join-Path $Retained.FullName "FullManifest.txt"
        if (-not (Test-Path -LiteralPath $RetainedManifest -PathType Leaf)) {
            throw "Cannot safely clean objects because a retained manifest is missing: $RetainedManifest"
        }
        $ExpectedEntries = -1
        $FoundEntries = 0
        foreach ($Line in Get-Content -LiteralPath $RetainedManifest) {
            if ($Line -match '^\$NUM_ENTRIES\s*=\s*(\d+)$') { $ExpectedEntries = [int]$Matches[1] }
            elseif ($Line -match '\tSHA256:([A-Fa-f0-9]{64})$') {
                $null = $ReferencedObjects.Add($Matches[1])
                $FoundEntries++
            }
        }
        if ($ExpectedEntries -lt 0 -or $FoundEntries -ne $ExpectedEntries) {
            throw "Cannot safely clean objects because a retained manifest is invalid: $RetainedManifest"
        }
        $RetainedBlocks = Join-Path $Retained.FullName "Blocks"
        if (Test-Path -LiteralPath $RetainedBlocks) {
            foreach ($Map in Get-ChildItem -LiteralPath $RetainedBlocks -Filter *.txt -File) {
                $MapLines = @(Get-Content -LiteralPath $Map.FullName)
                if ($MapLines.Count -lt 3 -or $MapLines[1] -notmatch '^\$NUM_ENTRIES = (\d+)$') { throw "Invalid block map: $($Map.FullName)" }
                if ([long]$Matches[1] -ne $MapLines.Count - 2) { throw "Incomplete block map: $($Map.FullName)" }
                foreach ($Line in $MapLines | Select-Object -Skip 2) {
                    if ($Line -notmatch '^\d+\t[1-9]\d*\tSHA256:([A-Fa-f0-9]{64})$') { throw "Invalid block entry: $($Map.FullName)" }
                    $null = $ReferencedObjects.Add($Matches[1])
                }
            }
        }
    }
    foreach ($OldVersion in @($VersionDirs | Select-Object -Skip $KeepFullVersions)) {
        Remove-Item -LiteralPath $OldVersion.FullName -Recurse -Force
    }
    $PrunedObjects = 0
    foreach ($Object in @(Get-ChildItem -LiteralPath $ObjectsDir -File -Recurse)) {
        if (-not $ReferencedObjects.Contains($Object.Name)) {
            Remove-Item -LiteralPath $Object.FullName -Force
            $PrunedObjects++
        }
    }
    foreach ($ObjectDir in @(Get-ChildItem -LiteralPath $ObjectsDir -Directory)) {
        if (-not (Get-ChildItem -LiteralPath $ObjectDir.FullName)) { Remove-Item -LiteralPath $ObjectDir.FullName -Force }
    }

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

    if ($LegacyZip) {
        $Size = "{0:N1} MB" -f ((Get-Item -LiteralPath $FullZip).Length / 1MB)
        Write-Host "Legacy full ZIP: $FullZip ($Size), SHA-256: $FullHash"
    }
    Write-Host "Game exe: $($Layout.GameExe)"
    Write-Host "FullVersion: $FullDir\FullVersion.txt = $BuildId"
    Write-Host "File manifest: $FullManifestPath ($($FullEntries.Count) files)"
    Write-Host "Objects: $NewObjects new, $ReusedObjects reused, $PrunedObjects pruned"
    Write-Host "Retained full versions: $($RetainedVersions.Count) / $KeepFullVersions"
    if ($LegacyFiles) { Write-Host "Legacy per-version Files: enabled" }
    if ($SigningKey) { Write-Host "RSA signatures: enabled" }
}
