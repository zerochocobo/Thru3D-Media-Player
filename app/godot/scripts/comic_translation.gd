extends RefCounted
## Anonymous protocols verified against plainheart/bing-translate-api (MIT),
## revision f37b17b8bc7848b3be38f4440bec5285ad1fd3e2; see docs/COMIC_READING.md and third_party/bing-translate-api/LICENSE.txt.
const Protocol := preload("res://scripts/comic_translation_protocol.gd")
const Overlay := preload("res://scripts/comic_translation_overlay.gd")
const I18n := preload("res://scripts/i18n.gd")
const WorkGate := preload("res://scripts/translation_work_gate.gd")
const Transport := preload("res://scripts/translation_transport.gd")
const SECTION := "comic_translation"
const EDGE := "https://edge.microsoft.com/translate/translatetext"
const UA := "Thru3D/ComicTranslation"
const RETRY_MS := 60000
var photo: Node3D
var overlay: RefCounted
var enabled := false
var target := "zh-Hans"
var source := "auto"
var text_size := 1.0
var appearance := "light"
var state := "off"
var provider := ""
var entries := []
var cache := {} # Bounded, memory only; no OCR text or translations on disk.
var failed := {} # key -> failure time; retried once RETRY_MS has passed
var jobs := []
var current := []
var epoch := -1
var generation := 0
var _signature := ""
var _regions := []
var _request: Node # in-flight HTTPRequest (legacy A/B) or the keep-alive transport
var _transport: Node
var _stage := ""
var _origin := "https://www.bing.com"
var _cookies := {}
var _session := {}
var _expires := 0
var _redirects := 0
var _next_at := 0
var _cooldown := WorkGate.cooldown
var priority := 1
var _active := false
var _overlay_dirty := false
var request_spacing_ms := 500
var request_timeout := 12.0 # seconds; live subtitles fall back to Edge sooner
var cache_limit := 256 # entries; video subtitles keep more so seeking back needs no request
var consecutive_failures := 0 # batches no provider translated; reset by any success
# Diagnostic counts and timings only, never text. stats_mark is the last start/seek.
var stats := {}
var stats_mark := 0
var _seen := {} # key -> when first observed untranslated
var _sent_at := 0
var _wait_since := -1
var _mismatches := 0
var _finished_at := 0
## Set by live subtitles while an untranslated line is about to show: the next
## batch only waits for the shared 0.5 s request gap, not the client spacing.
var urgent := false
## Keys of those lines. They go to Edge (about a third of Bing's time on the
## Quest) while lines translated ahead keep Bing's better wording.
var urgent_keys := {}

func _init(owner: Node3D, visual: bool = true) -> void:
	photo = owner
	if visual: overlay = Overlay.new(owner)

func load_settings(settings: ConfigFile) -> void:
	target = Protocol.language(str(settings.get_value(SECTION, "target", I18n.language)))
	if target == "auto": target = "en"
	source = Protocol.language(str(settings.get_value(SECTION, "source", "auto")))
	enabled = false # Activation lasts only for the open reading batch.
	var size: Variant = settings.get_value(SECTION, "text_size", 1.0)
	text_size = float(size) if size is float or size is int else 1.0
	if text_size not in [0.85, 1.0, 1.2]: text_size = 1.0
	appearance = str(settings.get_value(SECTION, "appearance", "light"))
	if appearance not in ["light", "dark"]: appearance = "light"

func save(settings: ConfigFile) -> void:
	if settings.has_section_key(SECTION, "enabled"): settings.erase_section_key(SECTION, "enabled")
	if settings.has_section_key(SECTION, "show_original"): settings.erase_section_key(SECTION, "show_original")
	for key in ["target", "source", "text_size", "appearance"]: settings.set_value(SECTION, key, get(key))

