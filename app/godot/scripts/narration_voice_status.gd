extends RefCounted
## Shared task feedback for inline audition, clone rows and the global library.
const BUSY := ["pausing", "preparing", "extracting", "encoding", "model_verifying", "model_loading", "generating", "playing_original", "playing_clone"]

static func preview_busy(state: Dictionary) -> bool:
	return state.get("operation", "") == "preview" and state.get("state", "") in BUSY

static func label(state: Dictionary) -> String:
	if state.get("state", "") == "error": return str(state.get("error", ""))
	if state.get("operation", "") == "preview":
		if state.get("state", "") == "ready": return "Voice preview finished"
		if state.get("state", "") == "playing_clone": return "Playing voice preview…"
	return str({"pausing": "Pausing video…", "reading": "Finding voice samples…", "preparing": "Preparing voice preview…", "extracting": "Preparing original audio…", "encoding": "Cloning voice…", "model_verifying": "Checking narration model…", "model_loading": "Loading narration model…", "generating": "Preparing voice preview…", "playing_original": "Original audio", "playing_clone": "Clone preview", "saving": "Saving voice…", "saved": "Voice saved"}.get(state.get("state", "idle"), ""))
