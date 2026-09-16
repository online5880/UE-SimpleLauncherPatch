# Dumps PatchChunk_1001 label properties to verify what actually got saved.
import unreal

asset = unreal.load_asset("/Game/Variant_Combat/PatchChunk_1001")
if asset is None:
    raise RuntimeError("label asset not found")

unreal.log("LABELDUMP class=%s" % asset.get_class().get_name())
unreal.log("LABELDUMP label_assets_in_my_directory=%s" % asset.get_editor_property("label_assets_in_my_directory"))
rules = asset.get_editor_property("rules")
unreal.log("LABELDUMP rules.cook_rule=%s" % rules.get_editor_property("cook_rule"))
unreal.log("LABELDUMP rules.chunk_id=%s" % rules.get_editor_property("chunk_id"))
try:
    unreal.log("LABELDUMP rules.apply_recursively=%s" % rules.get_editor_property("apply_recursively"))
except Exception as e:
    unreal.log("LABELDUMP rules.apply_recursively=<not exposed: %s>" % e)
