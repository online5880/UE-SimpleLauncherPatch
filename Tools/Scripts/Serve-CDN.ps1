[CmdletBinding()]
param(
    [string]$CloudRoot = "",
    [int]$Port = 8080,
    [switch]$NoPause
)

# PS 5.1-compatible (no #Requires). Serves Patch\Cloud as a static CDN and verifies it is reachable.

if (-not $CloudRoot) { $CloudRoot = Join-Path $PSScriptRoot "Cloud" }
if (-not (Test-Path $CloudRoot)) {
    New-Item -ItemType Directory -Force -Path $CloudRoot | Out-Null
}

function Wait-Enter { if (-not $NoPause) { Read-Host "Enter 키를 누르면 창이 닫힙니다 (서버는 계속 실행됨)" | Out-Null } }

# already serving?
$Existing = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
if ($Existing) {
    Write-Host "포트 $Port 사용 중 (PID $($Existing[0].OwningProcess)). 이미 CDN이 실행 중일 가능성이 높습니다."
    Write-Host "확인: http://127.0.0.1:$Port/Live.txt"
    Wait-Enter
    exit 0
}

$Python = Get-Command python -ErrorAction SilentlyContinue
if (-not $Python) {
    Write-Error "python 없음. 아무 정적 서버든 Cloud 폴더 루트로 실행하세요: $CloudRoot"
    Wait-Enter
    exit 1
}

Start-Process -FilePath $Python.Source `
    -ArgumentList @("-m", "http.server", "$Port", "--directory", $CloudRoot) `
    -WindowStyle Hidden

# health probe — the hidden python can die silently (e.g. port race), so verify for real
Start-Sleep -Seconds 2
try {
    $Resp = Invoke-WebRequest "http://127.0.0.1:$Port/Live.txt" -UseBasicParsing -TimeoutSec 5
    Write-Host "CDN OK: http://127.0.0.1:$Port/Live.txt -> $($Resp.Content.Trim())"
    Write-Host "CDN root: $CloudRoot"
    Write-Host "서버는 백그라운드 python 프로세스로 실행 중입니다. 중지: Stop-Process -Name python"
} catch {
    Write-Warning "서버 기동 확인 실패: $_"
}

Wait-Enter
