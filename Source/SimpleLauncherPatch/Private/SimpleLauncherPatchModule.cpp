#include "SimpleLauncherPatchModule.h"

#define LOCTEXT_NAMESPACE "FSimpleLauncherPatchModule"

void FSimpleLauncherPatchModule::StartupModule()
{
}

void FSimpleLauncherPatchModule::ShutdownModule()
{
}

#undef LOCTEXT_NAMESPACE

IMPLEMENT_MODULE(FSimpleLauncherPatchModule, SimpleLauncherPatch)
