extends RefCounted
## Build-time channel; deliberately independent of saved user preferences.
const KEY := "application/config/distribution_channel"

static func current() -> String:
	return str(ProjectSettings.get_setting(KEY, "standard"))

static func web_browser_enabled() -> bool:
	return current() == "standard"
