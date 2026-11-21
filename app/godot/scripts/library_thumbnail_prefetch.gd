extends RefCounted
## Schedules one preview for the settled, visible storage view. Navigation never waits on a job.
const Cache := preload("res://scripts/thumbnail_cache.gd")
const Artwork := preload("res://scripts/library_directory_artwork.gd")
const MediaUri := preload("res://scripts/media_uri.gd")
const References := preload("res://scripts/thumbnail_references.gd")
const Privacy := preload("res://scripts/media_privacy.gd")
const Methods := preload("res://scripts/platform_methods.gd")
const LIMITS := [10, 20, 50, 100, 200]
const DEFAULT_LIMIT := 20
const FILE_SETTLE := 400
const FOLDER_SETTLE := 1000
const INDICATOR_DELAY := 300
const MEMORY_PEAK := 32 * 1024 * 1024
const VIDEO_MEMORY_PEAK := 64 * 1024 * 1024
const NETWORK_START_INTERVAL_MS := 1500
const NETWORK_PER_MINUTE := 8
const BACKOFF_SCOPES := 64
const FRAME_RECOVERY_MS := 750
const FILE_FAILURE_POLICY := 2
const FILE_NEGATIVE_SECONDS := 86400
const FOLDER_NEGATIVE_SECONDS := 600
const DIAGNOSTIC_MAX_RECENT := 24
var menu: Node
var enabled := true
var smb_enabled := true
var dlna_enabled := true
var limit := DEFAULT_LIMIT
var may_run: Callable
var budget := preload("res://scripts/background_resource_budget.gd").new()
var used := 0
var _visit := ""
var _visit_id := 0
var _attempted := {}
var _frame_retries := {}
var _recover_at := 0
var _refresh_scope := ""
var _refresh_candidates := {}
var _refreshed := {}
var _folder_jobs := 0
var _view := ""
var _view_at := 0
var _view_folders := 0
var _native_id := -1
var _native_host: Object
var _job: Dictionary = {}
var _poll_at := 0
var _reading_at := -1
var _cancelled := false
var _backoff_by_scope := {}
var _writer := -1
var _stage_path := ""
var _private_image: Image
var _encoded_size := 0
var _disposed := false
var _writer_lock := Mutex.new()
var _network_last_start := -NETWORK_START_INTERVAL_MS
var _network_starts := {}
var _diagnostic_status := {}
var _diagnostic_recent: Array[Dictionary] = []
var _diagnostic_admission := {}

func _init(host: Node) -> void:
	menu = host
	budget.frame_cadence_only = true

static func normalized_limit(value: Variant) -> int:
	var requested := clampi(int(value), LIMITS.front(), LIMITS.back())
	for choice in LIMITS:
		if requested <= choice: return int(choice)
	return DEFAULT_LIMIT

func configure(wanted: bool, count: int, smb_wanted: bool = true, dlna_wanted: bool = true, protect_frames: bool = true) -> void:
	var next := normalized_limit(count)
	if next < limit: cancel()
	enabled = wanted
	smb_enabled = smb_wanted
	dlna_enabled = dlna_wanted
	if budget.protect_preview_frames != protect_frames:
		budget.stop()
		budget.protect_preview_frames = protect_frames
		_recover_at = 0
	limit = next
	if not _source_enabled(): cancel()

func _source_enabled() -> bool:
	match menu.section:
		menu.Section.LOCAL: return enabled
		menu.Section.SMB: return smb_enabled
		menu.Section.DLNA: return dlna_enabled
	return false

