extends Node
## Scenes offered for download. The list ships with the app (catalog.json, pictures beside it);
## only the scene files come from the network. A file that the server says is gone is shown as
## withdrawn; nothing else about the list changes without a new app version. Every channel
## offers it, and no screen names the server the files come from.
signal changed
const Channel := preload("res://scripts/distribution_channel.gd")
const I18n := preload("res://scripts/i18n.gd")
const CATALOG := "res://scene_library/catalog.json"
const PREVIEWS := "res://scene_library/previews/"
## Public builds have no bundled download origins. Set sites for a self-hosted catalog.
const WORLD: Array = []
const MAINLAND: Array = []
## A lost connection is tried again this many times round all the sites before the card says so.
const ROUNDS := 3
const RETRY_WAIT_MS := 2000
## A site that does not take the connection this soon is passed over for the next.
const CONNECT_MS := 8000
const QUEUED := "queued"
const LOADING := "loading"
const READY := "ready"
const WITHDRAWN := "withdrawn"
const FAILED := "failed"
const CHUNK := 256 * 1024
const STALL_MS := 30000
const MAX_CATALOG_BYTES := 1024 * 1024
var directory := "user://scene_gallery"
## Set to use these sites and no others; tests point this at a local server.
var sites: Array = []
var connect_ms := CONNECT_MS
var retry_wait_ms := RETRY_WAIT_MS
## The site that last delivered: asked first from then on, so one that never answers costs its wait once.
var _good: Array = []
var rows: Array[Dictionary] = []
## slug -> {state, error}; a slug with no entry is simply on offer.
var states := {}
var _queue: Array[Dictionary] = []
var _thread: Thread
var _lock := Mutex.new()
var _current := ""
var _received := 0
var _expected := 1
var _stop := false

## Every build and channel offers it (opened to Release by the owner, 2026-11-17).
static func offered() -> bool:
	return true

## Whether the viewer is most likely in mainland China: the domestic store build, or the app in
## Simplified Chinese. A wrong guess costs speed, not the download: the other sites follow.
static func mainland() -> bool:
	return Channel.current() == "pico_cn_store" or I18n.language == "zh"

## The sites to try, in order, for a download starting now.
func site_order() -> Array:
	var order: Array = sites.duplicate() if not sites.is_empty() else (MAINLAND + WORLD if mainland() else WORLD + MAINLAND)
	if order.has(_good):
		order.erase(_good)
		order.push_front(_good)
	return order

func load_catalog(path: String = CATALOG) -> void:
	rows.clear()
	var file := FileAccess.open(path, FileAccess.READ)
	var parser := JSON.new()
	if file == null or file.get_length() > MAX_CATALOG_BYTES or parser.parse(file.get_as_text()) != OK or not parser.data is Dictionary: return
	var listed: Variant = parser.data.get("scenes")
	if not listed is Array: return
	for item in listed:
		if not item is Dictionary or not item.get("tiers") is Dictionary: continue
		var slug := str(item.get("slug", ""))
		if slug.is_empty() or slug != slug.validate_filename() or row(slug).size() > 0: continue
		var tiers := {}
		for name in item.tiers:
			var tier: Variant = item.tiers[name]
			# A file name is all the server is ever asked for: nothing in it may leave the scene folder.
			if tier is Dictionary and str(tier.get("file", "")) == str(tier.get("file", "")).validate_filename() and str(tier.get("sha256", "")).length() == 64 and int(tier.get("bytes", 0)) > 0:
				tiers[str(name)] = {"file": str(tier.file), "bytes": int(tier.bytes), "sha256": str(tier.sha256).to_lower()}
		if tiers.is_empty(): continue
		# `title` names the card, with one per other language the app speaks; `work` is the author's own title, for the credit.
		rows.append({"slug": slug, "title": str(item.get("title", slug)).left(80), "title_zh": str(item.get("title_zh", "")).left(80),
			"title_zh_hant": str(item.get("title_zh_hant", "")).left(80), "title_ja": str(item.get("title_ja", "")).left(80),
			"work": str(item.get("work", item.get("title", slug))).left(120), "author": str(item.get("author", "")).left(80),
			"license": str(item.get("license", "")).left(24), "source": str(item.get("source", "")).left(200), "tiers": tiers,
			"preset": item.get("preset") if item.get("preset") is Dictionary else {}})

func row(slug: String) -> Dictionary:
	for item in rows:
		if item.slug == slug: return item
	return {}

func preview(slug: String) -> Texture2D:
	var path := PREVIEWS + slug + ".jpg"
	return load(path) as Texture2D if ResourceLoader.exists(path) else null

## Where a scene's file waits once it has arrived whole, for whoever takes it into the library.
func ready_path(slug: String) -> String:
	return str(states.get(slug, {}).get("path", "")) if states.get(slug, {}).get("state", "") == READY else ""

