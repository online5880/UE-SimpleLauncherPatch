#include "PatchSubsystem.h"

#include "ChunkDownloader.h"
#include "HttpModule.h"
#include "Interfaces/IHttpRequest.h"
#include "Interfaces/IHttpResponse.h"
#include "Misc/ConfigCacheIni.h"

void UPatchSubsystem::Initialize(FSubsystemCollectionBase& Collection)
{
	Super::Initialize(Collection);

	bShuttingDown = false;
	TSharedRef<FChunkDownloader> Downloader = FChunkDownloader::GetOrCreate();
	Downloader->Initialize(TEXT("Windows"), 8);
	bDownloaderInitialized = true;
	Downloader->LoadCachedBuild(DeploymentName);

	FetchLatestBuildId();
}

void UPatchSubsystem::Deinitialize()
{
	bShuttingDown = true;
	CancelVersionWork();

	if (bDownloaderInitialized)
	{
		FChunkDownloader::Shutdown();
		bDownloaderInitialized = false;
	}

	Super::Deinitialize();
}

void UPatchSubsystem::FetchLatestBuildId()
{
	if (bShuttingDown || VersionRequest.IsValid())
	{
		return;
	}

	TArray<FString> BaseUrls;
	GConfig->GetArray(TEXT("/Script/Plugins.ChunkDownloader PatchGameLive"), TEXT("CdnBaseUrls"), BaseUrls, GGameIni);
	if (BaseUrls.Num() == 0)
	{
		GConfig->GetArray(TEXT("/Script/Plugins.ChunkDownloader"), TEXT("CdnBaseUrls"), BaseUrls, GGameIni);
	}
	if (BaseUrls.Num() == 0)
	{
		FailPatch(FText::FromString(TEXT("No ChunkDownloader CdnBaseUrls are configured.")));
		return;
	}

	FString BaseUrl = BaseUrls[RetryAttempt % BaseUrls.Num()];
	BaseUrl.RemoveFromEnd(TEXT("/"));
	SetState(ESimplePatchState::CheckingVersion);

	TSharedRef<IHttpRequest, ESPMode::ThreadSafe> Request = FHttpModule::Get().CreateRequest();
	VersionRequest = Request;
	Request->SetVerb(TEXT("GET"));
	Request->SetURL(FString::Printf(TEXT("%s/Live.txt"), *BaseUrl));

	TWeakObjectPtr<UPatchSubsystem> WeakThis(this);
	Request->OnProcessRequestComplete().BindLambda(
		[WeakThis](FHttpRequestPtr CompletedRequest, FHttpResponsePtr Response, bool bSuccess)
		{
			UPatchSubsystem* Self = WeakThis.Get();
			if (Self == nullptr || Self->bShuttingDown)
			{
				return;
			}

			if (Self->VersionRequest == CompletedRequest)
			{
				Self->VersionRequest.Reset();
			}

			const int32 ResponseCode = Response.IsValid() ? Response->GetResponseCode() : 0;
			if (bSuccess && Response.IsValid() && EHttpResponseCodes::IsOk(ResponseCode))
			{
				const FString BuildId = Response->GetContentAsString().TrimStartAndEnd();
				if (!BuildId.IsEmpty())
				{
					Self->RetryAttempt = 0;
					Self->OnLiveBuildIdReceived(BuildId);
					return;
				}
			}

			const FString Message = ResponseCode > 0
				? FString::Printf(TEXT("Live.txt request failed (HTTP %d)."), ResponseCode)
				: TEXT("Live.txt request failed (network unavailable).");
			Self->ScheduleVersionRetry(FText::FromString(Message));
		});

	if (!Request->ProcessRequest())
	{
		Request->OnProcessRequestComplete().Unbind();
		VersionRequest.Reset();
		ScheduleVersionRetry(FText::FromString(TEXT("Live.txt request could not be started.")));
	}
}

