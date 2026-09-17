#Requires -Version 7
<#
.SYNOPSIS
  TypeSafe(Jev)로 쿡/런타임 로그를 판정해 "이 빌드를 배포해도 되는가"를 본다.
.DESCRIPTION
  발행자(개발자) PC에서만 쓰는 검사 도구다. 플러그인 런타임(Source/Config/uplugin)에는
  어떤 의존성도 넣지 않는다. TYPESAFE_API_KEY 가 없으면 아무것도 하지 않고 건너뛴다.

  기본은 경고 전용이다. -Enforce 를 주어야만 판정이 걸렸을 때 종료코드 1을 낸다.
  API 오류는 -Enforce 여부와 무관하게 발행을 막지 않는다(fail-open): 판정 모델은
  보조 신호이고, 외부 장애로 발행이 멈추는 쪽이 더 나쁘다.
.EXAMPLE
  ./Test-BuildHealth.ps1 -LogPath <스테이징런타임로그> -BuildId 1.0.4
.EXAMPLE
  ./Test-BuildHealth.ps1 -SelfTest
#>
[CmdletBinding()]
param(
    [string]$LogPath = "",
    [string]$OutDir = "",
    [string]$BuildId = "",
    [switch]$Enforce,
    [switch]$SelfTest,
    # ponytail: 문턱은 2026-09-17 실측 3건에서 나온 값이다. 표본이 쌓이면 다시 잡아야 한다.
    [double]$MinDefectProbability = 0.9,
    [double]$MinConfidence = 0.8,
    # ponytail: 로그 전문이 아니라 꼬리만 넣는다. state+questions 예산이 약 32k 토큰이다.
    [int]$TailLines = 200,
    [string]$Model = "jev-latest",
    [string]$BaseUrl = "https://api.typesafe.ai/v1/systemone"
)

$ErrorActionPreference = "Stop"

# 우리 환경에서 무해하다고 확인된 항목. 여기 없는 것은 전부 판정 대상으로 남는다.
# 이 목록은 우리 정책이므로 실제로 무시해도 되는지 확인이 필요하다.
$DefaultBenignFindings = @(
    "Graphics/CPU profiler DLLs that are not installed on the machine (aqProf, VtuneApi, WinPixGpuCapturer)"
    "Unreal Trace Server binary or trace data being unavailable"
    "Nanite legacy IO path performance warning"
    "The local patch CDN at 127.0.0.1:8080 being unreachable, so the game fell back to the already installed build"
)

function Test-GateTripped {
    param($Answer, [double]$MinProb, [double]$MinConf)
    if ($null -eq $Answer) { return $false }
    $Choice = Get-FieldValue $Answer "choice"
    if (-not $Choice -or $Choice -eq "none") { return $false }
    $Prob = [double](Get-FieldValue (Get-FieldValue $Answer "probabilities") $Choice)
    $Conf = [double](Get-FieldValue $Answer "confidence")
    return ($Prob -ge $MinProb) -and ($Conf -ge $MinConf)
}

# answers 는 API 응답에서 오면 PSCustomObject, SelfTest 에서 오면 hashtable 이다. 둘 다 읽는다.
function Get-FieldValue {
    param($Obj, [string]$Name)
    if ($null -eq $Obj) { return $null }
    if ($Obj -is [System.Collections.IDictionary]) { return $Obj[$Name] }
    $Prop = $Obj.PSObject.Properties[$Name]
    if ($Prop) { return $Prop.Value }
    return $null
}

if ($SelfTest) {
    # 2026-09-17 실측값. 판정 로직이나 문턱을 건드리면 여기서 깨진다.
    $Cases = @(
        @{ Name = "BAD(missing 18 assets)"; Expect = $true
           Answer = @{ choice = "missing_asset"; confidence = 0.99; probabilities = @{ missing_asset = 1.0; none = 0.0 } } }
        @{ Name = "GOOD(LoadErrors 0)"; Expect = $false
           Answer = @{ choice = "none"; confidence = 0.50; probabilities = @{ none = 0.60; missing_asset = 0.35 } } }
        @{ Name = "OK-but-detected(LoadErrors 0)"; Expect = $false
           Answer = @{ choice = "missing_asset"; confidence = 0.63; probabilities = @{ missing_asset = 0.71; none = 0.27 } } }
    )
    $Failed = 0
    foreach ($Case in $Cases) {
        $Tripped = Test-GateTripped -Answer $Case.Answer -MinProb $MinDefectProbability -MinConf $MinConfidence
        $Ok = ($Tripped -eq $Case.Expect)
        if (-not $Ok) { $Failed++ }
        "{0} {1,-30} tripped={2} expect={3}" -f $(if ($Ok) { "PASS" } else { "FAIL" }), $Case.Name, $Tripped, $Case.Expect
    }
    if ($Failed) { "SelfTest FAILED ($Failed case(s))" ; exit 1 }
    "SelfTest OK ($($Cases.Count) cases)"
    exit 0
}

if (-not $LogPath) { throw "-LogPath is required (or use -SelfTest)." }

# Codex/부모 프로세스가 환경변수를 물려받지 못한 경우가 있어 User 스코프까지 본다.
$Key = $env:TYPESAFE_API_KEY
if (-not $Key) { $Key = [Environment]::GetEnvironmentVariable("TYPESAFE_API_KEY", "User") }
if (-not $Key) { Write-Host "TypeSafe health check: SKIPPED (TYPESAFE_API_KEY not set)" ; exit 0 }

