extends Node
## Keep-alive HTTP(S) for translation requests. HTTPRequest opens a new TCP/TLS
## connection for every request; for Microsoft translation that setup was over
## half of each request (2026-11-24). One connection per host. Each frame one
## polling step runs on a worker thread, since a TLS handshake can take over
## 10 ms; the main thread only starts steps and delivers replies. A reused
## connection that fails before any reply is retried once on a new connection.
## Never follows redirects; gzip replies are decompressed.
const IDLE_MS := 30000 # servers drop idle keep-alive connections; start afresh after this
var timeout := 12.0
var body_size_limit := 2 * 1024 * 1024
var count := Callable() # (group, name) diagnostics: connections opened/reused/retried
var cost := Callable() # (name, usec) main-thread time spent polling
var _connections := {} # "scheme://host:port" -> {"client": HTTPClient, "used_at": msec}
var _job := {}
var _task := -1 # worker step in progress; _job and _connections belong to it until it completes

func busy() -> bool: return not _job.is_empty()

## [done] receives (result, response_code, headers, body) like HTTPRequest.request_completed.
func request(url: String, headers: PackedStringArray, method: HTTPClient.Method, body: String, done: Callable) -> Error:
	_join() # a reply is delivered while the step that produced it may still be returning
	if busy(): return ERR_BUSY
	var secure := url.begins_with("https://")
	if not secure and not url.begins_with("http://"): return ERR_INVALID_PARAMETER
	var rest := url.substr(8 if secure else 7)
	var slash := rest.find("/")
	var authority := rest if slash < 0 else rest.left(slash)
	var host := authority
	var port := 443 if secure else 80
	if ":" in authority:
		host = authority.get_slice(":", 0); port = authority.get_slice(":", 1).to_int()
	if host.is_empty() or port <= 0: return ERR_INVALID_PARAMETER
	var sent := headers.duplicate(); sent.append("Accept-Encoding: gzip")
	_job = {"key": ("https://" if secure else "http://") + host + ":" + str(port), "host": host, "port": port, "secure": secure,
		"path": "/" if slash < 0 else rest.substr(slash), "headers": sent, "method": method, "body": body, "done": done,
		"deadline": Time.get_ticks_msec() + int(timeout * 1000), "retried": false}
	_start()
	return OK

## Drops the request in flight without calling back; its connection is closed
## because the reply may still arrive on it.
func cancel() -> void:
	_join()
	if _job.is_empty(): return
	_drop(str(_job.key))
	_job = {}

func close_all() -> void:
	cancel()
	for key: String in _connections.keys(): _drop(key)

func _exit_tree() -> void: close_all()

func _join() -> void:
	if _task >= 0: WorkerThreadPool.wait_for_task_completion(_task); _task = -1

func _start() -> void:
	var entry: Dictionary = _connections.get(_job.key, {})
	var client: HTTPClient = entry.get("client")
	if client:
		client.poll() # notices a connection the server has closed
		if client.get_status() != HTTPClient.STATUS_CONNECTED or Time.get_ticks_msec() - int(entry.used_at) >= IDLE_MS:
			_drop(str(_job.key)); client = null
	_job.reused = client != null
	if client:
		_note("reused")
		_job.client = client; _send(); return
	client = HTTPClient.new()
	var error := client.connect_to_host(str(_job.host), int(_job.port), TLSOptions.client() if _job.secure else null)
	if error != OK: _fail(HTTPRequest.RESULT_CANT_CONNECT); return
	_note("opened")
	_connections[_job.key] = {"client": client, "used_at": Time.get_ticks_msec()}
	_job.client = client; _job.stage = "connect"

func _send() -> void:
	_job.stage = "send"
	var client: HTTPClient = _job.client
	if client.request(_job.method, str(_job.path), _job.headers, str(_job.body)) != OK:
		_fail(HTTPRequest.RESULT_CONNECTION_ERROR, true)

func _process(_delta: float) -> void:
	if _task >= 0:
		if not WorkerThreadPool.is_task_completed(_task): return
		_join()
	if _job.is_empty(): return
	_task = WorkerThreadPool.add_task(_timed_step, false, "translation request")