func tick(delta: float) -> void:
	var folder := _current_folder()
	if not folder.is_empty() and folder != _visit:
		cancel("directory_changed")
		_visit = folder
		_visit_id += 1
		used = 0
		_attempted.clear()
		_frame_retries.clear()
		_recover_at = 0
		_refresh_candidates.clear()
		_refreshed.clear()
		if _refresh_scope != folder: _refresh_scope = ""
		_folder_jobs = 0
		_view = ""
	var block := "scope_unavailable" if folder.is_empty() else _blocked_reason()
	var allowed := block.is_empty()
	var choices := _visible_choices() if allowed else []
	var now := Time.get_ticks_msec()
	var signature := JSON.stringify(choices.map(func(item): return item.ticket))
	if signature != _view:
		_view = signature
		_view_at = now
		_view_folders = 0
		cancel("viewport_changed")
	var network: bool = menu.section in [menu.Section.SMB, menu.Section.DLNA]
	var work_allowed := allowed and (used < limit or not _job.is_empty())
	budget.preview_job_active = not _job.is_empty()
	budget.tick(menu, delta, work_allowed)
	var frame_pressure: bool = budget.reason in ["frame_budget", "frame_stall"]
	if not allowed:
		cancel(block)
	elif not _job.is_empty():
		if not budget.can_continue(_memory_peak(_job.item)):
			cancel("resource_budget")
	_drain(choices, now, frame_pressure)
	if not allowed: _note_status(block); return
	if not _job.is_empty(): _note_status("active"); return
	if used >= limit: _note_status("folder_limit"); return
	var backoff: Dictionary = _backoff_by_scope.get(folder, {})
	if now < int(backoff.get("worker_until", 0)): _note_status("worker_busy"); return
	if now < _recover_at: _note_status("frame_recovery"); return
	if now - _view_at < FILE_SETTLE: _note_status("settling"); return
	if Cache.reading(): _note_status("cache_reading"); return
	if not budget.can_start(MEMORY_PEAK):
		_note_status(budget.reason if budget.reason != "ready" else "memory_limit")
		return
	if _refresh_scope == folder:
		if menu.directory_artwork.busy(): _note_status("fingerprint_check"); return
		for item in choices:
			if item.kind != "folder" and not _refreshed.has(item.ticket) and _eligibility(item) != "cached":
				_refresh_candidates[item.ticket] = true
		_refresh_scope = ""
	var cooling := now < int(backoff.get("until", 0))
	if cooling and (_refresh_candidates.is_empty() or backoff.get("probe_used", false)):
		_note_status("backoff")
		return
	var host: String = menu._smb_server if menu.section == menu.Section.SMB else menu._dlna_server
	var endpoint := str([menu.section, host])
	var starts: Array = []
	if network:
		if now - _network_last_start < NETWORK_START_INTERVAL_MS: _note_status("network_spacing"); return
		starts = _network_starts.get(endpoint, []).filter(func(time): return now - int(time) < 60000)
		if starts.size() >= NETWORK_PER_MINUTE: _note_status("network_limit"); return
	var videos: Array[String] = []
	var memory_limited := false
	var negative_cached := false
	var next := {}
	for item in choices:
		if item.kind == "video": videos.append(str(item.name))
	for item in choices:
		if item.kind == "folder": continue
		var manual := _refresh_candidates.has(item.ticket)
		if cooling and not manual: continue
		var eligibility := _eligibility(item)
		if eligibility != "eligible":
			if eligibility == "negative_cache": negative_cached = true
			continue
		if not budget.can_start(_memory_peak(item)):
			memory_limited = true
			continue
		if next.is_empty() or manual: next = item
		if manual: break
	if not next.is_empty():
		_start(next, videos, 0)
		if cooling and not _job.is_empty(): backoff.probe_used = true
		if network: _record_network_start(endpoint, starts, now)
		return
	if cooling: _note_status("backoff"); return
	var idle_reason := "memory_limit" if memory_limited else ("negative_cache" if negative_cached else "no_eligible_visible")
	_note_status(idle_reason)
	if menu.section == menu.Section.SMB: return
	if now - _view_at < FOLDER_SETTLE or limit - used < 2: return
	var folder_limit := _folder_jobs >= (1 if network else 4) or _view_folders >= 2
	for item in choices:
		if item.kind != "folder" or _eligibility(item) != "eligible" or not budget.can_start(_memory_peak(item)): continue
		if folder_limit and not _frame_retries.get(item.ticket, false): continue
		_start(item, [], mini(8 if network else 32, limit - used - 1))
		if network: _record_network_start(endpoint, starts, now)
		return

