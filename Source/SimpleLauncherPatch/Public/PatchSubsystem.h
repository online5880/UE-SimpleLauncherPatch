#pragma once

#include "CoreMinimal.h"
#include "Subsystems/GameInstanceSubsystem.h"
#include "PatchSubsystem.generated.h"

DECLARE_DYNAMIC_MULTICAST_DELEGATE_OneParam(FOnSimplePatchComplete, bool, bSuccess);

/**
 * GameInstanceSubsystem wrapping ChunkDownloader.
 * Automatically initializes on game start and handles manifest check, chunk download & mount.
 */
UCLASS()
class SIMPLELAUNCHERPATCH_API UPatchSubsystem : public UGameInstanceSubsystem
{
	GENERATED_BODY()

public:
	virtual void Initialize(FSubsystemCollectionBase& Collection) override;
	virtual void Deinitialize() override;

	/** True once the manifest has been fetched and compared against the cache. */
	UFUNCTION(BlueprintCallable, Category = "Patching")
	bool IsPatchReady() const { return bManifestUpToDate; }

	/** Download + mount all chunks listed in the manifest. */
	UFUNCTION(BlueprintCallable, Category = "Patching")
	void StartPatch();

	/** 0..1 across the file download + chunk mount phases. */
	UFUNCTION(BlueprintCallable, Category = "Patching")
	float GetPatchProgress() const;

	UPROPERTY(BlueprintAssignable, Category = "Patching")
	FOnSimplePatchComplete OnPatchComplete;

private:
	void FetchLatestBuildId();
	void OnLiveBuildIdReceived(bool bSuccess, const FString& BuildId);
	void OnManifestUpdated(bool bSuccess);
	void OnChunksDownloaded(bool bSuccess);
	void OnChunksMounted(bool bSuccess);

	static constexpr const TCHAR* DeploymentName = TEXT("PatchGameLive");

	bool bManifestUpToDate = false;
	bool bPatchStarted = false;
	bool bPatching = false;
};
