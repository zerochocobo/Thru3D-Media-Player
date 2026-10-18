extends SceneTree
const Narration := preload("res://scripts/narration_settings.gd")
const I18n := preload("res://scripts/i18n.gd")
var checks := 0
var failures: Array[String] = []
func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)
func _initialize() -> void:
	check(Narration.FEATURE_ENABLED, "Narration is enabled in normal builds")
	for sample in [
		[{"state": "loading", "model_phase": "verifying"}, "verifying"],
		[{"state": "loading", "model_phase": "loading"}, "model_loading"],
		[{"state": "loading", "model_ready": true}, "preparing"],
		[{"state": "ready", "preview": true, "synthesizing": true}, "preview_buffering"],
		[{"state": "ready", "timeline_reading": true}, "subtitle_loading"],
		[{"state": "ready", "startup_hold": true, "cached_seconds": 4, "synthesizing": true}, "preparing"],
		[{"state": "ready"}, "ready"],
		[{"state": "speaking"}, "speaking"],
		[{"state": "model_missing"}, "model_missing"],
		[{"state": "model_error"}, "model_error"],
		[{"state": "timeline_error"}, "timeline_error"],
		[{"state": "speech_error"}, "speech_error"]]:
		check(Narration.display_status(sample[0]) == sample[1], "Stage identity: " + sample[1])
		check(not Narration.status_label(sample[1]).is_empty(), "Normal builds show loading and playback stages")
	Narration.FEATURE_ENABLED = true
	check(Narration.progress_percent({"state":"loading","model_phase":"verifying","model_bytes":100,"model_verified_bytes":57}) == 50, "Verified bytes produce coarse progress")
	check(Narration.progress_percent({"state":"ready","startup_hold":true,"buffer_goal_seconds":16,"buffered_seconds":8}) == 50, "Prepared audio progresses while transport is held")
	check(Narration.progress_percent({"state":"loading","model_phase":"loading"}) == -1, "Session creation does not invent a percentage")
	check(Narration.display_status({"state":"speaking","timeline_indexing":true})=="subtitle_loading","Whole-track extraction remains visible while speech plays")
	check(Narration.progress_percent({"state":"speaking","timeline_indexing":true,"timeline_index_fraction":.57})==50,"Subtitle index reports covered timeline progress")
	check(Narration.progress_percent({"state":"ready","startup_hold":true,"buffer_goal_seconds":16,"buffered_seconds":99}) == 100, "Progress is bounded")
	for language in ["zh", "zh_Hant", "ja", "en"]:
		I18n.use(language)
		for stage in ["verifying", "model_loading", "preparing", "preview_buffering", "subtitle_loading", "ready", "speaking"]:
			var label := Narration.status_label(stage)
			check(not label.is_empty(), "Visible stage: " + language + stage)
			if language != "en": check(I18n.t(label) != label, "Localized stage: " + language + stage)
	Narration.FEATURE_ENABLED = false
	for failure in failures: push_error(failure)
	print("Narration stage checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