func option(key: String, value: Variant) -> bool:
	if value is Dictionary: value = value.get("value")
	match key:
		"translation_enabled": enabled = value == true
		"translation_target":
			if str(value) not in Protocol.LANGUAGES: return false
			target = str(value)
		"translation_source":
			if str(value) not in Protocol.LANGUAGES and value != "auto": return false
			source = str(value)
		"translation_size":
			if not (value is float or value is int) or float(value) not in [0.85, 1.0, 1.2]: return false
			text_size = float(value); _overlay_dirty = true; return true
		"translation_appearance":
			if value not in ["light", "dark"]: return false
			appearance = value; _overlay_dirty = true; return true
		_: return false
	reset(not enabled)
	return true

func reset(clear_cache: bool = false) -> void:
	generation += 1
	_cancel_request()
	WorkGate.release(self)
	jobs.clear(); current.clear(); entries.clear(); failed.clear(); _seen.clear()
	_signature = ""; epoch = -1; _regions = []; _overlay_dirty = false
	_wait_since = -1; consecutive_failures = 0
	state = "waiting" if enabled else "off"
	if overlay:
		if clear_cache: overlay.close()
		else: overlay.clear()
	if clear_cache:
		cache.clear(); _cookies.clear(); _session.clear(); _expires = 0
		if is_instance_valid(_transport): _transport.close_all()

func _cancel_request() -> void:
	if is_instance_valid(_request):
		if _request == _transport: _transport.cancel()
		else: _request.cancel_request(); _request.queue_free()
	_request = null

func retry() -> void:
	failed.clear(); _signature = "" # Existing provider cooldowns remain in force.

func observe_sentences(sentences: Array, source_language: String, target_language: String) -> void:
	# Shared verified transport for video ASR; only finalized, bounded sentences.
	source = source_language; target = target_language
	var next := []
	for sentence: Dictionary in sentences:
		var text := Protocol.normalize(str(sentence.get("text", "")), source)
		if text.is_empty() or text.length() > 1000 or source == target: continue
		next.append({"text": text, "source": source, "target": target, "key": Protocol.cache_key(text, source, target)})
		if next.size() >= 64: break
	var signature := str(next).sha256_text()
	if signature == _signature: return
	_signature = signature; entries = next
	var now := Time.get_ticks_msec()
	for entry: Dictionary in entries:
		if not cache.has(entry.key) and not _seen.has(entry.key) and _seen.size() < 512: _seen[entry.key] = now
	_schedule()

func observe(pages: Array, regions: Array, page_epoch: int) -> void:
	if not enabled: return
	if epoch != page_epoch:
		reset(); epoch = page_epoch
	var identity := []
	for page: Dictionary in pages:
		identity.append([page.get("page"), page.get("page_size")])
		for block: Dictionary in page.get("blocks", []):
			identity.append([block.get("id"), block.get("text"), block.get("language"), block.get("eligible")])
	var signature := str([identity, regions, source, target]).sha256_text()
	if signature == _signature: return
	_signature = signature; _regions = regions.duplicate(); entries = []
	for page: Dictionary in pages:
		var index := int(page.get("page", -1))
		var dimensions: Array = page.get("page_size", [])
		if index < 0 or index >= regions.size() or dimensions.size() != 2 or dimensions[0] <= 0 or dimensions[1] <= 0: continue
		for block: Dictionary in page.get("blocks", []):
			if not block.get("eligible", false): continue
			var lang := source if source != "auto" else Protocol.language(str(block.get("language", "auto")))
			var text := Protocol.normalize(str(block.get("text", "")), lang)
			if text.is_empty() or text.length() > 1000 or "T3D" in text: continue
			# Same-language bubbles stay original, without sending a request.
			if lang == target: continue
			entries.append({"text": text, "source": lang, "target": target, "key": Protocol.cache_key(text, lang, target),
				"page": index, "id": int(block.get("id", -1)), "block": block,
				"size": Vector2(dimensions[0], dimensions[1]), "region": regions[index]})
	_schedule()
	_overlay_dirty = true

func _schedule() -> void:
	var unique := {}; var pending := {}
	for entry: Dictionary in current: pending[entry.key] = true
	for entry: Dictionary in entries:
		if cache.has(entry.key) or pending.has(entry.key): continue
		if failed.has(entry.key) and Time.get_ticks_msec() - int(failed[entry.key]) < RETRY_MS: continue
		unique[entry.key] = entry
	jobs = Protocol.batches(unique.values())
	_next_at = maxi(_next_at, Time.get_ticks_msec() + 300) # Coalesce newly recognized spread pages.
	_status()