func _record_network_start(endpoint: String, starts: Array, now: int) -> void:
	if _job.is_empty(): return
	_network_last_start = now
	starts.append(now)
	_network_starts.erase(endpoint)
	_network_starts[endpoint] = starts
	if _network_starts.size() > 32: _network_starts.erase(_network_starts.keys().front())

func _current_folder() -> String:
	if menu.section in [menu.Section.SMB, menu.Section.DLNA]: return menu._artwork_scope()
	if menu.section != menu.Section.LOCAL or menu._local_stack.is_empty(): return ""
	var path: String = menu._local_path()
	if path.is_empty() or path.begins_with("content://"): return ""
	for volume in menu._local_volumes:
		if volume.get("removable", false) or volume.get("managed_usb", false): continue
		var root := str(volume.get("id", "")).trim_suffix("/")
		if not root.is_empty() and (path == root or path.begins_with(root + "/")): return path
	return ""

func _blocked_reason() -> String:
	if not _source_enabled(): return "source_disabled"
	if not menu.visible or menu.compact: return "view_inactive"
	if not Cache.ready(): return "index_loading"
	if Cache.clearing() or Cache._locked(): return "cache_unavailable"
	if not References.ready(): return "index_loading"
	if menu._artwork_location().is_empty(): return "scope_unavailable"
	if (menu.has_pointer_capture() or absf(menu._fling) > 0.4 or menu.file_actions.editing
			or Time.get_ticks_msec() - menu._stick_ms < 120): return "interacting"
	var pending: Array = menu._pending.values()
	if pending.has("local") or pending.has("smb_browse") or pending.has("dlna_browse"): return "directory_loading"
	if not menu._covers.is_empty() or not menu._folder_covers._active.is_empty(): return "declared_cover_active"
	if not Methods.supports(menu.platform, "local_thumbnail_request"): return "bridge_unavailable"
	if may_run.is_valid() and not bool(may_run.call()): return "foreground_busy"
	return ""

static func _memory_peak(item: Dictionary) -> int:
	return VIDEO_MEMORY_PEAK if item.kind == "video" or (item.kind == "folder" and str(item.uri).begins_with("dlna://")) else MEMORY_PEAK

static func smb_sidecars(entries: Array) -> Dictionary:
	var result := {}
	for entry: Dictionary in entries:
		if entry.get("container", false) or entry.get("kind") != "image": continue
		if str(entry.title).get_extension().to_lower() not in ["jpg", "jpeg", "png", "webp"]: continue
		result[str(entry.title).to_lower()] = entry
	return result

static func smb_sidecar(images: Dictionary, title: String) -> Dictionary:
	var stem := title.get_basename().to_lower()
	for suffix in ["", "-poster", "-thumb"]:
		for extension in [".jpg", ".jpeg", ".png", ".webp"]:
			if images.has(stem + suffix + extension): return images[stem + suffix + extension]
	return {}

