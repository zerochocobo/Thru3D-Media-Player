extends RefCounted

const I18n := preload("res://scripts/i18n.gd")

## Present fixed messages; signed addresses and server responses stay out of the UI.
const MESSAGES := {
	"STRM_EMPTY": "STRM is empty. Add one media address.",
	"STRM_TOO_LARGE": "STRM is too large (maximum 64 KB).",
	"STRM_INVALID_TEXT": "STRM must be a UTF-8 or UTF-16 text file.",
	"STRM_MULTIPLE_TARGETS": "STRM must contain only one media address.",
	"STRM_INVALID_ADDRESS": "The media address in STRM is invalid.",
	"STRM_UNSUPPORTED_ADDRESS": "This STRM address or protocol is unsupported.",
	"STRM_WINDOWS_PATH": "Windows paths cannot be opened here. Use SMB or HTTP.",
	"STRM_RELATIVE_PATH_UNAVAILABLE": "This STRM source requires an absolute media address.",
	"STRM_SMB_CONNECTION_REQUIRED": "Add the STRM target's SMB server to the library first.",
	"STRM_RECURSIVE": "STRM links form a loop or exceed four levels.",
	"STRM_READ_FAILED": "Cannot read STRM. Check the file and connection.",
	"STRM_READ_TIMEOUT": "Reading STRM timed out. Check the connection.",
	"STRM_ACCESS_DENIED": "STRM access denied. Check authentication or link expiry.",
	"STRM_NOT_FOUND": "The STRM file was not found or its link expired.",
	"STRM_TARGET_UNAVAILABLE": "Cannot access the STRM target. Check the path and account.",
	"MPV_OPEN_TIMEOUT": "Opening media timed out. Check the link and connection.",
	"MPV_OUTPUT_TIMEOUT": "Video output timed out. Try opening the video again.",
	"MPV_BUFFER_TIMEOUT": "Media buffering timed out. Check the connection."
}

const REASONS := {
	"access_denied": "Media access was denied.",
	"login_required": "Sign in to your cloud account again.",
	"not_found": "The media file was not found.",
	"source_missing": "The media file or cloud account was not found.",
	"link_expired": "The media link has expired.",
	"file_changed": "The media file changed. Refresh the folder.",
	"network_timeout": "Reading media timed out.",
	"tls_failed": "Cannot verify the media server's certificate. Check its HTTPS configuration.",
	"host_not_found": "The media server could not be found.",
	"connection_failed": "Could not connect to the media server.",
	"http_error": "The media server returned an error.",
	"not_media": "The server returned non-media content.",
	"range_unsupported": "The server does not support the required byte-range requests.",
	"invalid_range": "The server returned an invalid byte range.",
	"invalid_response": "The media server returned an invalid response.",
	"redirect_failed": "The media link redirected too many times.",
	"stream_interrupted": "The media stream was interrupted.",
	"unknown_format": "Cannot recognize the media format. It may be unsupported or damaged.",
	"nothing_to_play": "No playable audio or video tracks were found.",
	"decoder_failed": "The video decoder could not be started.",
	"audio_output_failed": "Audio output could not be initialized.",
	"video_output_failed": "Video output could not be initialized.",
	"output_timeout": "Video output timed out. Try opening the video again."
}
const STAGES := {"resolving": "Resolving media", "reading": "Reading media", "parsing": "Parsing media",
	"decoding": "Decoding video", "output": "Initializing output", "opening": "Opening media"}
const MPV_REASONS := {-14: "audio_output_failed", -15: "video_output_failed", -16: "nothing_to_play", -17: "unknown_format"}

static func message(report: Dictionary) -> String:
	var code := str(report.get("code", ""))
	var reason := str(report.get("reason", ""))
	if REASONS.has(reason): return REASONS[reason]
	if MESSAGES.has(code): return MESSAGES[code]
	var mpv_code := int(report.get("mpv_code", 0))
	if MPV_REASONS.has(mpv_code): return REASONS[MPV_REASONS[mpv_code]]
	if report.has("reason") or report.has("mpv_code"):
		return "Media loading failed. No specific cause was reported."
	# Compatibility with older native reports. Generic loading failures never imply permissions.
	var detail := str(report.get("message", "")).to_lower()
	if "certificate" in detail or "tls" in detail or "ssl" in detail:
		return REASONS.tls_failed
	if "decoder" in detail and ("failed" in detail or "could not" in detail or "error" in detail):
		return REASONS.decoder_failed
	if "timed out" in detail or "timeout" in detail or "within 15 seconds" in detail:
		return "Opening media timed out. Check the link and connection."
	if "unrecognized file format" in detail or "unknown format" in detail: return REASONS.unknown_format
	if "no audio or video" in detail: return REASONS.nothing_to_play
	return "Media loading failed. No specific cause was reported."

static func clean(report: Dictionary) -> Dictionary:
	var result := {}
	for key in ["code", "reason", "stage", "detail", "message", "native_detail", "source_code", "exception_type", "backend"]:
		if report.has(key): result[key] = safe_detail(str(report[key]))
	for key in ["http_status", "mpv_code", "session_id", "logical_session_id", "generation"]:
		if report.has(key): result[key] = int(report[key])
	return result

## A second redaction boundary also protects reports from older plugin versions.
static func safe_detail(value: String) -> String:
	var text := value
	var patterns := ["(?i)[a-z][a-z0-9+.-]*://[^\\s<>\"']+",
		"(?im)(?:cookie|set-cookie|authorization)\\s*[:=][^\\r\\n]*",
		"(?i)(?:access_token|refresh_token|token|password|passwd|secret|signature|sign|UID|CID|SEID|KID)[\\\"']*\\s*[:=]\\s*(?:\\\"[^\\\"]*\\\"|'[^']*'|[^\\s,;}&]+)"]
	for pattern in patterns:
		var regex := RegEx.new()
		regex.compile(pattern)
		text = regex.sub(text, "[redacted]", true)
	text = text.replace("\r", " ").replace("\n", " ").replace("\t", " ")
	if text.to_lower().contains("<html") or text.to_lower().contains("<!doctype") or text.strip_edges().begins_with("{"):
		return I18n.t("Server response omitted")
	return text.strip_edges().left(240)

static func details(report: Dictionary) -> String:
	var lines := PackedStringArray()
	var stage := str(report.get("stage", "opening"))
	lines.append(I18n.t("Stage: %s") % I18n.t(STAGES.get(stage, "Opening media")))
	var codes := PackedStringArray()
	var http := int(report.get("http_status", 0))
	if http >= 100 and http <= 599: codes.append("HTTP %d" % http)
	var mpv := int(report.get("mpv_code", 0))
	if mpv != 0: codes.append("MPV %d" % mpv)
	if not codes.is_empty(): lines.append(" · ".join(codes))
	for key in ["code", "source_code", "exception_type"]:
		var value := safe_detail(str(report.get(key, "")))
		if not value.is_empty(): lines.append(value.left(80))
	var cause := safe_detail(str(report.get("detail", report.get("message", ""))))
	if not cause.is_empty(): lines.append(cause)
	var native := safe_detail(str(report.get("native_detail", "")))
	if not native.is_empty() and native != cause: lines.append(native.left(160))
	if lines.size() == 1: lines.append(I18n.t("No additional error details were provided."))
	return "\n".join(lines)