func tick(active: bool) -> void:
	_active = active
	if not enabled: return
	if not active:
		if is_instance_valid(_request):
			generation += 1; _cancel_request(); current = []; _signature = ""
		WorkGate.release(self)
		if overlay: overlay.visible(false)
		return
	if overlay and _overlay_dirty:
		overlay.update(entries, cache, text_size, appearance); _overlay_dirty = false
	if overlay: overlay.sync(true)
	var ready_at := _next_at if not urgent or WorkGate.legacy else mini(_next_at, _finished_at + 500)
	if _request or not current.is_empty() or Time.get_ticks_msec() < ready_at: return
	# Failed lines still on screen retry once their interval passes, not only when new text arrives.
	if jobs.is_empty() and entries.any(func(entry): return failed.has(entry.key) and not cache.has(entry.key) and Time.get_ticks_msec() - int(failed[entry.key]) >= RETRY_MS):
		_schedule(); return
	if jobs.is_empty(): return
	while not jobs.is_empty():
		jobs[0] = jobs[0].filter(func(entry): return not cache.has(entry.key))
		if not jobs[0].is_empty(): break
		jobs.pop_front()
	if jobs.is_empty(): _status(); return
	if _wait_since < 0: _wait_since = Time.get_ticks_msec()
	if not WorkGate.acquire(self, priority): return
	_sample("gate_wait_ms", Time.get_ticks_msec() - _wait_since); _wait_since = -1
	current = _take_urgent()
	state = "translating"
	if not current.is_empty(): _count("urgent_edge"); _edge(); return
	current = jobs.pop_front()
	if current.any(func(entry): return "T3D" in str(entry.text)): _edge(); return
	if Time.get_ticks_msec() < int(_cooldown.Bing): _edge(); return
	if _session.is_empty() or Time.get_ticks_msec() >= _expires:
		# Start from the host Bing redirected to before; a failed start returns to www.
		_session.clear(); _redirects = 0
		if WorkGate.legacy: _origin = "https://www.bing.com"
		_bootstrap()
	else: _bing()

func _headers(form: bool = false) -> PackedStringArray:
	var result := PackedStringArray(["User-Agent: " + UA])
	if form: result.append("Content-Type: application/x-www-form-urlencoded")
	var cookies: Dictionary = _cookies.get(_origin, {})
	if not cookies.is_empty():
		var pairs := PackedStringArray()
		for key: String in cookies: pairs.append(key + "=" + str(cookies[key]))
		result.append("Cookie: " + "; ".join(pairs))
	return result

func _send(stage: String, url: String, headers: PackedStringArray, method: HTTPClient.Method, body: String = "") -> void:
	_stage = stage
	if not WorkGate.legacy:
		if not is_instance_valid(_transport):
			_transport = Transport.new(); _transport.count = _count; _transport.cost = _time
			photo.add_child(_transport)
		_transport.timeout = request_timeout
		_sent_at = Time.get_ticks_msec(); _count("requests", stage)
		_request = _transport
		if _transport.request(url, headers, method, body, _reply.bind(generation, stage)) != OK:
			_cancel_request(); _failure(stage, 0, PackedStringArray())
		return
	_request = HTTPRequest.new()
	_request.timeout = 12.0 if WorkGate.legacy else request_timeout
	_request.use_threads = true
	_request.body_size_limit = 2 * 1024 * 1024
	_request.max_redirects = 0 # Inspect redirects before forwarding anonymous cookies.
	photo.add_child(_request)
	_sent_at = Time.get_ticks_msec(); _count("requests", stage)
	_request.request_completed.connect(_reply.bind(generation, stage), CONNECT_ONE_SHOT)
	if _request.request(url, headers, method, body) != OK:
		_cancel_request(); _failure(stage, 0, PackedStringArray())

