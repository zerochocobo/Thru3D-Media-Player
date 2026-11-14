extends RefCounted
## HDR to SDR: one global video preference shared by the library and playback settings.
## Unset follows the headset: Meta's compositor shows HDR10/HLG surfaces close to SDR (Quest 3,
## 2026-11-13; Quest 2 untested), so Off there; PICO shows them washed out, so On elsewhere.
const TITLE := "HDR to SDR"
const ON := "on"
const OFF := "off"

static func normalize(value: Variant) -> String:
	return str(value) if str(value) in [ON, OFF] else ""

static func default_mode(compositor_shows_hdr: bool) -> String:
	return OFF if compositor_shows_hdr else ON

static func choice(value: String) -> Dictionary:
	return {"key": "hdr_to_sdr", "value": OFF if value == OFF else ON, "choices": [
		{"value": ON, "label": "On", "hint": "Converts HDR videos so colors do not look washed out"},
		{"value": OFF, "label": "Off", "hint": "Shows HDR videos unconverted; colors may look washed out"}]}