func _timed_step() -> void:
	var began := Time.get_ticks_usec()
	_step()
	if cost.is_valid(): cost.call_deferred("poll_us", Time.get_ticks_usec() - began)

func _step() -> void:
	if Time.get_ticks_msec() > int(_job.deadline): _fail(HTTPRequest.RESULT_TIMEOUT); return
	var client: HTTPClient = _job.client
	client.poll()
	var status := client.get_status()
	match str(_job.stage):
		"connect":
			match status:
				HTTPClient.STATUS_RESOLVING, HTTPClient.STATUS_CONNECTING: pass
				HTTPClient.STATUS_CONNECTED: _send()
				HTTPClient.STATUS_CANT_RESOLVE: _fail(HTTPRequest.RESULT_CANT_RESOLVE)
				HTTPClient.STATUS_TLS_HANDSHAKE_ERROR: _fail(HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR)
				_: _fail(HTTPRequest.RESULT_CANT_CONNECT)
		"send":
			if status == HTTPClient.STATUS_REQUESTING: return
			if not client.has_response() or status not in [HTTPClient.STATUS_BODY, HTTPClient.STATUS_CONNECTED]:
				_fail(HTTPRequest.RESULT_CONNECTION_ERROR, true); return
			_job.stage = "body"; _job.code = client.get_response_code(); _job.response_headers = client.get_response_headers()
			_job.chunks = PackedByteArray()
			_read(client, status)
		"body":
			_read(client, status)

func _read(client: HTTPClient, status: int) -> void:
	while status == HTTPClient.STATUS_BODY:
		var chunk := client.read_response_body_chunk()
		if chunk.is_empty(): return # more arrives on a later frame
		var chunks: PackedByteArray = _job.chunks
		chunks.append_array(chunk); _job.chunks = chunks
		if chunks.size() > body_size_limit: _fail(HTTPRequest.RESULT_BODY_SIZE_LIMIT_EXCEEDED); return
		client.poll(); status = client.get_status()
	if status != HTTPClient.STATUS_CONNECTED and status != HTTPClient.STATUS_DISCONNECTED:
		_fail(HTTPRequest.RESULT_CONNECTION_ERROR); return
	var headers: PackedStringArray = _job.response_headers
	var body: PackedByteArray = _job.chunks
	if header(headers, "content-encoding").to_lower() == "gzip" and not body.is_empty():
		body = body.decompress_dynamic(body_size_limit, FileAccess.COMPRESSION_GZIP)
		if body.is_empty(): _fail(HTTPRequest.RESULT_BODY_DECOMPRESS_FAILED); return
	if status == HTTPClient.STATUS_CONNECTED and header(headers, "connection").to_lower() != "close":
		_connections[_job.key].used_at = Time.get_ticks_msec()
	else: _drop(str(_job.key))
	_complete(HTTPRequest.RESULT_SUCCESS, int(_job.code), headers, body)

func _fail(result: int, retryable: bool = false) -> void:
	_drop(str(_job.key))
	if retryable and _job.get("reused", false) and not _job.retried:
		_job.retried = true; _note("retried")
		_start(); return
	_complete(result)

func _drop(key: String) -> void:
	var entry: Dictionary = _connections.get(key, {})
	if entry.has("client"): (entry.client as HTTPClient).close()
	_connections.erase(key)

func _complete(result: int, code: int = 0, headers: PackedStringArray = PackedStringArray(), body: PackedByteArray = PackedByteArray()) -> void:
	var done: Callable = _job.done
	_job = {}
	# Deferred: replies reach the caller on the main thread, never inside its own request() call.
	done.call_deferred(result, code, headers, body)

func _note(name: String) -> void:
	if count.is_valid(): count.call_deferred("connections", name)

static func header(headers: PackedStringArray, key: String) -> String:
	for value: String in headers:
		if value.get_slice(":", 0).strip_edges().to_lower() == key: return value.substr(value.find(":") + 1).strip_edges()
	return ""
