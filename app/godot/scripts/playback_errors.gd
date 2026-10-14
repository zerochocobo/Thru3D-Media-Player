extends RefCounted

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

static func message(report: Dictionary) -> String:
	var code := str(report.get("code", ""))
	if MESSAGES.has(code): return MESSAGES[code]
	var detail := str(report.get("message", "")).to_lower()
	if "certificate" in detail or "tls" in detail or "ssl" in detail:
		return "Cannot verify the media server's certificate. Check its HTTPS configuration."
	if "decoder" in detail and ("failed" in detail or "could not" in detail or "error" in detail):
		return "Video decoding failed. The codec or file may be unsupported."
	if "timed out" in detail or "timeout" in detail or "within 15 seconds" in detail:
		return "Opening media timed out. Check the link and connection."
	if "unrecognized file format" in detail or "unknown format" in detail or "no video" in detail or "no audio or video" in detail:
		return "Unsupported media format, or the link is not a video."
	if "loading failed" in detail or "no such file" in detail or "permission" in detail or "403" in detail or "401" in detail or "404" in detail:
		return "Cannot open media. Check the address and access permissions."
	if code == "MPV_LOCAL_SOURCE_FAILED": return "Cannot open media. Check the address and access permissions."
	return "Playback failed. Check the media format and connection."
