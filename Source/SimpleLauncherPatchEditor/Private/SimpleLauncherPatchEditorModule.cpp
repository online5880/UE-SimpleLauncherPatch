#include "Modules/ModuleManager.h"

#include "AssetRegistry/AssetRegistryModule.h"
#include "AssetRegistry/AssetData.h"
#include "Containers/Ticker.h"
#include "Engine/PrimaryAssetLabel.h"
#include "Framework/Docking/TabManager.h"
#include "HAL/PlatformTime.h"
#include "Misc/AutomationTest.h"
#include "Misc/CommandLine.h"
#include "Misc/ConfigCacheIni.h"
#include "Misc/FileHelper.h"
#include "Misc/Parse.h"
#include "Misc/MonitoredProcess.h"
#include "Misc/Paths.h"
#include "Misc/PackageName.h"
#include "Interfaces/IPluginManager.h"
#include "Widgets/Docking/SDockTab.h"
#include "Widgets/Input/SButton.h"
#include "Widgets/Layout/SBox.h"
#include "Widgets/Layout/SScrollBox.h"
#include "Widgets/Text/STextBlock.h"
#include "WorkspaceMenuStructure.h"
#include "WorkspaceMenuStructureModule.h"

#define LOCTEXT_NAMESPACE "SimpleLauncherPatchEditor"

DEFINE_LOG_CATEGORY_STATIC(LogSimpleLauncherPatchEditor, Log, All);

class FSimpleLauncherPatchEditorModule final : public IModuleInterface
{
public:
    virtual void StartupModule() override
    {
        FGlobalTabmanager::Get()->RegisterNomadTabSpawner("SimpleLauncherPatchPublisher",
            FOnSpawnTab::CreateRaw(this, &FSimpleLauncherPatchEditorModule::SpawnTab))
            .SetDisplayName(LOCTEXT("TabName", "Simple Launcher Patch"))
            .SetTooltipText(LOCTEXT("TabTooltip", "Check settings and publish a local launcher build"))
            .SetGroup(WorkspaceMenu::GetMenuStructure().GetToolsCategory());
    }

    virtual void ShutdownModule() override
    {
        FGlobalTabmanager::Get()->UnregisterNomadTabSpawner("SimpleLauncherPatchPublisher");
        FTSTicker::GetCoreTicker().RemoveTicker(TickerHandle);
        if (Process)
        {
            Process->Cancel(true);
            Process.Reset();
        }
    }

private:
    friend class FSimpleLauncherPatchLocalPublishE2ETest;
    TUniquePtr<FMonitoredProcess> Process;
    FTSTicker::FDelegateHandle TickerHandle;
    TSharedPtr<SButton> CheckButton;
    TSharedPtr<SButton> PublishButton;
    FString Status = TEXT("'Check settings' to inspect this project.");

    FString ScriptPath() const
    {
        const TSharedPtr<IPlugin> Plugin = IPluginManager::Get().FindPlugin(TEXT("SimpleLauncherPatch"));
        return Plugin.IsValid() ? FPaths::ConvertRelativePathToFull(Plugin->GetBaseDir() / TEXT("Tools/Scripts/Publish-Patch.ps1")) : FString();
    }

    FString CloudPath() const
    {
        return FPaths::ConvertRelativePathToFull(FPaths::ProjectSavedDir() / TEXT("SimpleLauncherPatch/Cloud"));
    }