func _bootstrap() -> void: _send("session", _origin + "/translator", _headers(), HTTPClient.METHOD_GET)

static func form(values: Dictionary) -> String:
	var pairs := PackedStringArray()
	for key: String in values: pairs.append(key.uri_encode() + "=" + str(values[key]).uri_encode())
	return "&".join(pairs)

func _bing() -> void:
	var query := form({"isVertical": "1", "IG": _session.ig, "IID": _session.iid})
	var body := form({"fromLang": "auto-detect" if current[0].source == "auto" else current[0].source,
		"to": target, "text": _bing_text(), "key": _session.key, "token": _session.token})
	var headers := _headers(true); headers.append("Referer: " + _origin + "/translator")
	_send("bing", _origin + "/ttranslatev3?" + query, headers, HTTPClient.METHOD_POST, body)

## Bing's model drops the markers around a lone line about a third of the time
## (Quest 3, 2026-11-24); one line needs no boundaries to split on.
func _bing_text() -> String:
	return str(current[0].text) if current.size() == 1 and not WorkGate.legacy else Protocol.bing_text(current)

func _edge() -> void:
	if Time.get_ticks_msec() < int(_cooldown.Edge):
		# Both providers are cooling down. Keep the sentences queued instead
		# of failing them without a request; resume when one is available.
		jobs.push_front(current); current = []
		WorkGate.release(self)
		_next_at = mini(int(_cooldown.Bing), int(_cooldown.Edge))
		_status(); return
	var query := {"to": target, "isEnterpriseClient": "false"}
	if current[0].source != "auto": query["from"] = current[0].source
	var texts := []
	for entry: Dictionary in current: texts.append(entry.text)
	_send("edge", EDGE + "?" + form(query), PackedStringArray(["User-Agent: " + UA, "Content-Type: application/json"]), HTTPClient.METHOD_POST, JSON.stringify(texts))

func _reply(result: int, code: int, headers: PackedStringArray, body: PackedByteArray, stamp: int, stage: String) -> void:
	if stamp != generation: return
	_cancel_request()
	if not enabled or not _active or current.is_empty(): WorkGate.release(self); return
	if stage != "edge": _remember_cookies(headers)
	if stage == "session" and code in [301, 302, 303, 307, 308] and _redirects < 3:
		var destination := header(headers, "location")
		var host := destination.get_slice("/", 2)
		if destination.begins_with("https://") and host in ["www.bing.com", "cn.bing.com", "bing.com"]:
			_origin = "https://" + host; _redirects += 1; _bootstrap(); return
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		push_warning("Translation %s failed: result %d, HTTP %d" % [stage, result, code]) # No text or URL.
		_count("failures", stage + "_" + ("timeout" if result == HTTPRequest.RESULT_TIMEOUT else str(code if code else result)))
		_failure(stage, code, headers); return
	if stage == "session":
		if not _parse_session(body.get_string_from_utf8()): _failure(stage, 0, headers); return
		_bing(); return
	var data: Variant = JSON.parse_string(body.get_string_from_utf8())
	var outputs := []
	if stage == "edge": outputs = Protocol.parse_edge(data, current.size(), target)
	elif data is Array and not data.is_empty():
		var text := Protocol.translated(data[0], target)
		if current.size() == 1 and not WorkGate.legacy: outputs = [text] if not text.is_empty() and text.length() <= 2000 else []
		else: outputs = Protocol.split_bing(text, current.size())
	if outputs.size() != current.size():
		push_warning("Translation %s reply did not match the request" % stage)
		_count("mismatch")
		if stage == "bing" and not WorkGate.legacy:
			_mismatches += 1
			if current.size() == 1 or _mismatches < 3: _resend(); return
		_failure(stage, 0, headers); return
	if stage == "bing": _mismatches = 0
	_count("ok", stage); _sample_in("batch_ms", stage, Time.get_ticks_msec() - _sent_at)
	provider = "Edge" if stage == "edge" else "Bing"
	_finish(outputs)

