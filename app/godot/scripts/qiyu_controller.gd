extends RefCounted
## iQIYI's QIYU factory runtime (Monado "QIYIVR") binds its controllers only through its own
## /interaction_profiles/qiyu/touch_controller; offered nothing else it falls back to
## khr/simple_controller, so the trigger ray works but sticks and grips never report (user logs
## 2026-11-18). Godot suggests the action map at module start, before any script, so the profile is
## listed in openxr_action_map.tres and its metadata registered by native/xr-layer/layer_extensions.cpp.

const PlatformMethods := preload("res://scripts/platform_methods.gd")

## The instance runs on the QIYU factory runtime (it enabled XR_QIYU_passthrough).
static var runtime := false
## QIYU draws menus in the eye buffer and decodes its washed-out pictures (pages, video, photos,
## AirPlay); both always on since the user feedback of 2026-11-19, so no longer settings.
static var page_decode := true
## Decoded pictures are first lifted by this exponent on their encoded values (black and white stay
## put). The decode alone left video dark: the QIYU tester lowered contrast and raised the shadow lift on
## every video (2026-11-23), and a QIYU streaming client (moonproX, ALVR on the QiYu SDK) settled on the
## same 0.65 on encoded values for this display.
const DISPLAY_GAMMA := 0.65
## Godot turns off the GPU's sRGB encode on write only through GL_EXT_sRGB_write_control. With it the
## decoded pictures land in the 8-bit eye buffer as linear values, which keep few dark levels (user,
## 2026-11-21: dark hair blurred until shadows were lifted), so they are dithered. Without it the GPU
## encodes the write and the stored values keep full precision.
static var linear_eye_buffer := false

static func register(platform: Object) -> void:
	runtime = PlatformMethods.supports(platform, "video_layer_qiyu_passthrough") and bool(platform.video_layer_qiyu_passthrough())
	if runtime and PlatformMethods.supports(platform, "gl_extension"):
		var write_control := int(platform.gl_extension("GL_EXT_sRGB_write_control"))
		linear_eye_buffer = write_control != 0
		print("[QIYU] GL_EXT_sRGB_write_control=%d" % write_control)
	# System screenshots of the app come out black on QIYU (2026-11-20): log what a capture sees.
	if runtime and PlatformMethods.supports(platform, "capture_probe_start"): platform.capture_probe_start()
