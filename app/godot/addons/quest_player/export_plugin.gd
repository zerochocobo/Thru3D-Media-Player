@tool
extends EditorPlugin

var android_export: QuestPlayerExport

func _enter_tree() -> void:
	android_export = QuestPlayerExport.new()
	add_export_plugin(android_export)

func _exit_tree() -> void:
	remove_export_plugin(android_export)
	android_export = null

class QuestPlayerExport extends EditorExportPlugin:
	var exclude_beach_models := false

	func _get_name() -> String:
		return "QuestPlayer"

	func _supports_platform(platform: EditorExportPlatform) -> bool:
		return platform is EditorExportPlatformAndroid

	# Build-Player declares the layer-extension GDExtension for Android exports only (its library is in
	# the plugin AAR). Godot lists it in the exported extension list; the declaration itself must ship too.
	func _export_begin(_features: PackedStringArray, _is_debug: bool, _path: String, _flags: int) -> void:
		# Build-Player -IncludePrivateBeach opts one Debug build in; every other export excludes it.
		exclude_beach_models = OS.get_environment("THRU3D_INCLUDE_PRIVATE_BEACH") != "1"
		if exclude_beach_models:
			add_file("res://environments/private_beach_debug_excluded.txt", "private_beach_models_excluded_v1\n".to_utf8_buffer(), false)
		const DECLARATION := "res://addons/quest_player/layer_extensions.gdextension"
		if FileAccess.file_exists(DECLARATION):
			add_file(DECLARATION, FileAccess.get_file_as_bytes(DECLARATION), false)

	func _export_file(path: String, _type: String, _features: PackedStringArray) -> void:
		# Modeling remains available to desktop studies, outside ordinary packages.
		# skip() also omits imported mesh/texture payloads and remaps.
		if exclude_beach_models and path.begins_with("res://environments/private_beach/"):
			skip()

	func _get_android_libraries(_platform: EditorExportPlatform, debug: bool) -> PackedStringArray:
		return PackedStringArray(["res://addons/quest_player/bin/player-plugin-%s.aar" % ("debug" if debug else "release"), "res://addons/quest_player/bin/web-browser-%s.aar" % ("debug" if debug else "release"), "res://addons/quest_player/bin/cloudcore.aar"])

	func _get_android_dependencies_maven_repos(_platform: EditorExportPlatform, _debug: bool) -> PackedStringArray:
		return PackedStringArray(["https://maven.mozilla.org/maven2/"])

	func _get_android_dependencies(_platform: EditorExportPlatform, _debug: bool) -> PackedStringArray:
		# The AAR embeds jcifs without the unused HTTP NTLM adapters. Resolve only
		# its unchanged runtime dependencies here, never the original full jcifs jar.
		return PackedStringArray(["androidx.media3:media3-exoplayer:1.11.1", "com.squareup.okhttp3:okhttp:4.12.0", "org.slf4j:slf4j-api:1.7.36", "org.bouncycastle:bcprov-jdk18on:1.85", "io.github.junkfood02.youtubedl-android:library:0.18.1", "org.mozilla.geckoview:geckoview-arm64-v8a:159.0.20261022150525"])
