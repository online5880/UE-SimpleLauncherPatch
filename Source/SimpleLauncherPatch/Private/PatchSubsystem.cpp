#include "PatchSubsystem.h"
#include "ChunkDownloader.h"
#include "HttpModule.h"
#include "Interfaces/IHttpRequest.h"
#include "Interfaces/IHttpResponse.h"
#include "Misc/ConfigCacheIni.h"

void UPatchSubsystem::Initialize(FSubsystemCollectionBase& Collection)
{
	Super::Initialize(Collection);

	TSharedRef<FChunkDownloader> Downloader = FChunkDownloader::GetOrCreate();
	Downloader->Initialize(TEXT("Windows"), 8);
	Downloader->LoadCachedBuild(DeploymentName);

	FetchLatestBuildId();
}

void UPatchSubsystem::Deinitialize()
{
	Super::Deinitialize();
}

void UPatchSubsystem::FetchLatestBuildId()
{
	TArray<FString> BaseUrls;
	GConfig->GetArray(TEXT("/Script/Plugins.ChunkDownloader PatchGameLive"), TEXT("+CdnBaseUrls"), BaseUrls, GGameIni);
	if (BaseUrls.Num() == 0)
	{
		GConfig->GetArray(TEXT("/Script/Plugins.ChunkDownloader PatchGameLive"), TEXT("CdnBaseUrls"), BaseUrls, GGameIni);
	}
	if (BaseUrls.Num() == 0)
	{
		UE_LOG(LogTemp, Warning, TEXT("[PatchSubsystem] No +CdnBaseUrls configured; patching disabled."));
		return;
	}

	FString BaseUrl = BaseUrls[0];
	BaseUrl.RemoveFromEnd(TEXT("/"));

	TSharedRef<IHttpRequest, ESPMode::ThreadSafe> Request = FHttpModule::Get().CreateRequest();
	Request->SetVerb(TEXT("GET"));
	Request->SetURL(FString::Printf(TEXT("%s/Live.txt"), *BaseUrl));
	Request->OnProcessRequestComplete().BindLambda([this](FHttpRequestPtr, FHttpResponsePtr Response, bool bSuccess)
	{
		if (bSuccess && Response.IsValid() && Response->GetResponseCode() == EHttpResponseCodes::Ok)
		{
			OnLiveBuildIdReceived(true, Response->GetContentAsString().TrimStartAndEnd());
		}
		else
		{
			OnLiveBuildIdReceived(false, FString());
		}
	});
	Request->ProcessRequest();
}

void UPatchSubsystem::OnLiveBuildIdReceived(bool bSuccess, const FString& BuildId)
{
	if (!bSuccess || BuildId.IsEmpty())
	{
		UE_LOG(LogTemp, Warning, TEXT("[PatchSubsystem] Failed to fetch Live.txt; using cached/base build."));
		return;
	}

	TSharedRef<FChunkDownloader> Downloader = FChunkDownloader::GetChecked();
	Downloader->UpdateBuild(DeploymentName, BuildId, [this](bool bManifestSuccess)
	{
		OnManifestUpdated(bManifestSuccess);
	});
}

void UPatchSubsystem::OnManifestUpdated(bool bSuccess)
{
	if (!bSuccess)
	{
		UE_LOG(LogTemp, Warning, TEXT("[PatchSubsystem] Manifest update failed."));
		return;
	}

	bManifestUpToDate = true;
	UE_LOG(LogTemp, Log, TEXT("[PatchSubsystem] Manifest up to date; starting patch."));
	StartPatch();
}

void UPatchSubsystem::StartPatch()
{
	if (bPatchStarted)
	{
		return;
	}
	bPatchStarted = true;

	TSharedRef<FChunkDownloader> Downloader = FChunkDownloader::GetChecked();

	TArray<int32> ChunkList;
	Downloader->GetAllChunkIds(ChunkList);
	if (ChunkList.Num() == 0)
	{
		UE_LOG(LogTemp, Log, TEXT("[PatchSubsystem] No chunks in manifest; nothing to patch."));
		OnPatchComplete.Broadcast(true);
		return;
	}

	bPatching = true;
	UE_LOG(LogTemp, Log, TEXT("[PatchSubsystem] Downloading %d chunk(s)."), ChunkList.Num());
	Downloader->DownloadChunks(ChunkList, [this](bool bDownloadSuccess)
	{
		OnChunksDownloaded(bDownloadSuccess);
	}, 1);
}

void UPatchSubsystem::OnChunksDownloaded(bool bSuccess)
{
	if (!bSuccess)
	{
		UE_LOG(LogTemp, Error, TEXT("[PatchSubsystem] Chunk download failed."));
		bPatching = false;
		OnPatchComplete.Broadcast(false);
		return;
	}

	TSharedRef<FChunkDownloader> Downloader = FChunkDownloader::GetChecked();
	TArray<int32> ChunkList;
	Downloader->GetAllChunkIds(ChunkList);
	Downloader->MountChunks(ChunkList, [this](bool bMountSuccess)
	{
		OnChunksMounted(bMountSuccess);
	});
}

void UPatchSubsystem::OnChunksMounted(bool bSuccess)
{
	UE_LOG(LogTemp, Log, TEXT("[PatchSubsystem] Chunk mount %s."), bSuccess ? TEXT("OK") : TEXT("FAILED"));
	bPatching = false;
	OnPatchComplete.Broadcast(bSuccess);
}

float UPatchSubsystem::GetPatchProgress() const
{
	TSharedPtr<FChunkDownloader> Downloader = FChunkDownloader::Get();
	if (!Downloader.IsValid())
	{
		return 0.f;
	}

	const FChunkDownloader::FStats& Stats = Downloader->GetLoadingStats();
	const int32 TotalUnits = Stats.TotalFilesToDownload + Stats.TotalChunksToMount;
	if (TotalUnits <= 0)
	{
		return 0.f;
	}

	const int32 DoneUnits = Stats.FilesDownloaded + Stats.ChunksMounted;
	return static_cast<float>(DoneUnits) / static_cast<float>(TotalUnits);
}