## Removes up to one batch of due lines from the queue, keeping the rest in order.
func _take_urgent() -> Array:
	if WorkGate.legacy or urgent_keys.is_empty() or Time.get_ticks_msec() < int(_cooldown.Edge): return []
	var taken := []
	for batch: Array in jobs:
		for entry: Dictionary in batch:
			if urgent_keys.has(entry.key) and taken.size() < Protocol.MAX_BATCH and (taken.is_empty() or entry.source == taken[0].source): taken.append(entry)
	if taken.is_empty(): return []
	var keys := {}
	for entry: Dictionary in taken: keys[entry.key] = true
	for i in jobs.size(): jobs[i] = jobs[i].filter(func(entry): return not keys.has(entry.key))
	jobs = jobs.filter(func(batch): return not batch.is_empty())
	return taken

## A changed marker is a reply format problem, not an outage: halve the batch
## and ask Bing again; a single line goes to Edge without cooling Bing down.
func _resend() -> void:
	if current.size() == 1:
		if Time.get_ticks_msec() < int(_cooldown.Edge): _finish([])
		else: _edge()
		return
	_count("split")
	var half := int(current.size() / 2.0)
	jobs.push_front(current.slice(half)); jobs.push_front(current.slice(0, half))
	current = []
	WorkGate.release(self)
	_status()

## The shared slot hands this batch's turn to waiting live subtitles; the batch
## is asked again later.
func preempt() -> void:
	generation += 1; _cancel_request()
	if not current.is_empty(): jobs.push_front(current)
	current = []; _count("preempted")
	_status()

static func header(headers: PackedStringArray, key: String) -> String:
	for value: String in headers:
		if value.get_slice(":", 0).to_lower() == key: return value.substr(value.find(":") + 1).strip_edges()
	return ""

func _remember_cookies(headers: PackedStringArray) -> void:
	var cookies: Dictionary = _cookies.get(_origin, {})
	for value: String in headers:
		if not value.to_lower().begins_with("set-cookie:"): continue
		var pair := value.substr(value.find(":") + 1).strip_edges().get_slice(";", 0)
		var split := pair.find("=")
		if split > 0 and "\n" not in pair and "\r" not in pair:
			cookies[pair.left(split)] = pair.substr(split + 1)
	_cookies[_origin] = cookies

func _parse_session(html: String) -> bool:
	var ig := RegEx.create_from_string('IG:"([^"]+)"').search(html)
	var iid := RegEx.create_from_string('data-iid="([^"]+)"').search(html)
	var helper := RegEx.create_from_string('params_AbusePreventionHelper\\s*=\\s*(\\[[^\\]]+\\])').search(html)
	if not ig or not iid or not helper: return false
	var values: Variant = JSON.parse_string(helper.get_string(1))
	if not values is Array or values.size() != 3 or not values[1] is String: return false
	# Godot parses JSON numbers as doubles; str(large_float) uses scientific
	# notation, which Bing rejects. The page nonce is an integer timestamp.
	if not (values[0] is float or values[0] is int) or not (values[2] is float or values[2] is int): return false
	_session = {"ig": ig.get_string(1), "iid": iid.get_string(1), "key": str(int(values[0])), "token": values[1]}
	_expires = Time.get_ticks_msec() + clampi(int(values[2]) - 60000, 1000, 3000000)
	return true

func _failure(stage: String, code: int, headers: PackedStringArray) -> void:
	var engine := "Edge" if stage == "edge" else "Bing"
	var delay := 60000 if code != 429 else 300000
	var retry_after := header(headers, "retry-after")
	if retry_after.is_valid_int(): delay = maxi(delay, int(retry_after) * 1000)
	_cooldown[engine] = Time.get_ticks_msec() + delay
	if stage == "session": _origin = "https://www.bing.com"
	if stage != "edge":
		if code in [401, 403]: _session.clear(); _expires = 0
		_edge()
	else: _finish([])