## Asks for a scene's file for this tier of headset; one comes down at a time, the rest wait their turn.
func request(slug: String, tier: String) -> bool:
	var item := row(slug)
	if item.is_empty() or states.get(slug, {}).get("state", "") in [QUEUED, LOADING, READY]: return false
	if site_order().is_empty():
		settle(slug, "No connection")
		return false
	var chosen: Dictionary = item.tiers.get(tier, item.tiers.values()[0])
	states[slug] = {"state": QUEUED}
	_queue.append({"slug": slug, "file": chosen.file, "bytes": chosen.bytes, "sha256": chosen.sha256})
	changed.emit()
	return true

## Gives up a scene that is waiting or coming down; what has arrived stays for the next try.
func cancel(slug: String) -> void:
	var state := str(states.get(slug, {}).get("state", ""))
	if state == QUEUED:
		_queue = _queue.filter(func(job: Dictionary) -> bool: return job.slug != slug)
		states.erase(slug)
		changed.emit()
	elif state == LOADING and slug == _current:
		_lock.lock()
		_stop = true
		_lock.unlock()

## The library took the file (or could not): the scene is no longer the gallery's to track.
func settle(slug: String, problem: String = "") -> void:
	if problem.is_empty(): states.erase(slug)
	else: states[slug] = {"state": FAILED, "error": problem}
	changed.emit()

func progress(slug: String) -> float:
	if slug != _current: return 0.0
	_lock.lock()
	var fraction := float(_received) / maxf(float(_expected), 1.0)
	_lock.unlock()
	return clampf(fraction, 0.0, 1.0)

## What each card needs: `installed` maps a slug to the library entry holding it.
func snapshot(installed: Dictionary) -> Array:
	var cards: Array = []
	for item in rows:
		var state: Dictionary = states.get(item.slug, {})
		var kind := str(state.get("state", ""))
		var bytes := 0
		for tier in item.tiers.values(): bytes = maxi(bytes, int(tier.bytes))
		cards.append({"slug": item.slug, "title": item.title, "title_zh": item.title_zh, "title_zh_hant": item.title_zh_hant, "title_ja": item.title_ja, "work": item.work, "author": item.author, "license": item.license, "bytes": bytes,
			"id": str(installed.get(item.slug, "")), "state": kind, "error": str(state.get("error", "")),
			"progress": snappedf(progress(item.slug), 0.01) if kind == LOADING else 0.0})
	return cards

func _process(_delta: float) -> void:
	if _thread and not _thread.is_alive():
		var result: Dictionary = _thread.wait_to_finish()
		_thread = null
		var slug := _current
		_current = ""
		if result.get("state", "") == READY: states[slug] = {"state": READY, "path": result.path}
		elif result.get("cancelled", false): states.erase(slug)
		elif result.get("state", "") == WITHDRAWN: states[slug] = {"state": WITHDRAWN}
		else: states[slug] = {"state": FAILED, "error": str(result.get("error", "Download failed"))}
		changed.emit()
	if _thread == null and not _queue.is_empty():
		var job: Dictionary = _queue.pop_front()
		_current = job.slug
		_received = 0
		_expected = int(job.bytes)
		_stop = false
		states[job.slug] = {"state": LOADING}
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory))
		_thread = Thread.new()
		job["sites"] = site_order()
		_thread.start(_fetch.bind(job, ProjectSettings.globalize_path(directory)))
		changed.emit()

func _stopped() -> bool:
	_lock.lock()
	var stop := _stop
	_lock.unlock()
	return stop

## Worker: brings one file down, picking up where an earlier try stopped, and checks it whole.
func _fetch(job: Dictionary, folder: String) -> Dictionary:
	var target := folder.path_join(str(job.file))
	var partial := target + ".partial"
	var resumed := FileAccess.file_exists(partial)
	for attempt in 2:
		if FileAccess.file_exists(partial) and FileAccess.get_size(partial) > int(job.bytes): DirAccess.remove_absolute(partial)
		if not FileAccess.file_exists(partial) or FileAccess.get_size(partial) < int(job.bytes):
			var outcome := _gather(job, partial)
			if not outcome.is_empty(): return outcome
		# A resumed file is only as good as its checksum: no site promises the second half
		# belongs with the first.
		if FileAccess.get_size(partial) == int(job.bytes) and FileAccess.get_sha256(partial) == str(job.sha256):
			DirAccess.remove_absolute(target)
			if DirAccess.rename_absolute(partial, target) != OK: return {"error": "Could not save scene"}
			return {"state": READY, "path": target}
		DirAccess.remove_absolute(partial)
		if not resumed: break
		resumed = false
	return {"error": "Downloaded file is damaged"}

