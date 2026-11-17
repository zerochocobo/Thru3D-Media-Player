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
		# Plain method callables, not lambdas: a lambda kept in another script's static var is
		# destroyed during engine shutdown after this script's mutex is gone and aborts the app.
		# Test them with is_null(), never is_valid(): the plugin's Java methods are not in the object's
		# method list, so is_valid() calls them missing and the hooks look absent (all of 11-16 to 11-17).
		if Unity.unpacker.is_null() and Methods.supports(plugin, "unity_scene_unpack"):
			Unity.unpacker = Callable(plugin, "unity_scene_unpack")
		if Loader.texture_encoder.is_null() and Methods.supports(plugin, "scene_texture_etc2"):
			Loader.texture_encoder = Callable(plugin, "scene_texture_etc2")
	elif Unity.unpacker_executable.is_empty() and not OS.has_feature("template"):
		# Desktop development runs use the command-line unpacker when it has been built.
		Unity.unpacker_executable = ProjectSettings.globalize_path(DESKTOP_TOOL)