func _finish(outputs: Array) -> void:
	# Each client keeps its own spacing below; the shared slot only separates requests.
	WorkGate.release(self, maxi(500, request_spacing_ms) if WorkGate.legacy else 500)
	var now := Time.get_ticks_msec()
	consecutive_failures = 0 if outputs.size() == current.size() else consecutive_failures + 1
	for i in current.size():
		var key: String = current[i].key
		if outputs.size() == current.size():
			while cache.size() >= cache_limit: cache.erase(cache.keys()[0])
			cache[key] = {"text": outputs[i], "provider": provider}
			if _seen.has(key): _sample("line_ms", [now - int(_seen[key]), now - stats_mark]); _seen.erase(key)
		else:
			while failed.size() >= 256: failed.erase(failed.keys()[0])
			failed[key] = Time.get_ticks_msec()
	current = []; _overlay_dirty = true
	_finished_at = Time.get_ticks_msec()
	_next_at = _finished_at + maxi(500, request_spacing_ms)
	_status()

func _count(group: String, name: String = "") -> void:
	if name.is_empty(): stats[group] = int(stats.get(group, 0)) + 1; return
	var counts: Dictionary = stats.get(group, {})
	counts[name] = int(counts.get(name, 0)) + 1; stats[group] = counts

func _time(name: String, usec: int) -> void:
	var value: Array = stats.get(name, [0, 0, 0])
	stats[name] = [int(value[0]) + 1, int(value[1]) + usec, maxi(int(value[2]), usec)]

func _sample(group: String, value: Variant) -> void:
	var values: Array = stats.get(group, [])
	if values.size() >= 2000: values.pop_front()
	values.append(value); stats[group] = values

func _sample_in(group: String, name: String, value: Variant) -> void:
	var groups: Dictionary = stats.get(group, {})
	var values: Array = groups.get(name, [])
	if values.size() >= 2000: values.pop_front()
	values.append(value); groups[name] = values; stats[group] = groups

func _status() -> void:
	if not enabled: state = "off"
	elif not jobs.is_empty() or not current.is_empty(): state = "translating"
	elif not failed.is_empty(): state = "partial" if translated_count() > 0 else "error"
	else: state = "ready" if not entries.is_empty() else "waiting"

## Milliseconds until a provider is available again; 0 when one can be asked now.
func cooldown_ms() -> int:
	return maxi(0, mini(int(_cooldown.Bing), int(_cooldown.Edge)) - Time.get_ticks_msec())

func pending_count() -> int:
	var count := current.size()
	for batch: Array in jobs: count += batch.size()
	return count

## A shown entry failed recently and will be retried later.
func failing() -> bool:
	for entry: Dictionary in entries:
		if failed.has(entry.key) and Time.get_ticks_msec() - int(failed[entry.key]) < RETRY_MS: return true
	return false

func translated_count() -> int:
	var count := 0
	for entry: Dictionary in entries:
		if cache.has(entry.key): count += 1
	return count

func speech_language() -> String:
	return "zh" if target in ["zh-Hans", "zh-Hant"] else target

func speech_rows(pages: Array, page_epoch: int) -> Array:
	var result := []
	if not enabled or epoch != page_epoch: return result
	for page: Dictionary in pages:
		for block: Dictionary in page.get("blocks", []):
			if not block.get("eligible", false): continue
			var lang := source if source != "auto" else Protocol.language(str(block.get("language", "auto")))
			var original := Protocol.normalize(str(block.get("text", "")), lang)
			var key := Protocol.cache_key(original, lang, target)
			# An already matching language needs no network, but still uses the target TTS language.
			var text: String = original if lang == target else str(cache.get(key, {}).get("text", ""))
			if text.is_empty() or text.length() > 2000: continue
			result.append({"page": int(page.get("page", -1)), "id": int(block.get("id", -1)), "text": text})
	return result

func snapshot() -> Dictionary:
	return {"translation_enabled": enabled, "translation_target": target, "translation_source": source,
		"translation_size": text_size, "translation_appearance": appearance, "translation_state": state,
		"translation_count": translated_count(), "translation_total": entries.size(), "translation_provider": provider}

func close() -> void:
	reset(true)
	if is_instance_valid(_transport): _transport.queue_free()
	_transport = null
	if overlay: overlay.close()
