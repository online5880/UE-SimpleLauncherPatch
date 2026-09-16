# 패치 안정성 설계

## 목표

- `Live.txt` 요청이 실패하면 5초부터 최대 60초 간격으로 성공할 때까지 재시도한다.
- 게임 종료 시 HTTP 요청과 재시도 타이머를 취소하고 `ChunkDownloader`를 안전하게 종료한다.
- 현재 상태, 마지막 오류, 재시도 횟수를 블루프린트에 공개한다.
- 중단 후 재실행했을 때 완료된 Pak을 재사용하고 패치가 정상 완료되는지 검증한다.

## 상태 흐름

`Idle → CheckingVersion → UpdatingManifest → Downloading → Mounting → Complete`

`Live.txt` 네트워크 실패는 `WaitingToRetry`로 이동한 뒤 자동 재시도한다. 설정 오류, 저장 공간 부족, 다운로드 또는 마운트의 최종 실패는 `Failed`로 이동하고 수동 `RetryPatch`를 허용한다.

기존 `OnPatchComplete`는 호환성을 위해 유지하고, 상태와 오류를 함께 받는 `OnPatchStateChanged`를 추가한다.

## 생명주기

모든 HTTP·다운로드·마운트 콜백은 `TWeakObjectPtr<UPatchSubsystem>`을 사용한다. `Deinitialize`는 자체 HTTP 요청과 재시도 타이머를 먼저 취소한 뒤 `FChunkDownloader::Shutdown()`을 호출한다. 종료 뒤 예약된 콜백은 약한 참조 검사에서 폐기된다.

## 재개 범위

UE 5.6 Windows 기본 `ChunkDownloader`는 HTTP 응답 전체를 받은 뒤 파일로 기록한다. 따라서 완료된 Pak은 다음 실행에서 재사용하지만, 종료 당시 다운로드 중이던 Pak 하나는 처음부터 다시 받는다. 바이트 단위 재개는 엔진 수정이나 별도 다운로더가 필요하므로 이번 플러그인 범위에서 제외한다.

## 검증

- UE 5.6 Win64 Development/Shipping 플러그인 빌드
- 네트워크 중단 시 `WaitingToRetry`와 재시도 횟수 확인
- 다운로드 도중 프로세스 종료 후 재실행하여 캐시된 Pak 재사용 및 최종 마운트 확인
- 블루프린트 공개 enum, 함수, 이벤트의 UHT 생성 확인
