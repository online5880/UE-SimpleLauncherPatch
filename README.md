# 🚀 SimpleLauncherPatch (UE5 Plugin & Standalone Launcher)

[![Unreal Engine](https://img.shields.io/badge/Unreal%20Engine-5.x-313131?logo=unrealengine&logoColor=white)](https://www.unrealengine.com/)
[![Platform](https://img.shields.io/badge/Platform-Windows-blue?logo=windows&logoColor=white)](https://microsoft.com/windows)
[![Launcher Runtime](https://img.shields.io/badge/.NET-Framework%204.x-512BD4?logo=dotnet&logoColor=white)](https://dotnet.microsoft.com/)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

언리얼 엔진 5(UE5) 공식 **ChunkDownloader** 기반의 **인게임 콘텐츠 패치 서브시스템**과 배포용 **경량 C# 독립형 게임 런처**를 하나로 묶은 올인원 패치 툴킷입니다.

기존의 복잡한 GameInstance 클래스 상속이나 엔진 소스 수정 없이, 플러그인을 프로젝트의 `Plugins/` 폴더에 넣고 활성화하기만 하면 즉시 블루프린트에서 인게임 패치와 스팀 스타일 런처를 사용할 수 있습니다.

---

## ✨ 핵심 특징

- 🧩 **Zero-Configuration 서브시스템 (`UGameInstanceSubsystem`):**
  - 기존 프로젝트의 GameInstance를 바꿀 필요 없이 엔진 초기화 시 자동 로드
  - 블루프린트 노드 하나로 버전 체크, 다운로드, 마운트, 진행률 계산 지원
- 🛡️ **스팀 스타일 1-클릭 C# 단일 파일 런처:**
  - 외부 SDK/라이브러리 의존성 없는 단일 C# (`.NET 4.x`) 소스 (Windows 기본 `csc`로 1초 빌드)
  - 변경된 파일만 받는 SHA-256 증분 업데이트, 중단 다운로드 이어받기 및 자동 롤백
  - 런처 자체 업데이트와 선택적 RSA 매니페스트 서명 검증
  - 게임 실행 파일 유실 시 자동 복구 및 재설치 지원
- ⚡ **1-Click 패치 & CDN 퍼블리시 자동화:**
  - PowerShell 스크립트 한 줄로 빌드/쿡/청크 패키징/매니페스트 생성 및 정적 CDN 폴더 배치
  - `.uproject`, UE 설치 경로, 스테이징 결과와 게임 실행 파일 자동 감지
  - 로컬 테스트용 경량 HTTP 서버 및 대역폭 제한(Throttle) 시뮬레이터 제공

---

## 🏗️ 2단계 패치 아키텍처

```text
[ 유저 실행: Launcher.exe ]
       │
       ▼
 1단계: 파일 단위 증분 업데이트
  ├─ 선택적으로 서명된 FullVersion.txt 및 FullManifest.txt 확인
  ├─ SHA-256 객체 저장소에서 변경 파일만 재사용/다운로드
  ├─ 변경된 exe, DLL, 베이스 엔진 파일만 다운로드
  ├─ 실패 시 이전 파일로 원자적 롤백
  ├─ 필요하면 Launcher.exe 자체 교체 후 재시작
  └─ 게임 실행 (YourGame.exe)
       │
       ▼
 2단계: 인게임 콘텐츠 패치 (UPatchSubsystem)
  ├─ CDN에서 Live.txt (최신 BuildId) 조회
  ├─ BuildManifest-Windows.txt 다운로드 및 로컬 캐시 비교
  ├─ 변경된 pakchunkN-Windows.pak만 다운로드
  └─ 청크 동적 마운트 후 OnPatchComplete 이벤트 브로드캐스트
```

---

## 📦 저장소 구조

```text
SimpleLauncherPatch/
├── SimpleLauncherPatch.uplugin         # 언리얼 엔진 플러그인 정의 파일
├── Source/SimpleLauncherPatch/         # 플러그인 C++ 소스 (GameInstanceSubsystem 기반)
│   ├── Public/
│   │   ├── PatchSubsystem.h            # BP/C++에서 접근 가능한 패치 서브시스템
│   │   └── SimpleLauncherPatchModule.h
│   └── Private/
│       ├── PatchSubsystem.cpp          # ChunkDownloader 래핑, CDN 통신, 마운트 로직
│       └── SimpleLauncherPatchModule.cpp
└── Tools/
    ├── Launcher/                       # C# WinForms 단일 파일 런처 (스팀 스타일 UI)
    │   ├── Launcher.cs                 # 런처 전체 구현 (단일 소스 파일)
    │   ├── Launcher.ini                # CDN 주소 및 실행 파일 설정 파일
    │   └── build.cmd                   # csc 기반 초고속 컴파일 스크립트
    └── Scripts/                        # 배포 및 패치 자동화 스크립트
        ├── CreatePatchLabel.py         # Primary Asset Label 생성 도구 (에디터 Python)
        ├── DumpLabel.py                # 라벨 상태 검사 스크립트
        ├── Publish-Patch.ps1           # 1-Click 패치 쿡 및 CDN 배포 스크립트
        ├── New-SigningKey.ps1          # 런처 매니페스트 RSA 키 생성
        ├── Package-Release.ps1         # 플러그인/런처 배포 ZIP 생성
        ├── Serve-CDN.ps1               # 로컬 테스트용 경량 HTTP 서버
        └── Throttle-CDN.py             # 다운로드 속도 제한 테스트용 서버
```

---

## 🚀 빠른 시작 가이드 (Quick Start)

### 1. 언리얼 프로젝트에 플러그인 연동

1. 이 저장소의 내용물을 대상 프로젝트의 `Plugins/SimpleLauncherPatch` 디렉터리에 복사합니다.
2. 프로젝트의 `.uproject`에 플러그인을 활성화합니다:
   ```json
   {
     "Plugins": [
       {
         "Name": "SimpleLauncherPatch",
         "Enabled": true
       }
     ]
   }
   ```
3. `Config/DefaultGame.ini`에 CDN 서버 주소를 등록합니다:
   ```ini
   [/Script/Plugins.ChunkDownloader PatchGameLive]
   +CdnBaseUrls="http://127.0.0.1:8080"

   [/Script/UnrealEd.ProjectPackagingSettings]
   bUseIoStore=False
   ```
   > ⚠️ **주의**: URL은 반드시 큰따옴표(`""`)로 감싸야 합니다. 그렇지 않으면 언리얼 엔진 ini 파서가 `//`를 주석으로 인식하여 주소가 잘립니다.

   런타임 Pak 마운트를 사용하므로 패키징의 **Use Io Store**는 꺼야 합니다.

---

### 2. 인게임 블루프린트 연동

`GameInstanceSubsystem`으로 동작하므로, 프로젝트 어디서든 전역 노드로 바로 접근할 수 있습니다:

- **Get Patch Subsystem**: 서브시스템 인스턴스 가져오기
- **Start Patch**: 최신 CDN 매니페스트 확인 후 패치 다운로드 및 마운트 시작
- **Retry Patch**: 최종 실패 또는 자동 재시도 대기 중 즉시 다시 시도
- **Get Patch Progress**: 패치 진행률 (0.0 ~ 1.0)
- **Get Patch State**: 버전 확인, 재시도 대기, 다운로드, 마운트, 완료, 실패 상태
- **Get Last Patch Error / Get Retry Attempt**: 마지막 실패 원인과 현재 재시도 횟수
- **On Patch Complete**: 패치 완료(성공/실패) 이벤트 바인딩
- **On Patch State Changed**: 상태와 오류가 변경될 때 이벤트 수신

`Live.txt` 요청은 네트워크가 복구될 때까지 5초부터 최대 60초 간격으로 자동 재시도합니다. 종료 시 진행 중인 HTTP 요청과 타이머를 취소하고 `ChunkDownloader` 캐시를 안전하게 닫습니다.

> UE 5.6 Windows 기본 `ChunkDownloader`는 완료된 Pak 단위로 복구합니다. 게임이 종료될 때 이미 완료된 Pak은 다음 실행에서 재사용하지만, 당시 다운로드 중이던 Pak 하나는 처음부터 다시 받습니다.

---

### 3. 패치 청크 생성 및 배포 (`Tools/Scripts/`)

#### 1) 패치 대상 에셋 라벨링
패치할 에셋을 `/Game/PatchContent`에 넣고 에디터에서 Python 스크립트를 실행합니다. 스크립트가 해당 폴더에 Chunk ID `1001`인 `Primary Asset Label`을 만듭니다.
```powershell
# 에디터 Python 콘솔에서 실행
Tools/Scripts/CreatePatchLabel.py
```

#### 2) 원클릭 빌드 & CDN 배포
프로젝트 루트에서 실행하면 `.uproject`와 `EngineAssociation`에 맞는 UE 설치를 자동으로 찾습니다.
```powershell
# 자동 감지만 확인하고 종료
.\Plugins\SimpleLauncherPatch\Tools\Scripts\Publish-Patch.ps1 -ValidateOnly

# 콘텐츠 패치만 배포할 때 (pakchunk1001.pak + Manifest + Live.txt 생성)
.\Plugins\SimpleLauncherPatch\Tools\Scripts\Publish-Patch.ps1

# 전체 게임과 프로젝트명/실행 파일이 반영된 런처까지 함께 배포
.\Plugins\SimpleLauncherPatch\Tools\Scripts\Publish-Patch.ps1 -Full

# RSA 서명까지 적용한 전체 배포
.\Plugins\SimpleLauncherPatch\Tools\Scripts\Publish-Patch.ps1 `
  -Full `
  -SigningKey .\LauncherSigning.private.xml

# 자동 감지가 불가능하거나 후보가 여러 개일 때만 직접 지정
.\Plugins\SimpleLauncherPatch\Tools\Scripts\Publish-Patch.ps1 `
  -Project .\MyGame.uproject `
  -EngineRoot "C:\Program Files\Epic Games\UE_5.6" `
  -GameExe MyGame.exe `
  -Full

# 1.3 이하 런처가 아직 설치된 사용자를 위한 1회 호환 배포
.\Plugins\SimpleLauncherPatch\Tools\Scripts\Publish-Patch.ps1 `
  -Full -LegacyFiles -LegacyZip
```

결과물은 기본적으로 `Tools/Scripts/Cloud`에 생성됩니다. 실제 파일은 내용이 같은 경우 한 번만 저장되는 `Full/Objects/<앞 2자리>/<SHA-256>`에 있고, 버전별 `FullManifest.txt`에는 경로·크기·SHA-256이 기록됩니다. 기본값은 최근 3개 전체 버전만 남기고 참조되지 않는 객체를 정리하며, `-KeepFullVersions 5`처럼 조정할 수 있습니다. 경로를 바꾸려면 `-CloudRoot`, 기존 스테이징 빌드를 재사용하려면 `-SkipBuild`를 사용합니다.

기존 1.3 런처가 배포되어 있다면 1.4 첫 배포에만 `-LegacyFiles -LegacyZip`을 붙이십시오. 1.4 런처가 보급된 뒤에는 두 옵션을 빼야 CDN 중복 제거 효과를 온전히 얻습니다.

---

### 4. 독립형 런처 빌드 (`Tools/Launcher/`)

1.5부터 `Publish-Patch.ps1 -Full`은 4MiB보다 큰 `.pak`·`.ucas`에 대해 4MiB 블록 목록도 자동 생성합니다. 런처는 설치본과 임시 파일의 동일 위치 블록을 SHA-256으로 검사해 재사용하고, 다른 블록만 다운로드합니다. 재조립 파일 전체의 SHA-256까지 통과해야 기존 설치 파일을 교체합니다. 서명을 사용하는 배포에서는 블록 목록도 서명합니다.

기존 1.4 런처 호환을 위해 전체 파일 객체도 유지하므로 블록 저장 공간이 추가됩니다. 블록 목록이 없는 이전 CDN은 파일 단위 다운로드로 처리합니다. 고정 위치 방식이므로 압축·재쿠킹으로 데이터 위치가 많이 이동하면 다운로드 절감 효과가 작아질 수 있습니다. 인게임 ChunkDownloader는 기존 Pak 단위 다운로드를 유지합니다. 진행률은 재사용을 포함한 파일 준비량이며, 로그의 `downloaded`는 다운로드 경로로 처리한 블록 크기 합계입니다.

1. `Tools/Launcher/Launcher.ini`에서 게임명, 실행 파일명과 CDN 주소를 설정합니다. `Publish-Patch.ps1 -Full`을 사용하면 게임명과 실행 파일명은 자동으로 채워집니다:
   ```ini
   CdnUrl=http://127.0.0.1:8080
   GameExe=YourGame.exe
   GameTitle=Your Game
   ManifestPublicKey=
   ```
2. `build.cmd`를 실행하면 별도 Visual Studio 설치 없이도 Windows 기본 `csc.exe`를 사용하여 `Launcher.exe`가 1초 만에 빌드됩니다:
   ```cmd
   cd Tools\Launcher
   build.cmd
   ```
3. 생성된 `Launcher.exe`와 `Launcher.ini`를 유저에게 배포합니다.

다운로드가 중단되면 `.launcher-cache/<BuildId>`에 파일별 `.part`를 보존합니다. 같은 업데이트를 다시 시도할 때 HTTP Range를 지원하는 CDN이면 받은 지점부터 이어받고, 지원하지 않는 서버면 자동으로 처음부터 다시 받습니다. 버전별 SHA-256이 달라지거나 파일이 손상되면 부분 파일을 폐기합니다.

> 1.2 이하 런처에는 셀프 업데이트 코드가 없으므로 1.3 이상 런처를 한 번 직접 배포해야 합니다. 이후 버전부터는 `Launcher.exe`도 매니페스트에 포함되어 자동 교체됩니다.

프로덕션 배포에서는 먼저 키를 한 번 생성하고 개인 키를 안전한 별도 위치에 보관합니다:

```powershell
.\Tools\Scripts\New-SigningKey.ps1 -OutputDir C:\Secure\LauncherKeys
```

`Publish-Patch.ps1 -SigningKey`를 사용하면 `Launcher.ini`의 `ManifestPublicKey`가 자동으로 채워집니다. `*.private.xml`은 Git에서 제외되며 외부에 배포하면 안 됩니다.

### 5. 배포 ZIP 만들기

플러그인 개발자용 ZIP과 플레이어용 런처 ZIP을 한 번에 생성합니다:

```powershell
.\Tools\Scripts\Package-Release.ps1 -EngineRoot "C:\Program Files\Epic Games\UE_5.6"
```

기본 출력 폴더는 저장소 옆의 `SimpleLauncherPatch-Releases`입니다.

---

## 🛠️ 로컬 테스트 환경 구성

프로젝트의 `Plugins/SimpleLauncherPatch/Tools/Scripts/Test-Local.cmd`를 더블클릭하면 끝입니다. 프로젝트·UE·게임 실행 파일을 자동 감지하고 다음 작업을 한 번에 수행합니다.

```text
게임 빌드 → 패치 배포 → 로컬 CDN 실행 → 테스트 런처 실행
```

첫 실행에서 `PLAY`를 눌러 전체 설치를 확인하고, 에셋을 수정한 뒤 `Test-Local.cmd`를 다시 실행하면 증분 패치를 확인할 수 있습니다. 테스트 파일은 프로젝트의 `Saved/SimpleLauncherPatchTest`에만 생성됩니다.

서버만 따로 실행하려면 다음 명령을 사용합니다:

```powershell
.\Tools\Scripts\Serve-CDN.ps1
```

---

### 블록 패치 회귀 테스트

블록 패치 개발 검증은 `pwsh -File .\Tools\Scripts\Test-Blocks.ps1`로 실행합니다(PowerShell 7, .NET Framework 컴파일러, Python 필요). 테스트용 Pak에서 한 블록만 변경하고, 실제 런처의 HTTP 객체 요청이 한 번인지와 설치 결과 SHA-256을 검사합니다. 중단 후 재사용, 손상 블록 거부, 신규 설치, 마지막 짧은 블록, 버전 정리 후 참조 블록 보존도 확인합니다. 테스트 결과와 로그는 출력된 임시 폴더에 남습니다. 실제 UE 쿠킹 에셋에서의 절감률은 별도 측정이 필요합니다.

런처의 **검사 및 복구** 버튼(Alt+R)을 누르면 버전이 같아도 CDN의 최신 매니페스트로 모든 관리 파일을 검사합니다. 누락·손상된 파일만 받고 큰 Pak은 정상 블록을 재사용합니다. 최신 버전이 따로 있으면 그 버전을 기준으로 복구하며, 완료 후 게임은 자동 실행하지 않습니다. 관리 대상 외의 파일은 삭제하지 않습니다. 실제 교체가 필요한 경우 실행 중인 게임을 종료하므로 먼저 게임을 저장하고 닫아 주세요.

복구에는 CDN 연결과 파일 매니페스트가 필요합니다. 서명 검증 실패나 연결 실패 시 복구를 중단하며, 일반 PLAY는 기존 동작을 유지합니다. 개발 검증용 `Launcher.exe --repair`는 같은 버튼 동작을 실행한 뒤 성공 0·실패 1로 종료합니다. `Test-Blocks.ps1`은 같은 버전의 손상 Pak·누락 실행 파일 복구, 정상 설치 무다운로드, 게임 자동 실행 방지, 서명 오류·오프라인 실패도 검사합니다.

## 📄 라이선스 (License)

본 프로젝트는 [MIT 라이선스](LICENSE)에 따라 자유롭게 수정, 배포 및 상업적 이용이 가능합니다.