    FString CheckSettings() const
    {
        TArray<FString> Problems;
        const FString Project = FPaths::GetProjectFilePath();
        if (!FPaths::FileExists(Project)) Problems.Add(TEXT("Project .uproject file not found"));
        if (!FPaths::FileExists(ScriptPath())) Problems.Add(TEXT("Publish-Patch.ps1 not found in the installed plugin"));

        FString DefaultMap;
        GConfig->GetString(TEXT("/Script/EngineSettings.GameMapsSettings"), TEXT("GameDefaultMap"), DefaultMap, GEngineIni);
        FString MapPackage;
        if (!DefaultMap.Split(TEXT("."), &MapPackage, nullptr)) MapPackage = DefaultMap;
        if (MapPackage.IsEmpty() || !FPackageName::DoesPackageExist(MapPackage))
        {
            Problems.Add(TEXT("GameDefaultMap does not point to a saved map"));
        }

        bool bGenerateChunks = false;
        bool bUseIoStore = true;
        GConfig->GetBool(TEXT("/Script/UnrealEd.ProjectPackagingSettings"), TEXT("bGenerateChunks"), bGenerateChunks, GGameIni);
        GConfig->GetBool(TEXT("/Script/UnrealEd.ProjectPackagingSettings"), TEXT("bUseIoStore"), bUseIoStore, GGameIni);
        if (!bGenerateChunks) Problems.Add(TEXT("Packaging: Generate Chunks must be enabled"));
        if (bUseIoStore) Problems.Add(TEXT("Packaging: Use Io Store must be disabled"));

        bool bHasPatchLabel = false;
        IAssetRegistry& Registry = FModuleManager::LoadModuleChecked<FAssetRegistryModule>("AssetRegistry").Get();
        TArray<FAssetData> Labels;
        Registry.GetAssetsByClass(UPrimaryAssetLabel::StaticClass()->GetClassPathName(), Labels);
        for (const FAssetData& Asset : Labels)
        {
            if (!Asset.PackageName.ToString().StartsWith(TEXT("/Game/"))) continue;
            const UPrimaryAssetLabel* Label = Cast<UPrimaryAssetLabel>(Asset.GetAsset());
            if (Label && Label->Rules.ChunkId >= 1 && Label->Rules.CookRule == EPrimaryAssetCookRule::AlwaysCook)
            {
                bHasPatchLabel = true;
                break;
            }
        }
        if (!bHasPatchLabel) Problems.Add(TEXT("No Always Cook Primary Asset Label with Chunk ID >= 1"));
        return Problems.IsEmpty() ? TEXT("Ready. Local output: ") + CloudPath() : FString::Join(Problems, TEXT("\n"));
    }

    void OnCheck() { Status = CheckSettings(); }

    void OnPublish()
    {
        Status = CheckSettings();
        if (!Status.StartsWith(TEXT("Ready.")) || Process) return;

        const FString Project = FPaths::ConvertRelativePathToFull(FPaths::GetProjectFilePath());
        const FString EngineRoot = FPaths::ConvertRelativePathToFull(FPaths::EngineDir() / TEXT(".."));
        const FString Params = FString::Printf(TEXT("-NoProfile -NonInteractive -File \"%s\" -Project \"%s\" -EngineRoot \"%s\" -CloudRoot \"%s\" -Full -SkipHealthCheck"),
            *ScriptPath(), *Project, *EngineRoot, *CloudPath());
        Process = MakeUnique<FMonitoredProcess>(TEXT("pwsh.exe"), Params, FPaths::ProjectDir(), true);
        Process->OnOutput().BindStatic([](FString Line) { UE_LOG(LogSimpleLauncherPatchEditor, Display, TEXT("%s"), *Line); });
        if (!Process->Launch())
        {
            Process.Reset();
            Status = TEXT("Could not start PowerShell 7 (pwsh.exe). Install it or add it to PATH.");
            return;
        }
        Status = TEXT("Building and publishing locally. Progress is in Output Log (SimpleLauncherPatchEditor).");
        TickerHandle = FTSTicker::GetCoreTicker().AddTicker(FTickerDelegate::CreateLambda([this](float)
        {
            if (!Process) return false;
            if (Process->Update()) return true;
            const int32 ExitCode = Process->GetReturnCode();
            Process.Reset();
            Status = ExitCode == 0 ? TEXT("Local publish complete: ") + CloudPath()
                : FString::Printf(TEXT("Publish failed (exit %d). See Output Log."), ExitCode);
            return false;
        }), 0.5f);
    }