func _visible_choices() -> Array:
	var first: int = menu._visible_line() * menu._cols()
	var last := mini(menu.rows.size(), first + int(menu._lines() * menu._cols()))
	var result := []
	for index in range(first, last):
		var row: Dictionary = menu.rows[index]
		if row.has("folder_thumb_scope"):
			var child := str(row.folder_thumb_scope)
			var uri := child
			if menu.section == menu.Section.DLNA:
				if menu._folder_covers.awaiting_cover(row) or int(row.get("child_count", -1)) == 0: continue
			elif menu.section == menu.Section.LOCAL and child.get_base_dir() == _visit:
				uri = "file://" + child.uri_encode().replace("%2F", "/")
			else: continue
			var item := {"kind": "folder", "uri": uri, "folder": child,
				"identity": Artwork.folder_identity(child), "version": str(int(row.get("modified", -1)))}
			item.ticket = str([item.uri, item.version])
			result.append(item)
		elif row.get("kind") in ["image", "video"] and not row.get("thumb_item", {}).is_empty():
			if menu.section == menu.Section.DLNA and menu._folder_covers.awaiting_cover(row): continue
			var item: Dictionary = row.thumb_item.duplicate()
			item.kind = row.kind
			item.name = str(row.get("title", ""))
			item.size = int(row.get("size", -1))
			item.modified = int(row.get("modified", -1))
			item.resource = str(row.get("thumbnail_resource", ""))
			var sidecar: Dictionary = row.get("thumbnail_sidecar", {})
			item.sidecar = str(sidecar.get("uri", ""))
			item.sidecar_size = int(sidecar.get("size", -1))
			item.ticket = str([item.uri, item.version])
			result.append(item)
	return result

func _eligibility(item: Dictionary) -> String:
	if item.kind == "folder":
		var cover := References.cover(item.folder)
		if Cache.has_digest(str(cover.get("picture", "")), true): return "cached"
	elif Cache.has(item.uri): return "cached"
	if _refresh_candidates.has(item.ticket): return "eligible"
	if _frame_retries.get(item.ticket, false): return "eligible"
	if _attempted.has(item.ticket): return "attempted"
	var prior := References.fingerprint(_visit, item.identity)
	var eligible: bool = (prior.get("version") != str(item.version).sha1_text()
		or (item.kind != "folder" and prior.get("failure_policy", 0) != FILE_FAILURE_POLICY)
		or int(prior.get("failed_until", 0)) <= int(Time.get_unix_time_from_system()))
	return "eligible" if eligible else "negative_cache"

## Explicit refresh can retry an unchanged visible miss once per visit.
## A hit stays cached and every new read still counts against the same quota.
func refreshed(scope: String) -> void:
	if not scope.is_empty() and scope == _current_folder():
		_refresh_scope = scope

func _start(item: Dictionary, videos: Array, samples: int) -> void:
	var request := {"uri": item.uri, "kind": item.kind, "visit": _visit_id,
		"sample_limit": samples, "videos": videos, "size": item.get("size", -1),
		"resource": item.get("resource", ""), "sidecar": item.get("sidecar", ""),
		"sidecar_size": item.get("sidecar_size", -1)}
	var id: int = menu.platform.local_thumbnail_request(JSON.stringify(request))
	if id <= 0:
		_note_status("worker_busy")
		_backoff_for_visit().worker_until = Time.get_ticks_msec() + 300
		return
	_native_id = id
	_native_host = menu.platform
	_job = {"item": item, "visit": _visit_id, "scope": _visit, "cache_generation": Cache.generation,
		"sample_limit": samples, "started": Time.get_ticks_msec(), "source": _source_name()}
	_attempted[item.ticket] = true
	var frame_retry := bool(_frame_retries.get(item.ticket, false))
	if frame_retry: _frame_retries[item.ticket] = false
	if _refresh_candidates.erase(item.ticket):
		_refreshed[item.ticket] = true
		_job.retry = "manual_refresh"
	elif frame_retry: _job.retry = "frame_recovery"
	used += 1
	if samples > 0 and not frame_retry:
		_folder_jobs += 1
		_view_folders += 1
	_cancelled = false
	_reading_at = -1
	_poll_at = 0
	_note_status("active")

