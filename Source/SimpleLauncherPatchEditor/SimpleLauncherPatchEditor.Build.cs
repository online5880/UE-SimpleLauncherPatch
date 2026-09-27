using UnrealBuildTool;

public class SimpleLauncherPatchEditor : ModuleRules
{
    public SimpleLauncherPatchEditor(ReadOnlyTargetRules Target) : base(Target)
    {
        PCHUsage = PCHUsageMode.UseExplicitOrSharedPCHs;
        PrivateDependencyModuleNames.AddRange(new[] { "Core", "CoreUObject", "Engine", "AssetRegistry", "Projects", "Slate", "SlateCore", "UnrealEd", "WorkspaceMenuStructure" });
    }
}