    TSharedRef<SDockTab> SpawnTab(const FSpawnTabArgs&)
    {
        return SNew(SDockTab).TabRole(ETabRole::NomadTab)
        [
            SNew(SBox).Padding(16)
            [
                SNew(SScrollBox)
                + SScrollBox::Slot()
                [
                    SNew(STextBlock).Text(LOCTEXT("Intro", "Check the project, then build the game and launcher into Saved/SimpleLauncherPatch/Cloud. Nothing is uploaded."))
                        .AutoWrapText(true)
                ]
                + SScrollBox::Slot().Padding(0, 12)
                [
                    SAssignNew(CheckButton, SButton).Text(LOCTEXT("Check", "Check settings"))
                        .OnClicked_Lambda([this]() { OnCheck(); return FReply::Handled(); })
                ]
                + SScrollBox::Slot()
                [
                    SAssignNew(PublishButton, SButton).Text(LOCTEXT("Publish", "Build and publish locally"))
                        .IsEnabled_Lambda([this]() { return !Process; })
                        .OnClicked_Lambda([this]() { OnPublish(); return FReply::Handled(); })
                ]
                + SScrollBox::Slot().Padding(0, 12)
                [
                    SNew(STextBlock).Text_Lambda([this]() { return FText::FromString(Status); }).AutoWrapText(true)
                ]
            ]
        ];
    }
};

IMPLEMENT_MODULE(FSimpleLauncherPatchEditorModule, SimpleLauncherPatchEditor)

#if WITH_DEV_AUTOMATION_TESTS
IMPLEMENT_SIMPLE_AUTOMATION_TEST(FSimpleLauncherPatchLocalPublishE2ETest,
    "SimpleLauncherPatch.Editor.LocalPublish", EAutomationTestFlags::EditorContext | EAutomationTestFlags::ProductFilter)

bool FSimpleLauncherPatchLocalPublishE2ETest::RunTest(const FString&)
{
    // Opt-in: this test builds and publishes a full game into the current project.
    if (!FParse::Param(FCommandLine::Get(), TEXT("SimpleLauncherPatchE2E"))) return true;
    FSimpleLauncherPatchEditorModule& Module = FModuleManager::LoadModuleChecked<FSimpleLauncherPatchEditorModule>("SimpleLauncherPatchEditor");
    const TSharedPtr<SDockTab> Tab = FGlobalTabmanager::Get()->TryInvokeTab(FName(TEXT("SimpleLauncherPatchPublisher")));
    if (!TestTrue(TEXT("Publisher tab opens"), Tab.IsValid()) ||
        !TestTrue(TEXT("Both buttons exist"), Module.CheckButton.IsValid() && Module.PublishButton.IsValid())) return false;

    Module.CheckButton->SimulateClick();
    if (!TestTrue(TEXT("Project settings are ready"), Module.Status.StartsWith(TEXT("Ready."))))
    {
        AddError(Module.Status);
        return false;
    }
    Module.PublishButton->SimulateClick();
    if (!TestTrue(TEXT("Local publisher starts"), Module.Process.IsValid()))
    {
        AddError(Module.Status);
        return false;
    }

    const double Deadline = FPlatformTime::Seconds() + 900.0;
    ADD_LATENT_AUTOMATION_COMMAND(FFunctionLatentCommand([this, &Module, Deadline]()
    {
        if (Module.Process)
        {
            if (FPlatformTime::Seconds() < Deadline) return false;
            Module.Process->Cancel(true);
            AddError(TEXT("Local publish timed out after 15 minutes"));
            return true;
        }
        if (!TestTrue(TEXT("Publisher reports success"), Module.Status.StartsWith(TEXT("Local publish complete:"))))
        {
            AddError(Module.Status);
            return true;
        }
        const FString Cloud = Module.CloudPath();
        FString Live;
        FString Full;
        if (!TestTrue(TEXT("Live pointer exists"), FFileHelper::LoadFileToString(Live, *(Cloud / TEXT("Live.txt"))))) return true;
        if (!TestTrue(TEXT("Full pointer exists"), FFileHelper::LoadFileToString(Full, *(Cloud / TEXT("Full/FullVersion.txt"))))) return true;
        Live.TrimStartAndEndInline();
        Full.TrimStartAndEndInline();
        TestEqual(TEXT("Pointers target the same release"), Live, Full);
        TestTrue(TEXT("Patch manifest exists"), FPaths::FileExists(Cloud / Live / TEXT("BuildManifest-Windows.txt")));
        TestTrue(TEXT("Full manifest exists"), FPaths::FileExists(Cloud / TEXT("Full") / Live / TEXT("FullManifest.txt")));
        TestTrue(TEXT("Launcher exists"), FPaths::FileExists(Cloud / TEXT("Full/Launcher.exe")));
        return true;
    }));
    return true;
}
#endif

#undef LOCTEXT_NAMESPACE