func _drain(choices: Array, now: int, frame_pressure: bool) -> void:
	if _job.is_empty(): return
	var current := (not _cancelled and int(_job.cache_generation) == Cache.generation and _visit_id == int(_job.visit)
		and choices.any(func(item): return item.ticket == _job.item.ticket))
	if not current: cancel("stale_result")
	if _writer >= 0:
		if WorkerThreadPool.is_task_completed(_writer) and (not current or not _job.memory_only or Cache.can_upload()):
			_finish_write(current)
		return
	if not is_instance_valid(_native_host):
		_record_finished("bridge_lost")
		_reset_job()
		return
	if now < _poll_at: return
	_poll_at = now + 50
	var parsed: Variant = JSON.parse_string(str(_native_host.local_thumbnail_state(_native_id)))
	if not parsed is Dictionary: return
	var state := str(parsed.get("state", "gone"))
	if state in ["queued", "reading", "cancelling"]:
		if current and frame_pressure and state != "cancelling":
			cancel("frame_budget")
			return
		if state == "reading" and current:
			if _reading_at < 0: _reading_at = now
			menu._set_thumbnail_reading(now - _reading_at >= INDICATOR_DELAY)
		else:
			menu._set_thumbnail_reading(false)
		if now - int(_job.started) > 2800 and not _cancelled:
			_temporary()
			cancel("ui_deadline")
		return
	if _visit_id == int(_job.visit):
		used += clampi(int(parsed.get("sampled", 0)), 0, int(_job.sample_limit))
	var data: PackedByteArray = _native_host.local_thumbnail_take(_native_id)
	_native_id = -1
	menu._set_thumbnail_reading(false)
	if current and state == "ready" and not data.is_empty() and _matches_result(parsed):
		_backoff_by_scope.erase(_job.scope)
		if _job.item.kind == "folder" and str(_job.item.uri).begins_with("dlna://"):
			var child := Artwork.descriptor({"type": "dlna", "server_id": menu._dlna_server}, parsed.entry)
			parsed.uri = child.uri
			_job.child = child
		var key := str(parsed.uri)
		_job.result = parsed.duplicate()
		_job.memory_only = not Privacy.cache_allowed(key)
		_encoded_size = data.size()
		_writer = WorkerThreadPool.add_task(_stage.bind(key, data, not _job.memory_only))
		return
	if current and state == "missing":
		var item: Dictionary = _job.item
		var expiry := int(Time.get_unix_time_from_system()) + (FOLDER_NEGATIVE_SECONDS if item.kind == "folder" else FILE_NEGATIVE_SECONDS)
		References.remember_fingerprint(_job.scope, item.identity, item.uri, item.version, "", expiry, 0,
			FILE_FAILURE_POLICY if item.kind != "folder" else 0)
	elif current and state in ["temporary", "cancelled"]:
		_temporary()
	if (_job.get("cancel_reason") == "frame_budget" and int(_job.cache_generation) == Cache.generation
			and _visit_id == int(_job.visit)):
		var item: Dictionary = _job.item
		_recover_at = now + FRAME_RECOVERY_MS
		if not _frame_retries.has(item.ticket): _frame_retries[item.ticket] = true
	var outcome := state
	if not current: outcome = "discarded"
	elif state == "ready": outcome = "result_rejected"
	_record_finished(outcome, parsed)
	_reset_job()

func _matches_result(result: Dictionary) -> bool:
	var item: Dictionary = _job.item
	var uri := str(result.get("uri", ""))
	if item.kind == "folder":
		if str(item.uri).begins_with("dlna://"):
			var entry: Dictionary = result.get("entry", {})
			return entry.get("kind") in ["image", "video"] and not str(entry.get("id", "")).is_empty() and str(entry.id) != str(item.uri).get_slice("/", 3).uri_decode()
		return uri.begins_with("file://") and MediaUri.decode_path(uri.trim_prefix("file://")).get_base_dir() == item.folder
	if uri.begins_with("content://media/external_primary/"): return uri == item.uri
	if uri.begins_with("smb://") or uri.begins_with("dlna://"): return uri == item.uri
	return (uri == item.uri and (item.get("size", -1) < 0 or int(result.get("size", -1)) == item.size)
		and (item.get("modified", -1) < 0 or int(result.get("modified", -1)) == item.modified))

