extends RefCounted
## The pinned MOSS Nano README names these 19 languages; voice origins are separate.
const NAMES := {"zh": "Chinese", "en": "English", "ja": "Japanese", "de": "German", "es": "Spanish", "fr": "French",
	"it": "Italian", "hu": "Hungarian", "ko": "Korean", "ru": "Russian", "fa": "Persian", "ar": "Arabic",
	"pl": "Polish", "pt": "Portuguese", "cs": "Czech", "da": "Danish", "sv": "Swedish", "el": "Greek", "tr": "Turkish"}
const ALIASES := {"zho": "zh", "chi": "zh", "cmn": "zh", "chs": "zh", "cht": "zh", "eng": "en", "jpn": "ja",
	"deu": "de", "ger": "de", "spa": "es", "fra": "fr", "fre": "fr", "ita": "it", "hun": "hu", "kor": "ko",
	"rus": "ru", "fas": "fa", "per": "fa", "ara": "ar", "pol": "pl", "por": "pt", "ces": "cs", "cze": "cs",
	"dan": "da", "swe": "sv", "ell": "el", "gre": "el", "tur": "tr"}

static func canonical(tag: String) -> String:
	var code := tag.strip_edges().replace("_", "-").to_lower().get_slice("-", 0)
	return code if code in NAMES else str(ALIASES.get(code, ""))

static func choices() -> Array:
	var result: Array = []
	for code in NAMES: result.append({"value": code, "label": NAMES[code]})
	result.append({"value": "auto", "label": "From subtitles"})
	return result
