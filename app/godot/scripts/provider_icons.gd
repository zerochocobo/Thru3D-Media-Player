extends RefCounted
## Vector provider marks. Aliases keep old accounts visually consistent.
const ALIASES := {
	"115": "115", "115_open": "115", "baidu": "baidu",
	"aliyun": "aliyun", "aliyun_open": "aliyun", "quark": "quark", "quark_open": "quark",
	"onedrive": "onedrive", "webdav": "webdav", "emby": "emby", "jellyfin": "jellyfin",
	"plex": "plex", "stash": "stash", "xbvr": "xbvr",
}
const TEXTURES := {
	"provider_115": preload("res://assets/provider-icons/115.svg"),
	"provider_baidu": preload("res://assets/provider-icons/baidu.svg"),
	"provider_aliyun": preload("res://assets/provider-icons/aliyun.svg"),
	"provider_quark": preload("res://assets/provider-icons/quark.svg"),
	"provider_onedrive": preload("res://assets/provider-icons/onedrive.svg"),
	"provider_webdav": preload("res://assets/provider-icons/webdav.svg"),
	"provider_emby": preload("res://assets/provider-icons/emby.svg"),
	"provider_jellyfin": preload("res://assets/provider-icons/jellyfin.svg"),
	"provider_plex": preload("res://assets/provider-icons/plex.svg"),
	"provider_stash": preload("res://assets/provider-icons/stash.svg"),
	"provider_xbvr": preload("res://assets/provider-icons/xbvr.svg"),
}
const MARK_SCALE := {"provider_xbvr": 1.8}
const COLORED := ["provider_emby", "provider_jellyfin", "provider_plex", "provider_stash", "provider_xbvr"]
# Readable color adaptations of the retained white vectors, not replacement artwork.
# 115's blue comes from its retained source; the remaining hues identify each service.
const LIGHT_COLORS := {
	"provider_115": Color("224888"), "provider_baidu": Color("2864d8"),
	"provider_aliyun": Color("6251c5"), "provider_quark": Color("3165d0"),
	"provider_onedrive": Color("0078d4"), "provider_webdav": Color("247b89"),
}

static func key(provider: String, fallback: String = "cloud") -> String:
	var name: String = ALIASES.get(provider.strip_edges().to_lower(), "")
	return "provider_" + name if not name.is_empty() else fallback
