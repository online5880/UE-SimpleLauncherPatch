# 범용 패치 퍼블리셔 설계

## 목표

`Publish-Patch.ps1`에서 특정 프로젝트명과 Unreal Engine 설치 경로를 제거해, 플러그인을 임의의 UE5 프로젝트 `Plugins/SimpleLauncherPatch` 아래에 복사한 뒤 바로 사용할 수 있게 한다.

## 방식

- `-Project`가 없으면 스크립트 위치부터 상위 폴더를 탐색해 단일 `.uproject`를 찾는다.
- `-EngineRoot`가 없으면 `.uproject`의 `EngineAssociation`과 Epic Launcher 설치 정보를 이용해 엔진을 찾는다.
- 스테이징 결과에서 `Content/Paks`와 게임 실행 파일을 탐색한다.
- 자동 감지 결과가 여러 개이면 임의 선택하지 않고 `-Project`, `-EngineRoot`, `-GameExe` 사용법을 포함한 오류를 낸다.
- 전체 빌드 ZIP은 특정 폴더명을 나열하지 않고 스테이징 루트의 모든 항목을 담는다.
- 기존 `-Config`, `-SkipBuild`, `-Full`, `-CloudRoot` 사용법은 유지한다.

## 검증

- PowerShell 파서 검사를 통과한다.
- 기존 `PatchGame.uproject`와 UE 5.6 설치 경로를 자동 감지한다.
- 런처 자체 테스트와 Unreal `BuildPlugin` 빌드를 통과한다.

## 제외

에디터 설정 UI와 별도 설정 파일은 이번 범위에 넣지 않는다. 명령줄 자동 감지로 부족해지는 시점에 추가한다.