func _stage(key: String, bytes: PackedByteArray, disk: bool) -> void:
	if disk:
		var path := Cache.stage_prefetch(key, bytes)
		_writer_lock.lock()
		var discard := _disposed
		if not discard: _stage_path = path
		_writer_lock.unlock()
		if discard and not path.is_empty(): DirAccess.remove_absolute(path)
	else:
		var image := Image.new()
		if image.load_jpg_from_buffer(bytes) == OK: _private_image = image

func _finish_write(current: bool) -> void:
	WorkerThreadPool.wait_for_task_completion(_writer)
	_writer = -1
	var key := str(_job.result.uri)
	var stored := false
	if current:
		if not _stage_path.is_empty():
			stored = Cache.commit_prefetch(key, _stage_path, _encoded_size, _job.cache_generation)
		elif _private_image:
			stored = Cache.store_transient(key, _private_image, true)
	elif not _stage_path.is_empty():
		DirAccess.remove_absolute(_stage_path)
	if stored:
		var item: Dictionary = _job.item
		if item.kind == "folder":
			var child: Dictionary = _job.get("child", {})
			if child.is_empty():
				var path := MediaUri.decode_path(key.trim_prefix("file://"))
				child = Artwork.descriptor({"type": "local"}, {"uri": key, "id": path, "title": path.get_file(),
					"kind": "image", "size": int(_job.result.size), "modified": int(_job.result.modified)})
			menu.directory_artwork.remember(item.folder, child)
			if not _stage_path.is_empty(): menu._update_thumbnail_buttons()
		else:
			References.remember_fingerprint(_job.scope, item.identity, key, item.version, key)
			if item.kind == "image": menu.directory_artwork.remember(_job.scope, item)
		if _stage_path.is_empty(): menu._update_thumbnail_buttons()
		else: Cache.texture(key)
	_record_finished("stored" if stored else ("cache_failed" if current else "discarded"), _job.result)
	_stage_path = ""
	_private_image = null
	_reset_job()

func _source_name() -> String:
	match menu.section:
		menu.Section.LOCAL: return "local"
		menu.Section.SMB: return "smb"
		menu.Section.DLNA: return "dlna"
	return ""

static func _diagnostics_allowed() -> bool:
	return Privacy.mode == Privacy.ALL and (Privacy.vault == null or not Privacy.vault.protected)

func _note_status(status: String) -> void:
	if not _diagnostics_allowed() or not menu.visible: return
	var source := _source_name()
	if source.is_empty(): return
	var previous: Dictionary = _diagnostic_status.get(source, {})
	if previous.get("status") == status and int(previous.get("used", -1)) == used: return
	_diagnostic_status[source] = {"status": status, "used": used}
	if not budget.policy.is_empty(): _diagnostic_admission = budget.report()

func _record_finished(outcome: String, report: Dictionary = {}) -> void:
	if not _diagnostics_allowed(): return
	var event := {"source": _job.source, "kind": _job.item.kind, "outcome": outcome,
		"elapsed_ms": Time.get_ticks_msec() - int(_job.started), "sampled": int(report.get("sampled", 0))}
	if _job.has("cancel_reason"): event["cancel_reason"] = _job.cancel_reason
	if _job.has("retry"): event["retry"] = _job.retry
	if outcome == "cache_failed":
		event["cache_phase"] = "stage" if _stage_path.is_empty() else "commit"
	var diagnostic: Variant = report.get("diagnostic", {})
	if diagnostic is Dictionary:
		for key in ["stage", "reason", "transport", "container", "codec"]:
			var label := str(diagnostic.get(key, ""))
			if label.length() <= 48 and label.replace(",", "_").is_valid_identifier(): event[key] = label
		for key in ["worker_ms", "media_bytes", "http_status"]:
			if diagnostic.has(key): event[key] = maxi(0, int(diagnostic[key]))
	_remember_diagnostic(event)

