extends RefCounted
## Document pages share the image UI but never persist session capabilities.
static func named(uri: String, title: String = "") -> bool:
	return title.get_extension().to_lower() == "pdf" or uri.get_slice("?", 0).get_extension().to_lower() == "pdf"

static func page(uri: String) -> bool: return uri.begins_with("pdfpage://")
static func container_page(uri: String) -> bool: return page(uri) or uri.begins_with("comic://")
static func session(uri: String) -> String: return uri.get_slice("/", 2) if page(uri) else ""

static func error_text(code: String) -> String:
	return {"PDF_NETWORK_UNAVAILABLE":"Cloud connection failed", "PDF_LOCATION_EXPIRED":"Archive location expired; refresh the folder", "PDF_CACHE_FULL":"Not enough storage", "PDF_PAGE_LIMIT":"PDF has too many pages",
		"PDF_NOT_SEEKABLE":"PDF source does not support seeking", "PDF_PASSWORD_UNSUPPORTED":"Password-protected PDFs are not supported",
		"PDF_UNAVAILABLE":"PDF could not be opened"}.get(code, code)