void UPatchSubsystem::ScheduleVersionRetry(const FText& Error)
{
	if (bShuttingDown)
	{
		return;
	}

	if (RetryTickerHandle.IsValid())
	{
		FTSTicker::GetCoreTicker().RemoveTicker(RetryTickerHandle);
		RetryTickerHandle.Reset();
	}

	++RetryAttempt;
	const float DelaySeconds = FMath::Min(static_cast<float>(RetryAttempt) * 5.0f, 60.0f);
	SetState(ESimplePatchState::WaitingToRetry, Error);
	UE_LOG(LogTemp, Warning, TEXT("[PatchSubsystem] %s Retrying in %.0f seconds (attempt %d)."),
		*Error.ToString(), DelaySeconds, RetryAttempt);

	TWeakObjectPtr<UPatchSubsystem> WeakThis(this);
	RetryTickerHandle = FTSTicker::GetCoreTicker().AddTicker(
		FTickerDelegate::CreateLambda([WeakThis](float)
		{
			UPatchSubsystem* Self = WeakThis.Get();
			if (Self != nullptr)
			{
				Self->RetryTickerHandle.Reset();
				if (!Self->bShuttingDown)
				{
					Self->FetchLatestBuildId();
				}
			}
			return false;
		}),
		DelaySeconds);
}

void UPatchSubsystem::CancelVersionWork()
{
	if (RetryTickerHandle.IsValid())
	{
		FTSTicker::GetCoreTicker().RemoveTicker(RetryTickerHandle);
		RetryTickerHandle.Reset();
	}

	if (VersionRequest.IsValid())
	{
		VersionRequest->OnProcessRequestComplete().Unbind();
		VersionRequest->CancelRequest();
		VersionRequest.Reset();
	}
}

void UPatchSubsystem::OnLiveBuildIdReceived(const FString& BuildId)
{
	if (bShuttingDown)
	{
		return;
	}

	TSharedPtr<FChunkDownloader> Downloader = FChunkDownloader::Get();
	if (!Downloader.IsValid())
	{
		FailPatch(FText::FromString(TEXT("ChunkDownloader is not initialized.")));
		return;
	}

	bManifestUpToDate = false;
	SetState(ESimplePatchState::UpdatingManifest);
	TWeakObjectPtr<UPatchSubsystem> WeakThis(this);
	Downloader->UpdateBuild(DeploymentName, BuildId, [WeakThis](bool bSuccess)
	{
		UPatchSubsystem* Self = WeakThis.Get();
		if (Self != nullptr && !Self->bShuttingDown)
		{
			Self->OnManifestUpdated(bSuccess);
		}
	});
}

void UPatchSubsystem::OnManifestUpdated(bool bSuccess)
{
	if (!bSuccess)
	{
		bManifestUpToDate = false;
		FailPatch(GetDownloaderError(FText::FromString(TEXT("Manifest update failed."))));
		return;
	}

	bManifestUpToDate = true;
	UE_LOG(LogTemp, Log, TEXT("[PatchSubsystem] Manifest up to date; starting patch."));
	StartPatch();
}

void UPatchSubsystem::StartPatch()
{
	if (bShuttingDown || bPatching)
	{
		return;
	}

	if (!bManifestUpToDate)
	{
		if (PatchState != ESimplePatchState::CheckingVersion &&
			PatchState != ESimplePatchState::WaitingToRetry &&
			PatchState != ESimplePatchState::UpdatingManifest)
		{
			FetchLatestBuildId();
		}
		return;
	}

	if (bPatchStarted)
	{
		return;
	}
	bPatchStarted = true;

	TSharedPtr<FChunkDownloader> Downloader = FChunkDownloader::Get();
	if (!Downloader.IsValid())
	{
		FailPatch(FText::FromString(TEXT("ChunkDownloader is not initialized.")));
		return;
	}

	TArray<int32> ChunkList;
	Downloader->GetAllChunkIds(ChunkList);
	if (ChunkList.Num() == 0)
	{
		UE_LOG(LogTemp, Log, TEXT("[PatchSubsystem] No chunks in manifest; nothing to patch."));
		SetState(ESimplePatchState::Complete);
		OnPatchComplete.Broadcast(true);
		return;
	}

	bPatching = true;
	SetState(ESimplePatchState::Downloading);
	UE_LOG(LogTemp, Log, TEXT("[PatchSubsystem] Downloading %d chunk(s)."), ChunkList.Num());
	TWeakObjectPtr<UPatchSubsystem> WeakThis(this);
	Downloader->DownloadChunks(ChunkList, [WeakThis](bool bSuccess)
	{
		UPatchSubsystem* Self = WeakThis.Get();
		if (Self != nullptr && !Self->bShuttingDown)
		{
			Self->OnChunksDownloaded(bSuccess);
		}
	}, 1);
}

