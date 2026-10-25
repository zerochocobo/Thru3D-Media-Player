extends RefCounted
## Display preference only. Never changes media disparity, IPD or saved file settings.
const KEY := "playback_menu_depth"
const DEFAULT := "default"
const MEDIUM := "medium"
const MONO := "mono"
const MODES := [DEFAULT, MEDIUM, MONO]
const TITLE := "VR control bar depth (Test)"

static func load_mode(settings: ConfigFile) -> String:
	var value: Variant = settings.get_value("ui", KEY, DEFAULT)
	return value if value is String and value in MODES else DEFAULT

static func choices() -> Array:
	return [{"value": DEFAULT, "label": "Default", "hint": "Control bar distance: 1.4 m (default)."},
		{"value": MEDIUM, "label": "Moderate", "hint": "Control bar distance: 3 m. Keeps the same apparent size."},
		{"value": MONO, "label": "No parallax", "hint": "No binocular parallax for the control bar and its popups. The video is unchanged."}]

static func factor(mode: String) -> float:
	return 3.0 / 1.4 if mode == MEDIUM else 1.0

static func place(pose: Transform3D, head: Transform3D, mode: String) -> Transform3D:
	var scale := factor(mode)
	return Transform3D(pose.basis.scaled(Vector3.ONE * scale), head.origin + (pose.origin - head.origin) * scale)
