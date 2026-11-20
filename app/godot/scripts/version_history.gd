@tool
extends RefCounted

const PAGE := "https://thru3d.com/changelog.html"
const SECTION := "version_history"
const LEGACY_REPORT := "user://diagnostics/capabilities_latest.json"

const DATA := "res://data/release_notes.json"

static func locale(language: String) -> String:
	return language if language in ["en", "zh", "zh_Hant", "ja"] else "en"

static func url(language: String) -> String:
	return PAGE + "?lang=" + ("zh" if language == "zh_Hant" else locale(language))

static func valid_version(value: String) -> bool:
	var parts := value.split(".")
	return parts.size() >= 2 and Array(parts).all(func(p: String): return not p.is_empty() and p.is_valid_int() and p[0] not in ["+", "-"])

static func compare(a: String, b: String) -> int:
	var left := a.split(".")
	var right := b.split(".")
	for i in maxi(left.size(), right.size()):
		var delta := (int(left[i]) if i < left.size() else 0) - (int(right[i]) if i < right.size() else 0)
		if delta != 0: return signi(delta)
	return 0

## An inclusive lower bound is only needed when old preferences have no known version.
static func unread(version: String, lower: String) -> bool:
	if lower.is_empty(): return false
	if lower.begins_with("="): return compare(version, lower.substr(1)) >= 0
	return compare(version, lower) > 0

## Called immediately after loading preferences, before any first-run defaults are saved.
static func record_launch(config: ConfigFile, version: String, legacy_report: String = LEGACY_REPORT) -> bool:
	var previous := str(config.get_value(SECTION, "last_used_version", ""))
	if not valid_version(version) or previous == version: return false
	var returning_user := not config.get_sections().is_empty()
	if previous.is_empty() and FileAccess.file_exists(legacy_report):
		var report := JSON.new()
		if report.parse(FileAccess.get_file_as_string(legacy_report)) == OK and report.data is Dictionary:
			previous = str(report.data.get("app_version", ""))
	config.set_value(SECTION, "last_used_version", version)
	var lower := str(config.get_value(SECTION, "unread_from", ""))
	if not valid_version(previous):
		lower = "=" + version if returning_user else ""
	elif compare(version, previous) > 0 and lower.is_empty():
		lower = previous
	elif not unread(version, lower):
		lower = ""
	config.set_value(SECTION, "unread_from", lower)
	return true

static func device(platform: Object) -> Dictionary:
	var vendor := "quest" if OS.has_feature("quest") else "pico" if OS.has_feature("pico") else "openxr" if OS.has_feature("android") else ""
	var runtime := ""
	if vendor in ["pico", "quest"]:
		runtime = "other"
	elif preload("res://scripts/platform_methods.gd").supports(platform, "video_layer_qiyu_passthrough") and platform.video_layer_qiyu_passthrough():
		runtime = "qiyu"
	elif vendor == "openxr":
		var xr := XRServer.find_interface("OpenXR") as OpenXRInterface
		if xr and xr.is_initialized():
			var info := xr.get_system_info()
			var system := str(info.get("OpenXRSystemName", "")).strip_edges().to_lower()
			var name := str(info.get("XRRuntimeName", "")).to_lower()
			if "qiyu" in name or "qiyu" in system: runtime = "qiyu"
			elif not system.is_empty(): runtime = "other"
	return {"vendor": vendor, "channel": preload("res://scripts/distribution_channel.gd").current(), "runtime": runtime}

static func applies(scope: Array, context: Dictionary) -> bool:
	if scope.is_empty(): return true
	for tag in scope:
		match tag:
			"quest", "pico", "openxr":
				if context.vendor in ["", tag]: return true
			"pico_cn_store":
				if context.vendor in ["", "pico"] and context.channel in ["", tag]: return true
			"qiyu":
				if context.vendor in ["", "openxr"] and context.runtime in ["", tag]: return true
			_: return true
	return false

static func localized_notes(row: Dictionary, lang: String, context: Dictionary = {}) -> PackedStringArray:
	var notes := PackedStringArray()
	if not row.title.get(lang) is String or row.title[lang].strip_edges().is_empty(): return notes
	var items: Variant = row.get("items")
	if items == null and row.get("notes") is Dictionary: items = row.notes.get(lang)
	if not items is Array: return notes
	for item in items:
		var value: Variant = item.get("text") if item is Dictionary else item
		if value is Dictionary: value = value.get(lang)
		if not value is String or value.strip_edges().is_empty(): return PackedStringArray()
		if context.is_empty() or item is String or applies(item.get("scope", []), context):
			notes.append(value)
	return notes

static func visible_entries(catalog: Array, installed: String, language: String, context: Dictionary) -> Array:
	var result := []
	var lang := locale(language)
	for row: Dictionary in catalog:
		if compare(row.version, installed) > 0: continue
		var notes := localized_notes(row, lang, context)
		if not notes.is_empty():
			var title: String = row.title[lang]
			if row.has("filteredTitle") and notes.size() < localized_notes(row, lang).size():
				title = row.filteredTitle[lang]
			result.append({"version": row.version, "date": row.date, "title": title, "notes": notes})
	return result
