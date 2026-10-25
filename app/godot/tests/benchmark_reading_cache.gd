extends SceneTree
const Photo := preload("res://scripts/photo_display.gd")
const Cache := preload("res://scripts/reading_render_cache.gd")
var folder := ProjectSettings.globalize_path("res://../../build/output/reading-cost")
var samples: Array = []

func _initialize() -> void: run.call_deferred()

func run() -> void:
	DirAccess.make_dir_recursive_absolute(folder)
	var noise := FastNoiseLite.new(); noise.seed = 20261025; noise.frequency = .035
	var source := noise.get_image(2048,3072); source.convert(Image.FORMAT_RGB8)
	for y in range(0,3072,192): source.fill_rect(Rect2i(0,y,2048,12),Color.WHITE)
	var large := folder.path_join("page-3072.jpg"); source.save_jpg(large,.98)
	source.resize(1024,1536); var small := folder.path_join("page-1536.jpg"); source.save_jpg(small,.98); source = null
	for spec in [["single_1536",small,false,""],["single_3072",large,false,""],
		["double_3072_png",large,true,"png"],["double_3072_jpg",large,true,"jpg"]]:
		for repeat in 3:
			var start := Time.get_ticks_usec()
			var job := {"info":{"path":spec[1]},"prefetch":true,"reading":true,"skip_thumbnail":true}
			if spec[2]: job["magazine_first"] = Photo._decode(job); job["magazine_path"] = folder.path_join("spread."+spec[3])
			var result := Photo._decode(job)
			assert(result.has("image"))
			var decode_ms := (Time.get_ticks_usec()-start)/1000.0
			job.clear() # Decoder inputs are not retained by a finished entry.
			var width: int = result.image.get_width(); var height: int = result.image.get_height()
			var uploads: Array = []
			for item in [[result,"proxy","ready_texture"]]:
				start = Time.get_ticks_usec()
				var texture := ImageTexture.create_from_image(item[0][item[1]])
				var enqueue_ms := (Time.get_ticks_usec()-start)/1000.0
				var readback := texture.get_image()
				assert(readback.get_size() == item[0][item[1]].get_size())
				uploads.append({"kind":item[2],"enqueue_ms":enqueue_ms,"upload_and_readback_ms":(Time.get_ticks_usec()-start)/1000.0})
				item[0][item[2]] = texture
			var two_d := Cache.memory({"result":result},{})
			samples.append({"case":spec[0],"iteration":repeat,"width":width,"height":height,
				"decode_and_join_ms":decode_ms,"spread_encode_ms":result.spread_encode_ms,
				"neighbor_2d_bytes":two_d,"color_image_bytes":result.image.get_data_size(),
				"source_bytes":FileAccess.get_file_as_bytes(str(spec[1])).size(),
				"spread_file_bytes":FileAccess.get_file_as_bytes(folder.path_join("spread."+spec[3])).size() if spec[2] else 0,
				"uploads":uploads})
			await process_frame
	var report := {"scope":"Desktop synthetic production decoder and actual GL texture upload/readback. Colour/file-only production policy. No neighbouring 3D allocation or inference. No Android PDF rendering, archive IO or headset frame time measurement.","samples":samples}
	FileAccess.open(folder.path_join("report.json"),FileAccess.WRITE).store_string(JSON.stringify(report,"\t"))
	print("Reading cost benchmark passed: %d samples" % samples.size())
	quit()