## Brings the rest of the file in from whichever site will give it. Returns {} once the body has
## ended, otherwise how the download ended. A connection lost midway is picked up again from
## what has arrived, at the next site or the same one, a few times over before giving up.
func _gather(job: Dictionary, partial: String) -> Dictionary:
	var problem := "No connection"
	for round in ROUNDS:
		var gone := 0
		var answered := 0
		var order: Array = job.sites
		for index in order.size():
			var held := FileAccess.get_size(partial) if FileAccess.file_exists(partial) else 0
			if held >= int(job.bytes): return {}
			var outcome := _transfer(job, partial, held, order[index])
			if outcome.is_empty(): _good = order[index]
			if outcome.is_empty() or outcome.has("cancelled"): return outcome
			if outcome.get("state", "") == WITHDRAWN:
				gone += 1
				answered += 1
				continue
			if outcome.get("restart", false):
				# A range the site will not serve: what is held is not part of this file.
				DirAccess.remove_absolute(partial)
				answered += 1
				continue
			problem = str(outcome.get("error", problem))
			print("[SCENE_GALLERY] site %d round %d: %s (%s)" % [index, round, problem, outcome.get("detail", "")])
			if problem in ["Could not save scene", "Not enough storage"]: return {"error": problem}
		# Withdrawn only when every site that answered says the file is gone: one lagging behind
		# another must not read as a takedown, and a takedown removes the file from all of them.
		if gone > 0 and gone == answered: return {"state": WITHDRAWN}
		for step in retry_wait_ms * (round + 1) / 100:
			if _stopped(): return {"cancelled": true}
			OS.delay_msec(100)
	return {"error": problem}

## One request to one site. Returns {} when the body ended normally, otherwise what stopped it.
func _transfer(job: Dictionary, partial: String, held: int, site: Array) -> Dictionary:
	var client := HTTPClient.new()
	var proxy := OS.get_environment("HTTPS_PROXY") if OS.has_environment("HTTPS_PROXY") else OS.get_environment("https_proxy")
	if bool(site[2]) and proxy.begins_with("http://") and OS.has_feature("pc"):
		var address := proxy.trim_prefix("http://").trim_suffix("/")
		client.set_https_proxy(address.get_slice(":", 0), int(address.get_slice(":", 1)) if address.contains(":") else 8080)
	if client.connect_to_host(str(site[0]), int(site[1]), TLSOptions.client() if site[2] else null) != OK: return {"error": "No connection", "detail": "connect refused"}
	var waited := Time.get_ticks_msec()
	while client.get_status() in [HTTPClient.STATUS_RESOLVING, HTTPClient.STATUS_CONNECTING]:
		client.poll()
		if _stopped(): return {"cancelled": true}
		if Time.get_ticks_msec() - waited > connect_ms: return {"error": "No connection", "detail": "timed out in status %d" % client.get_status()}
		OS.delay_msec(10)
	if client.get_status() != HTTPClient.STATUS_CONNECTED: return {"error": "No connection", "detail": "status %d" % client.get_status()}
	var headers := PackedStringArray(["Accept: */*"])
	if held > 0: headers.append("Range: bytes=%d-" % held)
	if client.request(HTTPClient.METHOD_GET, str(site[3]) + str(job.file).uri_encode(), headers) != OK: return {"error": "No connection", "detail": "request"}
	waited = Time.get_ticks_msec()
	while client.get_status() == HTTPClient.STATUS_REQUESTING:
		client.poll()
		if _stopped(): return {"cancelled": true}
		if Time.get_ticks_msec() - waited > STALL_MS: return {"error": "No connection", "detail": "no answer"}
		OS.delay_msec(10)
	if not client.has_response(): return {"error": "No connection", "detail": "status %d after request" % client.get_status()}
	var code := client.get_response_code()
	if code in [404, 410]: return {"state": WITHDRAWN}
	if code == 416: return {"error": "Download failed", "restart": true}
	if code not in [200, 206]: return {"error": "Download failed", "detail": "http %d" % code}
	# 200 to a ranged request is the whole file again: start over rather than append to it.
	var append := code == 206 and held > 0
	var file := FileAccess.open(partial, FileAccess.READ_WRITE if append else FileAccess.WRITE)
	if file == null: return {"error": "Could not save scene"}
	if append: file.seek_end()
	else: held = 0
	_lock.lock()
	_received = held
	_lock.unlock()
	waited = Time.get_ticks_msec()
	while client.get_status() == HTTPClient.STATUS_BODY:
		client.poll()
		var chunk := client.read_response_body_chunk()
		if chunk.is_empty():
			if Time.get_ticks_msec() - waited > STALL_MS: return {"error": "No connection", "detail": "stalled"}
			OS.delay_msec(5)
		else:
			waited = Time.get_ticks_msec()
			file.store_buffer(chunk)
			if file.get_error() != OK: return {"error": "Not enough storage"}
			_lock.lock()
			_received += chunk.size()
			_lock.unlock()
		if _stopped(): return {"cancelled": true}
	file.close()
	# The server closing early leaves a short file: say so, so the rest is asked for again.
	if FileAccess.get_size(partial) < int(job.bytes): return {"error": "No connection", "detail": "ended early"}
	return {}

func _exit_tree() -> void:
	_lock.lock()
	_stop = true
	_lock.unlock()
	if _thread: _thread.wait_to_finish()
