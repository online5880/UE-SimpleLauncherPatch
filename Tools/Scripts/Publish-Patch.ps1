#Requires -Version 7
[CmdletBinding()]
param(
    [string]$Config = "Development",
    [switch]$SkipBuild,
    [switch]$Full,
    [string]$CloudRoot = ""
)

$ErrorActionPreference = "Stop"

# 1. Paths
$Root = Split-Path -Parent $PSScriptRoot
$Project = Join-Path $Root "PatchGame.uproject"
if (-not $CloudRoot) { $CloudRoot = Join-Path $PSScriptRoot "Cloud" }

# 2. Build + cook + stage
if (-not $SkipBuild) {
    $UAT = "C:\Program Files\Epic Games\UE_5.6\Engine\Build\BatchFiles\RunUAT.bat"
    & $UAT BuildCookRun -project="$Project" -noP4 -platform=Win64 -clientconfig="$Config" `
        -cook -allmaps -build -stage -pak -compressed
    if ($LASTEXITCODE -ne 0) {
        throw "RunUAT failed with exit code $LASTEXITCODE"
    }
}

# 3. Collect patchable chunk files (chunk >= 1; pakchunk0 stays embedded)
$PaksDir = Join-Path $Root "Saved\StagedBuilds\Windows\PatchGame\Content\Paks"
$ChunkFiles = Get-ChildItem -Path $PaksDir -File |
    Where-Object { $_.Name -match '^pakchunk(\d+)-Windows\.(pak|utoc|ucas)$' -and [int]$Matches[1] -ge 1 } |
    Sort-Object Name

if ($ChunkFiles.Count -eq 0) {
    Write-Warning "No patchable chunks exist (need a Primary Asset Label with Chunk ID >= 1; see Patch\CreatePatchLabel.py)."
    exit 1
}
# 4. BuildId: previous Live.txt suffix + 1, else 1.0.1
$NextNumber = 1
$LivePath = Join-Path $CloudRoot "Live.txt"
if (Test-Path $LivePath) {
    $Prev = (Get-Content $LivePath -Raw).Trim()
    if ($Prev -match '^1\.0\.(\d+)$') {
        $NextNumber = [int]$Matches[1] + 1
    }
}
$BuildId = "1.0.$NextNumber"
Write-Host "Publishing BuildId: $BuildId"

# 5. Per-file hash (streamed SHA1, uppercase 40-hex)
$Sha1 = [System.Security.Cryptography.SHA1]::Create()
$Entries = foreach ($File in $ChunkFiles) {
    $Stream = [System.IO.File]::OpenRead($File.FullName)
    try {
        $HashBytes = $Sha1.ComputeHash($Stream)
    } finally { $Stream.Dispose() }
    $HashHex = ([System.BitConverter]::ToString($HashBytes)).Replace("-", "")
    $null = $File.Name -match '^pakchunk(\d+)-Windows\.'
    [PSCustomObject]@{
        Name = $File.Name
        Size = $File.Length
        Hash = $HashHex
        ChunkId = [int]$Matches[1]
    }
}
$Sha1.Dispose()

# 6. Manifest (tab-separated, UTF-8 without BOM; ChunkDownloader parser format)
$Lines = [System.Collections.Generic.List[string]]::new()
$Lines.Add("`$NUM_ENTRIES = $($Entries.Count)")
$Lines.Add("`$BUILD_ID = $BuildId")
foreach ($E in $Entries) {
    $Lines.Add("$($E.Name)`t$($E.Size)`tSHA1:$($E.Hash)`t$($E.ChunkId)`t/Windows/$($E.Name)")
}

$BuildDir = Join-Path $CloudRoot $BuildId
$BuildWinDir = Join-Path $BuildDir "Windows"
New-Item -ItemType Directory -Force -Path $BuildWinDir | Out-Null

$ManifestPath = Join-Path $BuildDir "BuildManifest-Windows.txt"
[System.IO.File]::WriteAllLines($ManifestPath, $Lines, [System.Text.UTF8Encoding]::new($false))

# Copy pak files into the build folder (same-named files are overwritten)
foreach ($E in $Entries) {
    Copy-Item -Path (Join-Path $PaksDir $E.Name) -Destination (Join-Path $BuildWinDir $E.Name) -Force
}

# Refresh Live.txt (UTF-8 without BOM)
[System.IO.File]::WriteAllText($LivePath, $BuildId, [System.Text.UTF8Encoding]::new($false))

# Sanity: re-read manifest header
$Header = (Get-Content $ManifestPath -TotalCount 1)
Write-Host "CDN root: $CloudRoot"
Write-Host "Manifest: $ManifestPath"
Write-Host "Published $($Entries.Count) file(s), Live.txt = $BuildId ($Header)"

# 7. Optional: publish full build for the launcher (-Full)
if ($Full) {
    $StagedDir = Join-Path $Root "Saved\StagedBuilds\Windows"
    if (-not (Test-Path (Join-Path $StagedDir "TP_ThirdPerson.exe"))) {
        Write-Warning "Staged build not found: $StagedDir (skipped -Full steps)"
    } else {
        $FullDir = Join-Path $CloudRoot "Full"
        New-Item -ItemType Directory -Force -Path $FullDir | Out-Null

        # delete existing zip first (stale content)
        $FullZip = Join-Path $FullDir "PatchGame.zip"
        if (Test-Path $FullZip) { Remove-Item $FullZip -Force }

        # zip root = staged build root (Engine\ + PatchGame\ + TP_ThirdPerson.exe at top level),
        # matching an extracted install dir. tar.exe (bsdtar) handles long paths Compress-Archive chokes on.
        tar.exe -a -cf $FullZip -C $StagedDir Engine PatchGame TP_ThirdPerson.exe
        if ($LASTEXITCODE -ne 0) { throw "tar.exe failed with exit code $LASTEXITCODE" }

        $FullHash = (Get-FileHash -LiteralPath $FullZip -Algorithm SHA256).Hash.ToLowerInvariant()
        [System.IO.File]::WriteAllText(
            "$FullZip.sha256",
            $FullHash,
            [System.Text.UTF8Encoding]::new($false))

        # FullVersion.txt: same BuildId as the manifest (UTF-8 no BOM, no trailing newline)
        [System.IO.File]::WriteAllText(
            (Join-Path $FullDir "FullVersion.txt"),
            $BuildId,
            [System.Text.UTF8Encoding]::new($false))

        foreach ($Name in @("Launcher.exe", "Launcher.ini")) {
            $Src = Join-Path $Root "Launcher\$Name"
            if (Test-Path $Src) {
                Copy-Item -Path $Src -Destination (Join-Path $FullDir $Name) -Force
            }
        }

        $Size = "{0:N1} MB" -f ((Get-Item $FullZip).Length / 1MB)
        Write-Host "Full build: $FullZip ($Size)"
        Write-Host "SHA-256: $FullHash"
        Write-Host "FullVersion: $FullDir\FullVersion.txt = $BuildId"
    }
}
