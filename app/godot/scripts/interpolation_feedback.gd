extends RefCounted
## A shared readout for the picture controls, the FPS overlay and its one-time playback preview.
const I18n := preload("res://scripts/i18n.gd")
const WINDOW_MS := 1000
const PREVIEW_MS := 10_000
const STOP_NOTICE_MS := 3000

var _open := -1
var _epoch: Array = []
var _state := ""
var _source := 0.0
var _rate := 0
var _start := -1
var _total := 0
var _between := 0
var _last_sample := -1
var _last_fresh := -1
var _remaining := 0
var _shown_since := -1

func update(sample: Dictionary, now: int) -> void:
	var open := int(sample.get("open", -1))
	var state := str(sample.get("state", ""))
	var epoch: Array = sample.get("epoch", [])
	if open != _open or (_state == "stopped" and state != "stopped"):
		_remaining = PREVIEW_MS if open >= 0 else 0
		_shown_since = -1
	if state == "stopped" and (_state != state or open != _open):
		_remaining = STOP_NOTICE_MS
		_shown_since = -1
	if open != _open or epoch != _epoch or state != _state or not sample.has("total"):
		_start = -1
		_rate = 0
		_last_sample = -1
	_open = open
	_epoch = epoch
	_state = state
	_source = float(sample.get("source", 0.0))
	if not sample.has("total"): return
	var at := int(sample.time)
	if at == _last_sample:
		if now - _last_fresh > WINDOW_MS: _rate = 0; _start = -1
		return
	_last_sample = at
	_last_fresh = now
	var total := int(sample.total)
	var between := int(sample.between)
	var elapsed := at - _start
	if _start < 0 or elapsed < 0 or elapsed > 2 * WINDOW_MS or total < _total or between < _between:
		_rate = 0
	elif elapsed < WINDOW_MS: return
	else:
		_rate = roundi((total - _total) * 1000.0 / elapsed) if between > _between else 0
	_start = at
	_total = total
	_between = between

func caption() -> String:
	match _state:
		"stopped": return I18n.t("Frame interpolation stopped")
		"paused": return I18n.t("Paused")
		"buffering": return I18n.t("Buffering…")
		"", "unavailable": return ""
	if _rate <= 0: return I18n.t("Waiting for frame interpolation…")
	if _source <= 0.0: return I18n.t("Interpolation · Output %d FPS") % _rate
	return I18n.t("Interpolation · Source %d → Output %d FPS") % [roundi(_source), _rate]

func preview_pending() -> bool:
	return _remaining > 0

## Charge only time for which the preview owned the HUD. Opening a menu suspends the balance.
func preview(now: int, can_show: bool, permanent: bool) -> String:
	if _shown_since >= 0:
		_remaining = maxi(0, _remaining - (now - _shown_since))
	_shown_since = -1
	if permanent: _remaining = 0
	if _remaining == 0 or not can_show or (_rate <= 0 and _state != "stopped"): return ""
	_shown_since = now
	return caption()
