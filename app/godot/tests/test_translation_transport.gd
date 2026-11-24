extends SceneTree
## Keep-alive translation transport against a local HTTP/1.1 server.
const Transport := preload("res://scripts/translation_transport.gd")
var checks := 0
var failures := []
var server := TCPServer.new()
var peers := []
var accepted := 0
var requests := []
var mode := "keep"
var results := []
var counts := {}

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message); push_error(message)

func _initialize() -> void: run.call_deferred()

func serve() -> void:
	while server.is_connection_available():
		peers.append({"peer": server.take_connection(), "data": PackedByteArray()}); accepted += 1
	for entry: Dictionary in peers:
		var peer: StreamPeerTCP = entry.peer
		peer.poll()
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED: continue
		var available := peer.get_available_bytes()
		if available > 0:
			var data: PackedByteArray = entry.data
			data.append_array(peer.get_data(available)[1]); entry.data = data
		var text: String = (entry.data as PackedByteArray).get_string_from_ascii()
		var end := text.find("\r\n\r\n")
		if end < 0: continue
		var length := 0
		for line in text.left(end).split("\r\n"):
			if line.to_lower().begins_with("content-length:"): length = line.get_slice(":", 1).strip_edges().to_int()
		if (entry.data as PackedByteArray).size() < end + 4 + length: continue
		requests.append({"head": text.left(end), "body": text.substr(end + 4, length)})
		entry.data = (entry.data as PackedByteArray).slice(end + 4 + length)
		if mode == "silent": continue
		var body := "ok".to_utf8_buffer()
		var extra := ""
		if mode == "gzip":
			body = "compressed reply".to_utf8_buffer().compress(FileAccess.COMPRESSION_GZIP); extra = "Content-Encoding: gzip\r\n"
		peer.put_data(("HTTP/1.1 200 OK\r\nContent-Length: %d\r\n%sConnection: keep-alive\r\n\r\n" % [body.size(), extra]).to_ascii_buffer())
		peer.put_data(body)
		if mode == "close": peer.disconnect_from_host()

func ask(transport: Node, path: String, body: String = "") -> void:
	var before := results.size()
	var url := "http://127.0.0.1:%d%s" % [server.get_local_port(), path]
	transport.request(url, PackedStringArray(["User-Agent: test"]), HTTPClient.METHOD_POST, body,
		func(result, code, _headers, reply): results.append([result, code, (reply as PackedByteArray).get_string_from_utf8()]))
	for i in 600:
		serve()
		await process_frame
		if results.size() > before: return

func run() -> void:
	check(server.listen(0, "127.0.0.1") == OK, "Local test server listens")
	var transport := Transport.new(); root.add_child(transport)
	transport.count = func(_group, name): counts[name] = int(counts.get(name, 0)) + 1
	await ask(transport, "/translate?to=zh-Hans", "[\"hello\"]")
	check(results.back() == [HTTPRequest.RESULT_SUCCESS, 200, "ok"], "First request succeeds")
	check(requests.back().head.begins_with("POST /translate?to=zh-Hans HTTP/1.1") and requests.back().body == "[\"hello\"]", "Path, query and body are sent as given")
	check("accept-encoding: gzip" in requests.back().head.to_lower() and "content-length: 9" in requests.back().head.to_lower(), "Body length and gzip acceptance are declared")
	await ask(transport, "/again", "x")
	check(results.back()[0] == HTTPRequest.RESULT_SUCCESS and accepted == 1 and counts.get("reused", 0) == 1, "A second request reuses the connection")
	mode = "gzip"; await ask(transport, "/gzip")
	check(results.back() == [HTTPRequest.RESULT_SUCCESS, 200, "compressed reply"] and accepted == 1, "Gzip replies are decompressed on the same connection")
	mode = "close"; await ask(transport, "/close")
	mode = "keep"
	for i in 10:
		serve(); await process_frame
	await ask(transport, "/after-close")
	check(results.back()[0] == HTTPRequest.RESULT_SUCCESS and accepted == 2, "A connection the server closed is replaced")
	transport._connections[transport._connections.keys()[0]].used_at = Time.get_ticks_msec() - transport.IDLE_MS
	await ask(transport, "/idle")
	check(results.back()[0] == HTTPRequest.RESULT_SUCCESS and accepted == 3, "An idle connection is not reused")
	mode = "silent"; transport.timeout = 0.3
	await ask(transport, "/silent")
	check(results.back()[0] == HTTPRequest.RESULT_TIMEOUT and transport._connections.is_empty(), "A silent server times out and its connection is dropped")
	transport.timeout = 5.0; var count := results.size()
	transport.request("http://127.0.0.1:%d/cancel" % server.get_local_port(), PackedStringArray(), HTTPClient.METHOD_GET, "", func(_a, _b, _c, _d): results.append("late"))
	for i in 5:
		serve(); await process_frame
	transport.cancel(); mode = "keep"
	for i in 20:
		serve(); await process_frame
	check(results.size() == count and not transport.busy(), "A cancelled request never calls back")
	check(transport.request("ftp://example.com/", PackedStringArray(), HTTPClient.METHOD_GET, "", func(_a, _b, _c, _d): pass) == ERR_INVALID_PARAMETER, "Only HTTP and HTTPS are accepted")
	check(Transport.header(PackedStringArray(["Content-Encoding: GZIP"]), "content-encoding") == "GZIP", "Header lookup ignores name case")
	transport.free(); server.stop()
	print("Translation transport: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
