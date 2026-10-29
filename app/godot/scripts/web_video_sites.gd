extends RefCounted

const Channel := preload("res://scripts/distribution_channel.gd")

const FEATURED := [
	{"name": "Bilibili", "url": "https://www.bilibili.com/", "icon": "site_bilibili", "color": Color("fa80a4"), "languages": ["zh"], "region": "CN"},
	{"name": "YouTube", "url": "https://www.youtube.com/", "icon": "site_youtube", "color": Color("ff6978"), "languages": [], "lead": true},
	{"name": "Weibo", "url": "https://weibo.com/", "icon": "site_weibo", "color": Color("ffad69"), "languages": ["zh"], "region": "CN"},
	{"name": "Tencent Video", "url": "https://v.qq.com/", "icon": "site_tencent", "color": Color("58c9e8"), "languages": ["zh"], "region": "CN"},
	{"name": "Mango TV", "url": "https://www.mgtv.com/", "icon": "site_mango", "color": Color("ffb54f"), "languages": ["zh"], "region": "CN"},
	{"name": "Youku", "url": "https://www.youku.com/", "icon": "site_youku", "color": Color("77aaff"), "languages": ["zh"], "region": "CN"},
	{"name": "Netflix", "url": "https://www.netflix.com/", "icon": "site_netflix", "color": Color("ff5a5f"), "languages": []},
	{"name": "Prime Video", "url": "https://www.primevideo.com/", "icon": "site_prime", "color": Color("5cc8ff"), "languages": []},
	{"name": "Disney+", "url": "https://www.disneyplus.com/", "icon": "site_disney", "color": Color("8fb4ff"), "languages": []},
	{"name": "HBO Max", "url": "https://www.hbomax.com/", "icon": "site_hbo", "color": Color("b79cff"), "languages": []},
	{"name": "Hulu", "url": "https://www.hulu.com/", "icon": "site_hulu", "color": Color("6ee69a"), "languages": []},
	{"name": "Apple TV", "url": "https://tv.apple.com/", "icon": "site_appletv", "color": Color("d7dde3"), "languages": []},
	{"name": "Twitch", "url": "https://www.twitch.tv/", "icon": "site_twitch", "color": Color("b894ff"), "languages": []},
	{"name": "TikTok", "url": "https://www.tiktok.com/", "icon": "site_tiktok", "color": Color("ff6f91"), "languages": []},
	{"name": "Instagram Reels", "url": "https://www.instagram.com/reels/", "icon": "site_instagram", "color": Color("ed92c6"), "languages": []},
	{"name": "TED", "url": "https://www.ted.com/talks", "icon": "site_ted", "color": Color("ff7070"), "languages": []},
	{"name": "Niconico", "url": "https://www.nicovideo.jp/", "icon": "site_niconico", "color": Color("e3e7eb"), "languages": ["ja"]},
	{"name": "iQIYI", "url": "https://www.iqiyi.com/", "icon": "site_iqiyi", "color": Color("67d644"), "languages": ["zh"], "region": "CN"},
	{"name": "Douyin", "url": "https://www.douyin.com/", "icon": "site_tiktok", "color": Color("68e4df"), "languages": ["zh"], "region": "CN"},
]

# Positive sample evidence, not a promise for every video/account/quality on a site.
# See docs/WEB_VIDEO_SITES_20261028_CN.md and the 2026-10-28/29 handovers.
# iQIYI and Douyin remain browser entries; neither passed native audio/video acceptance.
const NATIVE_PLAYBACK := ["Bilibili", "YouTube", "Weibo", "Tencent Video", "Mango TV", "Youku",
	"Twitch", "TikTok", "Instagram Reels", "TED", "Niconico"]

static func supports_native(site: Dictionary) -> bool:
	return str(site.get("name", "")) in NATIVE_PLAYBACK

static func ordered_indexes(language: String, sites: Array = FEATURED) -> Array[int]:
	var locale := language.to_lower().replace("-", "_").get_slice("_", 0)
	var order: Array[int] = []
	for index in sites.size():
		if Channel.current() == "pico_cn_store" and sites[index].get("region", "") != "CN": continue
		order.append(index)
	order.sort_custom(func(a: int, b: int) -> bool:
		var left := _language_rank(sites[a], locale)
		var right := _language_rank(sites[b], locale)
		return a < b if left == right else left < right)
	return order

static func _language_rank(site: Dictionary, locale: String) -> int:
	var languages: Array = site.get("languages", [])
	# The main VR video source stays on the first page for every audience.
	if languages.has(locale) or site.get("lead", false): return 0
	if locale == "zh": return 1
	if languages.has("zh"): return 3
	return 1 if languages.is_empty() else 2
