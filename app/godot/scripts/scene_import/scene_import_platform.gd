extends RefCounted
## Connects the import pipeline to what this build can do natively. Safe to call more than once.
const Loader := preload("res://scripts/scene_import/scene_import_loader.gd")
const Unity := preload("res://scripts/scene_import/scene_import_unity.gd")
const Methods := preload("res://scripts/platform_methods.gd")
const DESKTOP_TOOL := "res://../../build/unity-scene/windows/unity_scene_unpack.exe"

static func configure() -> void:
	if Engine.has_singleton("QuestPlayer"):
		var plugin := Engine.get_singleton("QuestPlayer")
		# Plugin methods are not in the object's own method list; ask the way the rest of the player does.
		if not Unity.unpacker.is_valid() and Methods.supports(plugin, "unity_scene_unpack"):
			Unity.unpacker = func(bundle: String, output: String, max_texture: int, max_sky: int) -> String:
				return str(plugin.unity_scene_unpack(bundle, output, max_texture, max_sky))
		if not Loader.texture_encoder.is_valid() and Methods.supports(plugin, "scene_texture_etc2"):
			Loader.texture_encoder = func(rgba: PackedByteArray, width: int, height: int, alpha: bool) -> PackedByteArray:
				return plugin.scene_texture_etc2(rgba, width, height, alpha)
	elif Unity.unpacker_executable.is_empty() and not OS.has_feature("template"):
		# Desktop development runs use the command-line unpacker when it has been built.
		Unity.unpacker_executable = ProjectSettings.globalize_path(DESKTOP_TOOL)
