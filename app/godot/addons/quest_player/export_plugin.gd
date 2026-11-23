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
	const History := preload("res://scripts/version_history.gd")

	func _get_name() -> String:
		return "QuestPlayer"

	func _supports_platform(platform: EditorExportPlatform) -> bool:
		return platform is EditorExportPlatformAndroid

	func _export_file(path: String, _type: String, _features: PackedStringArray) -> void:
		if path != History.DATA: return
		var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
		var version := str(ProjectSettings.get_setting("application/config/version"))
		data.entries = data.entries.filter(func(row): return History.compare(row.version, version) <= 0)
		add_file(path, JSON.stringify(data).to_utf8_buffer(), false)
		skip()

	# Build-Player declares the layer-extension GDExtension for Android exports only (its library is in
	# the plugin AAR). Godot lists it in the exported extension list; the declaration itself must ship too.
	func _export_begin(_features: PackedStringArray, _is_debug: bool, _path: String, _flags: int) -> void:
		const DECLARATION := "res://addons/quest_player/layer_extensions.gdextension"
		if FileAccess.file_exists(DECLARATION):
			add_file(DECLARATION, FileAccess.get_file_as_bytes(DECLARATION), false)

	func _get_android_libraries(_platform: EditorExportPlatform, debug: bool) -> PackedStringArray:
		return PackedStringArray(["res://addons/quest_player/bin/player-plugin-%s.aar" % ("debug" if debug else "release"), "res://addons/quest_player/bin/web-browser-%s.aar" % ("debug" if debug else "release"), "res://addons/quest_player/bin/cloudcore.aar"])

	# iQIYI QIYU's package manager calls a package a VR application (and schedules it as one) only
	# when it carries this flag; the standard OpenXR package is the one QIYU headsets install.
	# Quest and PICO packages stay free of it (Build-Player rejects them otherwise).
	func _get_android_manifest_application_element_contents(_platform: EditorExportPlatform, _debug: bool) -> String:
		if not get_option("xr_features/enable_khronos_plugin"): return ""
		return "        <meta-data android:name=\"qiyu-sdk-flag\" android:value=\"true\" />\n"

	func _get_android_dependencies_maven_repos(_platform: EditorExportPlatform, _debug: bool) -> PackedStringArray:
		if OS.has_environment("THRU3D_PROBE_MAVEN"):
			return PackedStringArray([OS.get_environment("THRU3D_PROBE_MAVEN"), "https://maven.mozilla.org/maven2/"])
		return PackedStringArray(["https://maven.mozilla.org/maven2/"])

	func _get_android_dependencies(_platform: EditorExportPlatform, _debug: bool) -> PackedStringArray:
		# The AAR embeds jcifs without the unused HTTP NTLM adapters. Resolve only
		# its unchanged runtime dependencies here, never the original full jcifs jar.
		var gecko := "org.mozilla.geckoview:geckoview-arm64-v8a:159.0.20261022150525"
		if OS.has_environment("THRU3D_PROBE_MAVEN"):
			gecko = OS.get_environment("THRU3D_PROBE_COORDINATE")
		return PackedStringArray(["androidx.media3:media3-exoplayer:1.11.1", "com.squareup.okhttp3:okhttp:4.12.0", "org.slf4j:slf4j-api:1.7.36", "org.bouncycastle:bcprov-jdk18on:1.85", "io.github.junkfood02.youtubedl-android:library:0.18.1", gecko])