func _remember_diagnostic(event: Dictionary) -> void:
	event["monotonic_ms"] = Time.get_ticks_msec()
	_diagnostic_recent.append(event)
	if _diagnostic_recent.size() > DIAGNOSTIC_MAX_RECENT: _diagnostic_recent.pop_front()

func record_declared_cover(kind: String, outcome: String, http_status: int, bytes: int, started: int) -> void:
	if not _diagnostics_allowed(): return
	_remember_diagnostic({"source": "dlna", "kind": kind, "stage": "xml_cover", "outcome": outcome,
		"http_status": http_status, "media_bytes": bytes, "elapsed_ms": Time.get_ticks_msec() - started})

static func declared_cover_failure(result: int) -> String:
	match result:
		HTTPRequest.RESULT_TIMEOUT: return "io_timeout"
		HTTPRequest.RESULT_BODY_SIZE_LIMIT_EXCEEDED: return "read_limit"
		HTTPRequest.RESULT_SUCCESS: return "http_error"
	return "request_failed"

func diagnostics_snapshot() -> Dictionary:
	if not _diagnostics_allowed(): return {}
	var snapshot := {"enabled": {"local": enabled, "smb": smb_enabled, "dlna": dlna_enabled}, "limit": limit,
		"frame_protection": budget.protect_preview_frames,
		"status": _diagnostic_status.duplicate(true), "recent": _diagnostic_recent.duplicate(true),
		"admission": _diagnostic_admission.duplicate()}
	if not _job.is_empty():
		snapshot.active = {"source": _job.source, "kind": _job.item.kind, "cancelled": _cancelled,
			"phase": "cache_write" if _writer >= 0 else "worker",
			"elapsed_ms": Time.get_ticks_msec() - int(_job.started)}
	return snapshot

func clear_diagnostics() -> void:
	_diagnostic_status.clear()
	_diagnostic_recent.clear()
	_diagnostic_admission.clear()

func _backoff_for_visit() -> Dictionary:
	var state: Dictionary = _backoff_by_scope.get(_visit, {})
	_backoff_by_scope.erase(_visit)
	_backoff_by_scope[_visit] = state
	if _backoff_by_scope.size() > BACKOFF_SCOPES:
		_backoff_by_scope.erase(_backoff_by_scope.keys().front())
	return state

func _temporary() -> void:
	var state := _backoff_for_visit()
	var now := Time.get_ticks_msec()
	var failures := 1 + (int(state.get("failures", 0)) if now < int(state.get("keep_until", 0)) else 0)
	state.failures = failures
	if failures >= 3:
		if now >= int(state.get("until", 0)): state.probe_used = false
		state.until = now + mini(30, 5 * (failures - 2)) * 60000
	state.keep_until = maxi(now, int(state.get("until", 0))) + 5 * 60000

func cancel(reason: String = "cancelled") -> void:
	menu._set_thumbnail_reading(false)
	if _job.is_empty() or _cancelled: return
	_cancelled = true
	_job["cancel_reason"] = reason
	if _native_id > 0 and is_instance_valid(_native_host): _native_host.local_thumbnail_cancel(_native_id)

func _reset_job() -> void:
	_job = {}
	_native_host = null
	_native_id = -1
	_reading_at = -1

func attach() -> void:
	_writer_lock.lock()
	_disposed = false
	_writer_lock.unlock()

func close() -> void:
	cancel()
	budget.stop()
	_writer_lock.lock()
	_disposed = true
	var path := _stage_path
	_stage_path = ""
	_writer_lock.unlock()
	if not path.is_empty(): DirAccess.remove_absolute(path)
	if _native_id > 0 and Methods.supports(_native_host, "local_thumbnail_abandon"):
		_native_host.local_thumbnail_abandon(_native_id)