void UPatchSubsystem::RetryPatch()
{
	if (bShuttingDown ||
		(PatchState != ESimplePatchState::Failed && PatchState != ESimplePatchState::WaitingToRetry))
	{
		return;
	}

	CancelVersionWork();
	RetryAttempt = 0;
	bPatchStarted = false;
	bPatching = false;
	SetState(ESimplePatchState::Idle);

	if (bManifestUpToDate)
	{
		StartPatch();
	}
	else
	{
		FetchLatestBuildId();
	}
}

void UPatchSubsystem::OnChunksDownloaded(bool bSuccess)
{
	if (!bSuccess)
	{
		FailPatch(GetDownloaderError(FText::FromString(TEXT("Chunk download failed."))));
		return;
	}

	TSharedPtr<FChunkDownloader> Downloader = FChunkDownloader::Get();
	if (!Downloader.IsValid())
	{
		FailPatch(FText::FromString(TEXT("ChunkDownloader stopped before mounting.")));
		return;
	}

	TArray<int32> ChunkList;
	Downloader->GetAllChunkIds(ChunkList);
	SetState(ESimplePatchState::Mounting);
	TWeakObjectPtr<UPatchSubsystem> WeakThis(this);
	Downloader->MountChunks(ChunkList, [WeakThis](bool bSuccess)
	{
		UPatchSubsystem* Self = WeakThis.Get();
		if (Self != nullptr && !Self->bShuttingDown)
		{
			Self->OnChunksMounted(bSuccess);
		}
	});
}

void UPatchSubsystem::OnChunksMounted(bool bSuccess)
{
	bPatching = false;
	if (!bSuccess)
	{
		FailPatch(GetDownloaderError(FText::FromString(TEXT("Chunk mount failed."))));
		return;
	}

	UE_LOG(LogTemp, Log, TEXT("[PatchSubsystem] Chunk mount OK."));
	SetState(ESimplePatchState::Complete);
	OnPatchComplete.Broadcast(true);
}

void UPatchSubsystem::SetState(ESimplePatchState NewState, const FText& Error)
{
	if (PatchState == NewState && LastPatchError.EqualTo(Error))
	{
		return;
	}

	PatchState = NewState;
	LastPatchError = Error;
	const UEnum* StateEnum = StaticEnum<ESimplePatchState>();
	const FString StateName = StateEnum != nullptr
		? StateEnum->GetNameStringByValue(static_cast<int64>(PatchState))
		: TEXT("Unknown");
	UE_LOG(LogTemp, Log, TEXT("[PatchSubsystem] State=%s Error=%s"), *StateName, *LastPatchError.ToString());
	OnPatchStateChanged.Broadcast(PatchState, LastPatchError);
}

void UPatchSubsystem::FailPatch(const FText& Error)
{
	bPatching = false;
	bPatchStarted = false;
	SetState(ESimplePatchState::Failed, Error);
	UE_LOG(LogTemp, Error, TEXT("[PatchSubsystem] %s"), *Error.ToString());
	OnPatchComplete.Broadcast(false);
}

FText UPatchSubsystem::GetDownloaderError(const FText& Fallback) const
{
	const TSharedPtr<FChunkDownloader> Downloader = FChunkDownloader::Get();
	if (Downloader.IsValid() && !Downloader->GetLoadingStats().LastError.IsEmpty())
	{
		return Downloader->GetLoadingStats().LastError;
	}
	return Fallback;
}

float UPatchSubsystem::GetPatchProgress() const
{
	if (PatchState == ESimplePatchState::Complete)
	{
		return 1.0f;
	}

	const TSharedPtr<FChunkDownloader> Downloader = FChunkDownloader::Get();
	if (!Downloader.IsValid())
	{
		return 0.0f;
	}

	const FChunkDownloader::FStats& Stats = Downloader->GetLoadingStats();
	const int32 TotalUnits = Stats.TotalFilesToDownload + Stats.TotalChunksToMount;
	if (TotalUnits <= 0)
	{
		return 0.0f;
	}

	const int32 DoneUnits = Stats.FilesDownloaded + Stats.ChunksMounted;
	return FMath::Clamp(static_cast<float>(DoneUnits) / static_cast<float>(TotalUnits), 0.0f, 1.0f);
}
