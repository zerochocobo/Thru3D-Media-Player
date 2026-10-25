extends SceneTree
## Explicit, bounded network probe with self-authored text only. Never part of test_*.gd.
const Fixtures := preload("res://tests/test_comic_translation.gd")
class ProbeTranslator extends "res://scripts/comic_translation.gd":
	var stages := []
	var errors := []
	var translation_responses := []
	func _reply(result: int, code: int, headers: PackedStringArray, body: PackedByteArray, stamp: int, stage: String) -> void:
		if stage in ["bing", "edge"]:
			translation_responses.append({"stage":stage,"result":result,"http_status":code,"data":JSON.parse_string(body.get_string_from_utf8())})
		super._reply(result,code,headers,body,stamp,stage)
	func _send(stage: String, url: String, headers: PackedStringArray, method: HTTPClient.Method, body: String = "") -> void:
		stages.append(stage)
		super._send(stage,url,headers,method,body)
	func _failure(stage: String, code: int, headers: PackedStringArray) -> void:
		errors.append({"stage":stage,"status":code})
		super._failure(stage,code,headers)
func _initialize() -> void: run.call_deferred()
func run() -> void:
	var photo := Fixtures.FakePhoto.new(); root.add_child(photo)
	var client := ProbeTranslator.new(photo); client.enabled = true; client.target = "zh-Hans"
	var texts := ["待って！まだ話は終わってない！", "勘違いするな。お前を助けに来たわけじゃない。", "まさか……あいつが？", "ここで逃げたら、あいつに顔向けできない。", "アオイ先輩、約束は明日の放課後ですよね？", "ドキドキ……なんで急に顔が熱くなるの？", "へえ、ずいぶん立派な言い訳だな。", "嫌いじゃない。でも、今は答えられない。"]
	var blocks := []
	for i in texts.size(): blocks.append(Fixtures.block(i,texts[i]))
	var observations := []; var ok := true
	for engine in ["Bing", "Edge"]:
		client.reset(true); client.stages.clear(); client.errors.clear(); client.translation_responses.clear()
		if engine == "Edge": client._cooldown.Bing = Time.get_ticks_msec() + 60000
		client.observe([{"page":0,"page_size":[200,200],"blocks":blocks}], [Rect2(0,0,1,1)], 1)
		var start := Time.get_ticks_msec()
		while Time.get_ticks_msec() - start < 45000:
			client.tick(true)
			if client.state in ["ready","error","partial"]: break
			await create_timer(.02).timeout
		var passed: bool = client.translated_count() == 8 and client.provider == engine
		ok = ok and passed
		var row := {"engine":engine,"passed":passed,"elapsed_ms":Time.get_ticks_msec()-start,"count":client.translated_count(),"stages":client.stages.duplicate(),"errors":client.errors.duplicate(),"outputs":client.cache.values().duplicate(true)}
		row["translation_responses"] = client.translation_responses.duplicate(true)
		observations.append(row); print(JSON.stringify(row))
		if not passed: break
	var output := ProjectSettings.globalize_path("res://../../build/output/comic-translation-20261025")
	DirAccess.make_dir_recursive_absolute(output)
	var file := FileAccess.open(output.path_join("godot-network.json"),FileAccess.WRITE)
	file.store_string(JSON.stringify(observations,"  ")); file.close()
	client.close(); photo.free(); quit(0 if ok else 1)
