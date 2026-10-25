extends RefCounted

const NAMES := ["Standard", "Enhanced", "High"]
const SCALES := [1.0, 1.1, 1.25]
## -1 follows the device tier: Standard on low-end GPUs, Enhanced elsewhere.
const AUTO := -1
const DEFAULT := AUTO
const TIER_DEFAULT := 1
## Matches the compositor's two sharpening filters; the value is the shader strength off the layer.
const SHARPNESS := [0.0, 0.2, 0.6]
const SHARPNESS_NAMES := ["Off", "Normal", "Quality"]
## Photos keep gentle sharpening by default. Video starts without it: compositor sharpening on moving
## 8K made fine detail flicker and felt harsh (Quest 3 tester, 2026-10-25); Skybox/Pigasus do not sharpen.
## A saved choice still applies to both.
const DEFAULT_SHARPNESS := 0.2
const DEFAULT_VIDEO_SHARPNESS := 0.0
## Video output width: -1 follows the device tier, 0 keeps the source size.
const AUTO_OUTPUT := -1
## XR2 Gen1 class GPUs (Quest 2/Pro, PICO Neo3/4) lack the bandwidth to resample 8K60
## RGBA per eye pixel; 4K output and no sharpening keep their frame rate.
const LOW_END_OUTPUT_WIDTH := 4096
## Compositor supersampling of media layers: 0 off, 1 normal (the earlier fixed filter), 2 quality.
const SUPERSAMPLING_NAMES := ["Off", "Normal", "Quality"]
const DEFAULT_SUPERSAMPLING := 1

## Settings hover text: one sentence per setting, the numbers on each choice.
const SCALE_INFO := "Eye-buffer resolution for the 3D scene and shader-drawn media; normal video, photos and menus are unaffected."
const SCALE_HINTS := ["×1.0 per axis", "×1.1 per axis (1.21× pixels)", "×1.25 per axis (1.56× pixels)"]
const SCALE_AUTO_HINT := "×1.0 on Quest 2 / PICO Neo3 class GPUs, ×1.1 otherwise"
const SUPERSAMPLING_INFO := "Compositor filtering of video and photo layers when scaled down; reduces shimmer."
const SUPERSAMPLING_HINTS := ["No filtering, lowest GPU cost", "System normal supersampling", "Stronger filtering, higher GPU cost"]
const SHARPNESS_INFO := "Edge sharpening for video and photos, independent of supersampling."
const SHARPNESS_HINTS := ["No sharpening", "System normal sharpening; shader strength 0.2", "System quality sharpening; shader strength 0.6"]
const OUTPUT_INFO := "Maximum decoded width for shader playback and Alpha on the compositor layer; plain compositor-layer playback ignores it."
const OUTPUT_HINTS := {AUTO_OUTPUT: "4096 px on Quest 2 / PICO Neo3 class GPUs, source width otherwise", 0: "Source width",
	5760: "Max 5760 px wide", 4096: "Max 4096 px wide"}

static func load_quality(settings: ConfigFile) -> int:
	if settings.has_section_key("video", "display_quality"):
		return clampi(int(settings.get_value("video", "display_quality")), AUTO, SCALES.size() - 1)
	if settings.has_section_key("video", "render_scale"):
		var scale := float(settings.get_value("video", "render_scale"))
		return 0 if scale <= 1.0 else (1 if scale < 1.2 else 2)
	return DEFAULT

static func render_scale(choice: int, low_end: bool) -> float:
	if choice == AUTO: return SCALES[0 if low_end else TIER_DEFAULT]
	return SCALES[clampi(choice, 0, SCALES.size() - 1)]

## Adreno 6xx and older (XR2 Gen1 / XR2+) are low end; 7xx (XR2 Gen2) and unknown GPUs are not.
static func is_low_end_gpu(adapter: String) -> bool:
	var found := RegEx.create_from_string("(?i)adreno\\D*(\\d{3})").search(adapter)
	return found != null and int(found.get_string(1)) < 700

static func default_sharpness(low_end: bool) -> float:
	return 0.0 if low_end else DEFAULT_SHARPNESS

static func load_video_sharpness(settings: ConfigFile) -> float:
	if not settings.has_section_key("video", "sharpness"): return DEFAULT_VIDEO_SHARPNESS
	return load_sharpness(settings)

static func load_sharpness(settings: ConfigFile, low_end: bool = false) -> float:
	var fallback := default_sharpness(low_end)
	var value := float(settings.get_value("video", "sharpness", fallback))
	if not is_finite(value): return fallback
	# Earlier four levels fold in: Low stays Normal, Medium and High become Quality.
	return SHARPNESS[0 if value <= 0.0 else (1 if value < 0.4 else 2)]

static func load_supersampling(settings: ConfigFile) -> int:
	return clampi(int(settings.get_value("video", "supersampling", DEFAULT_SUPERSAMPLING)), 0, SUPERSAMPLING_NAMES.size() - 1)

## Playback refresh rate: the highest rate a video may raise the display to. Matching the video's
## frame rate shows every frame for the same number of refreshes; higher rates cost GPU time and heat.
## 120 Hz by default: below it 60 fps has no even rate and plays at 72 Hz, repeating one frame in
## five. Quest 3 holds 120 fps for 8K60 layer playback (2026-10-24); low-end GPUs stop at 90 Hz.
const REFRESH_CAPS := [120, 90, 72]
const DEFAULT_REFRESH_CAP := 120
const REFRESH_NAMES := {120: "Up to 120 Hz", 90: "Up to 90 Hz", 72: "72 Hz · Power saving"}
const REFRESH_INFO := "Steadier motion at higher refresh rates, with a higher GPU load."
const REFRESH_HINTS := {120: "60 fps → 120 Hz, 30 fps → 90 Hz · steadiest picture, highest GPU load",
	90: "30 fps → 90 Hz, others 72 Hz · steadier picture, moderate GPU load",
	72: "Every video at 72 Hz · lowest GPU load, power and heat"}

## Power saving also keeps plain playback at sustained-low CPU/GPU levels (Alpha and 2D->3D still
## request sustained-high for their inference).
const POWER_SAVING_CAP := 72

## The saved cap; XR2 Gen1 class GPUs (Quest 2, PICO Neo3) stop at 90 Hz.
static func load_refresh_cap(settings: ConfigFile, low_end: bool) -> int:
	var value := int(settings.get_value("video", "refresh_cap", DEFAULT_REFRESH_CAP))
	if not REFRESH_CAPS.has(value): value = DEFAULT_REFRESH_CAP
	return mini(value, 90) if low_end else value

static func refresh_choices(low_end: bool) -> Array:
	return REFRESH_CAPS.filter(func(cap): return not (low_end and cap > 90))

static func load_output_choice(settings: ConfigFile) -> int:
	var value := int(settings.get_value("video", "output_width", AUTO_OUTPUT))
	return value if value == AUTO_OUTPUT or value in [0, 5760, 4096] else AUTO_OUTPUT

static func output_width(choice: int, low_end: bool) -> int:
	if choice != AUTO_OUTPUT: return choice
	return LOW_END_OUTPUT_WIDTH if low_end else 0
