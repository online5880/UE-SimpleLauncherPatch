using UnrealBuildTool;

public class SimpleLauncherPatch : ModuleRules
{
	public SimpleLauncherPatch(ReadOnlyTargetRules Target) : base(Target)
	{
		PCHUsage = ModuleRules.PCHUsageMode.UseExplicitOrSharedPCHs;

		PublicDependencyModuleNames.AddRange(
			new string[]
			{
				"Core",
				"CoreUObject",
				"Engine"
			}
		);

		PrivateDependencyModuleNames.AddRange(
			new string[]
			{
				"ChunkDownloader",
				"HTTP"
			}
		);
	}
}
