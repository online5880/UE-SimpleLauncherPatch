# SimpleLauncherPatch (UE Plugin & Standalone Launcher)

언리얼 엔진 5.x ChunkDownloader 기반의 **인게임 콘텐츠 패치 시스템**과 **단일 C# 독립형 게임 런처** 툴킷입니다.
어떤 프로젝트든 `Plugins/` 폴더에 넣고 활성화하면 즉시 사용할 수 있습니다.

---

## 📦 구조

```text
SimpleLauncherPatch/
├── SimpleLauncherPatch.uplugin
├── Source/SimpleLauncherPatch/     # 언리얼 플러그인 (GameInstanceSubsystem 기반)
│   ├── Public/PatchSubsystem.h     # BP/C++에서 접근 가능한 패치 서브시스템
│   └── Private/PatchSubsystem.cpp
└── Tools/
    ├── Launcher/                   # C# WinForms 단일 파일 런처 (스팀 스타일)
    │   ├── Launcher.cs
    │   ├── Launcher.ini            # CDN 주소 및 실행 파일 설정
    │   └── build.cmd               # csc 기반 단일 빌드 배치파일 (.NET 4.x)
    └── Scripts/                    # 배포 및 패치 자동화 스크립트
        ├── CreatePatchLabel.py     # Primary Asset Label 생성 (Chunk ID 지정)
        ├── Publish-Patch.ps1       # 1-Click 패치 쿡 및 CDN 배포
        ├── Serve-CDN.ps1           # 로컬 테스트용 경량 HTTP 서버
        └── Throttle-CDN.py         # 다운로드 속도 제한 테스트용 서버
```

---

## 🚀 빠른 시작 가이드 (Quick Start)

### 1. 언리얼 프로젝트에 플러그인 추가
1. 대상 언리얼 프로젝트의 `Plugins/` 폴더에 `SimpleLauncherPatch`를 복사합니다.
2. 프로젝트 `.uproject` 또는 에디터의 **Edit -> Plugins**에서 `SimpleLauncherPatch`를 활성화합니다.
3. `Config/DefaultGame.ini`에 CDN 주소를 등록합니다:
   ```ini
   [/Script/Plugins.ChunkDownloader PatchGameLive]
   +CdnBaseUrls="http://your-cdn-server.com"
   ```
   *(주의: URL은 반드시 큰따옴표 `""`로 감싸야 `//`가 주석으로 처리되지 않습니다)*

### 2. 인게임 블루프린트 연동
`GameInstanceSubsystem`으로 동작하므로, 프로젝트의 GameInstance를 교체할 필요 없이 어디서나 노드로 접근 가능합니다:
- **Get Patch Subsystem**: 서브시스템 인스턴스 가져오기
- **Start Patch**: 최신 CDN 매니페스트 확인 후 패치 다운로드 및 마운트 시작
- **Get Patch Progress**: 패치 진행률 (0.0 ~ 1.0)
- **On Patch Complete**: 패치 완료(성공/실패) 이벤트 수신

### 3. 패치 생성 및 배포 (`Tools/Scripts/`)
1. **에셋 라벨링**:
   에디터 Python 콘솔에서 `CreatePatchLabel.py`를 실행하거나, 콘텐츠 브라우저에서 `Primary Asset Label`을 생성하여 Chunk ID(예: `1001`)를 지정합니다.
2. **패치 빌드 & 퍼블리시**:
   ```powershell
   # 콘텐츠 청크만 패치 배포할 때
   .\Publish-Patch.ps1

   # 전체 게임 빌드 ZIP(런처용)까지 같이 배포할 때
   .\Publish-Patch.ps1 -Full
   ```

### 4. 독립형 런처 빌드 (`Tools/Launcher/`)
1. `Launcher.ini`에서 게임 실행 파일명과 CDN URL 설정:
   ```ini
   CdnUrl=http://your-cdn-server.com
   GameExe=YourGame.exe
   ```
2. `build.cmd`를 실행하면 외부 의존성 없이 `Launcher.exe`가 빌드됩니다.
3. 런처 기능:
   - 기동 시 CDN 버전 체크 (`Full/FullVersion.txt`)
   - SHA-256 무결성 검증 후 패치 적용
   - 안전한 파일 교체 (Move-first 교체 및 롤백)
   - PLAY 클릭 시 1-클릭 실행
