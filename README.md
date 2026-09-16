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
  - CDN 다운로드 무결성 SHA-256 검증 및 자동 롤백 (Move-first 원자적 교체)
  - 게임 실행 파일 유실 시 자동 복구 및 재설치 지원
- ⚡ **1-Click 패치 & CDN 퍼블리시 자동화:**
  - PowerShell 스크립트 한 줄로 빌드/쿡/청크 패키징/매니페스트 생성 및 정적 CDN 폴더 배치
  - 로컬 테스트용 경량 HTTP 서버 및 대역폭 제한(Throttle) 시뮬레이터 제공

---

## 🏗️ 2단계 패치 아키텍처

```text
[ 유저 실행: Launcher.exe ]
       │
       ▼
 1단계: 전체 빌드 업데이트
  ├─ CDN에서 FullVersion.txt 및 PatchGame.zip(.sha256) 확인
  ├─ exe, DLL, 베이스 엔진 파일 교체 (Move-first 안전 교체)
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
   ```
   > ⚠️ **주의**: URL은 반드시 큰따옴표(`""`)로 감싸야 합니다. 그렇지 않으면 언리얼 엔진 ini 파서가 `//`를 주석으로 인식하여 주소가 잘립니다.

---

### 2. 인게임 블루프린트 연동

`GameInstanceSubsystem`으로 동작하므로, 프로젝트 어디서든 전역 노드로 바로 접근할 수 있습니다:

- **Get Patch Subsystem**: 서브시스템 인스턴스 가져오기
- **Start Patch**: 최신 CDN 매니페스트 확인 후 패치 다운로드 및 마운트 시작
- **Get Patch Progress**: 패치 진행률 (0.0 ~ 1.0)
- **On Patch Complete**: 패치 완료(성공/실패) 이벤트 바인딩

---

### 3. 패치 청크 생성 및 배포 (`Tools/Scripts/`)

#### 1) 패치 대상 에셋 라벨링
에디터 콘솔에서 Python 스크립트를 실행하거나, 콘텐츠 브라우저에서 `Primary Asset Label`을 생성하여 Chunk ID(예: `1001`)를 지정합니다.
```powershell
# 에디터 Python 콘솔에서 실행
Tools/Scripts/CreatePatchLabel.py
```

#### 2) 원클릭 빌드 & CDN 배포
```powershell
# 콘텐츠 패치만 배포할 때 (pakchunk1001.pak + Manifest + Live.txt 생성)
.\Tools\Scripts\Publish-Patch.ps1

# 런처용 전체 게임 ZIP 빌드까지 함께 배포할 때
.\Tools\Scripts\Publish-Patch.ps1 -Full
```

---

### 4. 독립형 런처 빌드 (`Tools/Launcher/`)

1. `Tools/Launcher/Launcher.ini`에서 게임 실행 파일명과 CDN 주소를 설정합니다:
   ```ini
   CdnUrl=http://127.0.0.1:8080
   GameExe=YourGame.exe
   ```
2. `build.cmd`를 실행하면 별도 Visual Studio 설치 없이도 Windows 기본 `csc.exe`를 사용하여 `Launcher.exe`가 1초 만에 빌드됩니다:
   ```cmd
   cd Tools\Launcher
   build.cmd
   ```
3. 생성된 `Launcher.exe`와 `Launcher.ini`를 유저에게 배포합니다.

---

## 🛠️ 로컬 테스트 환경 구성

CDN 서버가 없어도 로컬에서 완전한 엔드투엔드 테스트를 진행할 수 있습니다:

```powershell
# 1. 로컬 정적 CDN 서버 실행 (포트 8080)
.\Tools\Scripts\Serve-CDN.ps1

# 2. 대역폭 제한(다운로드 속도 시뮬레이션) 테스트 서버 실행 (옵션)
python .\Tools\Scripts\Throttle-CDN.py --rate 2.5MB
```

---

## 📄 라이선스 (License)

본 프로젝트는 [MIT 라이선스](LICENSE)에 따라 자유롭게 수정, 배포 및 상업적 이용이 가능합니다.