# 로그가 없다고 발행을 막지 않는다. 아직 한 번도 실행하지 않았다는 뜻일 뿐이다.
$LogItem = Get-Item -LiteralPath $LogPath -ErrorAction SilentlyContinue
if (-not $LogItem) { Write-Host "TypeSafe health check: SKIPPED (no runtime log at $LogPath)"; exit 0 }
$Tail = (Get-Content -LiteralPath $LogItem.FullName -Tail $TailLines) -join "`n"

$Questions = [ordered]@{
    content_defect_class = [ordered]@{
        type   = "choice"
        instructions = 'Ignoring everything listed in `known_benign_findings`, what is the dominant defect in the shipped build content, based only on `log_tail`?'
        criteria = [ordered]@{
            missing_asset = "Referenced packages/assets were not available or failed to load"
            path_conflict = "Assets resolve to unexpected mount paths or wrong package location"
            shader        = "Shader or PSO compilation failure"
            plugin_dep    = "Missing plugin or module dependency"
            none          = "The build content itself has no defect"
        }
    }
    ships_safely = [ordered]@{
        type = "noul"
        instructions = 'After ignoring everything listed in `known_benign_findings`, does `log_tail` contain any finding that indicates the shipped build content is defective and would harm players?'
    }
    player_visible_impact = [ordered]@{
        type = "score"
        instructions = 'Ignoring everything listed in `known_benign_findings`, if this build were shipped, what would players experience because of its own content defects?'
        criteria = @("Nothing noticeable", "Cosmetic or partial content problems", "Gameplay broken or blocked")
    }
    needs_human = [ordered]@{
        type = "noul"
        instructions = 'After ignoring everything listed in `known_benign_findings`, would a human engineer still have to read the original full log to decide whether this build is safe to ship?'
    }
}

$Payload = [ordered]@{
    state     = [ordered]@{ log_tail = $Tail; known_benign_findings = $DefaultBenignFindings }
    model     = $Model
    questions = $Questions
} | ConvertTo-Json -Depth 10
$Bytes = [Text.Encoding]::UTF8.GetBytes($Payload)

# 문서 권고대로 429/529 는 백오프 후 재시도한다. 그 외 실패는 fail-open.
$Response = $null
$Error_ = ""
foreach ($Attempt in 1..2) {
    try {
        $Response = Invoke-RestMethod -Uri $BaseUrl -Method Post `
            -Headers @{ Authorization = "Bearer $Key" } `
            -ContentType "application/json; charset=utf-8" -Body $Bytes -TimeoutSec 120
        break
    } catch {
        $Status = $null
        if ($_.Exception.PSObject.Properties.Name -contains "Response" -and $_.Exception.Response) {
            $Status = [int]$_.Exception.Response.StatusCode
        }
        $Error_ = $_.Exception.Message
        if (($Status -eq 429 -or $Status -eq 529) -and $Attempt -lt 2) { Start-Sleep -Seconds 5; continue }
        break
    }
}

if (-not $Response) {
    Write-Warning "TypeSafe health check: could not evaluate ($Error_). Publishing continues."
    exit 0
}

$Class  = $Response.answers.content_defect_class
$Impact = $Response.answers.player_visible_impact
$Tripped = Test-GateTripped -Answer $Class -MinProb $MinDefectProbability -MinConf $MinConfidence

$Record = [ordered]@{
    evaluated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    build_id         = $BuildId
    log_path         = $LogItem.FullName
    log_bytes        = $LogItem.Length
    log_last_write   = $LogItem.LastWriteTimeUtc.ToString("o")
    session_id       = $LogItem.Name
    model            = $Response.model
    answers          = $Response.answers
    usage            = $Response.usage
    thresholds       = [ordered]@{ min_defect_probability = $MinDefectProbability; min_confidence = $MinConfidence }
    gate_tripped     = $Tripped
}

if ($OutDir) {
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    $Stamp = if ($BuildId) { $BuildId } else { (Get-Date).ToString("yyyy-MM-dd-HHmmss") }
    $RecordPath = Join-Path $OutDir "$Stamp.json"
    [IO.File]::WriteAllText($RecordPath, ($Record | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
}

$ClassProb = [double](Get-FieldValue (Get-FieldValue $Class "probabilities") $Class.choice)

Write-Host "TypeSafe health check: $($LogItem.Name) ($($LogItem.Length) bytes, last write $($LogItem.LastWriteTime))"
Write-Host ("  content_defect_class : {0} (p={1:N2}, confidence={2:N2})" -f $Class.choice, $ClassProb, $Class.confidence)
Write-Host ("  player_visible_impact: {0:N2} / 2" -f $Impact.score)
Write-Host ("  ships_safely         : {0:N2}" -f $Response.answers.ships_safely.noul)
Write-Host ("  needs_human          : {0:N2}" -f $Response.answers.needs_human.noul)
Write-Host ("  usage                : in={0} out={1}" -f $Response.usage.input_tokens, $Response.usage.output_tokens)
if ($OutDir) { Write-Host "  recorded             : $RecordPath" }

if (-not $Tripped) {
    Write-Host "  verdict              : OK (no reproducible content defect detected)"
    exit 0
}

Write-Warning "TypeSafe health check flagged this build: content_defect_class=$($Class.choice) p=$($ClassProb.ToString('N2')) confidence=$($Class.confidence.ToString('N2'))"
if ($Enforce) { exit 1 }
Write-Warning "Warn-only mode: publishing continues. Re-run with -Enforce to block."
exit 0
