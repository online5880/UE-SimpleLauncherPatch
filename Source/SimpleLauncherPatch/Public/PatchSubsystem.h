#pragma once

#include "CoreMinimal.h"
#include "Containers/Ticker.h"
#include "Subsystems/GameInstanceSubsystem.h"
#include "PatchSubsystem.generated.h"

class IHttpRequest;

UENUM(BlueprintType)
enum class ESimplePatchState : uint8
{
	Idle,
	CheckingVersion,
	WaitingToRetry,
	UpdatingManifest,
	Downloading,
	Mounting,
	Complete,
	Failed
};

DECLARE_DYNAMIC_MULTICAST_DELEGATE_OneParam(FOnSimplePatchComplete, bool, bSuccess);
DECLARE_DYNAMIC_MULTICAST_DELEGATE_TwoParams(
	FOnSimplePatchStateChanged,
	ESimplePatchState, State,
	const FText&, Error);

/**
 * GameInstanceSubsystem wrapping ChunkDownloader.
 * Automatically checks, downloads, and mounts content patches on game start.
 */
UCLASS()
class SIMPLELAUNCHERPATCH_API UPatchSubsystem : public UGameInstanceSubsystem
{
	GENERATED_BODY()

public:
	virtual void Initialize(FSubsystemCollectionBase& Collection) override;
	virtual void Deinitialize() override;

	/** True once the manifest has been fetched and compared against the cache. */
	UFUNCTION(BlueprintPure, Category = "Patching")
	bool IsPatchReady() const { return bManifestUpToDate; }

	UFUNCTION(BlueprintPure, Category = "Patching")
	bool IsPatching() const { return bPatching; }

	UFUNCTION(BlueprintPure, Category = "Patching")
	ESimplePatchState GetPatchState() const { return PatchState; }

	UFUNCTION(BlueprintPure, Category = "Patching")
	FText GetLastPatchError() const { return LastPatchError; }

	UFUNCTION(BlueprintPure, Category = "Patching")
	int32 GetRetryAttempt() const { return RetryAttempt; }

	/** Check the manifest if needed, then download and mount every listed chunk. */
	UFUNCTION(BlueprintCallable, Category = "Patching")
	void StartPatch();

	/** Immediately retry after a terminal failure or while waiting for an automatic retry. */
	UFUNCTION(BlueprintCallable, Category = "Patching")
	void RetryPatch();

	/** 0..1 across the file download + chunk mount phases. */
	UFUNCTION(BlueprintPure, Category = "Patching")
	float GetPatchProgress() const;

	UPROPERTY(BlueprintAssignable, Category = "Patching")
	FOnSimplePatchComplete OnPatchComplete;

	UPROPERTY(BlueprintAssignable, Category = "Patching")
	FOnSimplePatchStateChanged OnPatchStateChanged;

private:
	void FetchLatestBuildId();
	void ScheduleVersionRetry(const FText& Error);
	void CancelVersionWork();
	void OnLiveBuildIdReceived(const FString& BuildId);
	void OnManifestUpdated(bool bSuccess);
	void OnChunksDownloaded(bool bSuccess);
	void OnChunksMounted(bool bSuccess);
	void SetState(ESimplePatchState NewState, const FText& Error = FText::GetEmpty());
	void FailPatch(const FText& Error);
	FText GetDownloaderError(const FText& Fallback) const;

	static constexpr const TCHAR* DeploymentName = TEXT("PatchGameLive");

	TSharedPtr<IHttpRequest, ESPMode::ThreadSafe> VersionRequest;
	FTSTicker::FDelegateHandle RetryTickerHandle;

	ESimplePatchState PatchState = ESimplePatchState::Idle;
	FText LastPatchError;
	int32 RetryAttempt = 0;
	bool bManifestUpToDate = false;
	bool bPatchStarted = false;
	bool bPatching = false;
	bool bDownloaderInitialized = false;
	bool bShuttingDown = false;
};
