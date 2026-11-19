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

static func register(platform: Object) -> void:
	runtime = PlatformMethods.supports(platform, "video_layer_qiyu_passthrough") and bool(platform.video_layer_qiyu_passthrough())
