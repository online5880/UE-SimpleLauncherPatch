import unreal

# Label placed inside /Game/Variant_Combat so the whole folder's assets get labeled
# into patchable chunk 1001 (b_label_assets_in_my_directory).
LABEL_PATH = "/Game/Variant_Combat"
LABEL_NAME = "PatchChunk_1001"
CHUNK_ID = 1001


def get_factory():
    if hasattr(unreal, "PrimaryAssetLabelFactory"):
        return unreal.PrimaryAssetLabelFactory()
    if hasattr(unreal, "DataAssetFactory"):
        return unreal.DataAssetFactory()
    return None


asset_tools = unreal.AssetToolsHelpers.get_asset_tools()
asset_path = f"{LABEL_PATH}/{LABEL_NAME}"
if unreal.EditorAssetLibrary.does_asset_exist(asset_path):
    unreal.log(f"[Patch] {asset_path} already exists")
else:
    asset = asset_tools.create_asset(LABEL_NAME, LABEL_PATH, unreal.PrimaryAssetLabel, get_factory())
    if asset is None:
        raise RuntimeError(f"[Patch] Failed to create label asset {asset_path}")
    asset.set_editor_property("label_assets_in_my_directory", True)
    rules = unreal.PrimaryAssetRules()
    rules.set_editor_property("cook_rule", unreal.PrimaryAssetCookRule.ALWAYS_COOK)
    rules.set_editor_property("chunk_id", CHUNK_ID)
    asset.set_editor_property("rules", rules)
    if not unreal.EditorAssetLibrary.save_loaded_asset(asset):
        raise RuntimeError(f"[Patch] Failed to save {asset_path}")
    unreal.log(f"[Patch] Created {asset_path} (chunk {CHUNK_ID})")
