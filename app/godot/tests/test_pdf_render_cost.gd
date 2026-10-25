extends SceneTree
const Photo := preload("res://scripts/photo_display.gd")
const Magazine := preload("res://scripts/photo_magazine.gd")
var failures: Array[String] = []
var checks := 0

class Host extends RefCounted:
	func prepare_photo_3d(_id: int, _strength: float) -> bool: return true

func check(value: bool, label: String) -> void:
	checks += 1
	if not value: failures.append(label)

func _initialize() -> void: run.call_deferred()

func run() -> void:
	var folder := ProjectSettings.globalize_path("res://../../build/output/pdf-render-cost")
	DirAccess.make_dir_recursive_absolute(folder)
	var left := Image.create(320, 480, false, Image.FORMAT_RGBA8); left.fill(Color.WHITE)
	left.fill_rect(Rect2i(20, 20, 280, 200), Color.DARK_RED)
	var right := Image.create(320, 480, false, Image.FORMAT_RGBA8); right.fill(Color.WHITE)
	right.fill_rect(Rect2i(20, 20, 280, 200), Color.DARK_BLUE)
	var source := folder.path_join("source.png"); right.save_png(source)
	var photo := Photo.new(); root.add_child(photo); photo.set_process(false); photo.platform = Host.new()
	photo.queue.assign([{"uri":"pdfpage://fixture/0"}, {"uri":"pdfpage://fixture/1"}])
	photo.magazine.first = {"image":left, "info":{}}
	var job := {"index":0}; photo.magazine.decorate(job)
	check(str(job.magazine_path).ends_with(".jpg"), "PDF spread chooses fast JPEG handoff")
	photo.queue[0].uri = "comic://fixture/0"
	var archive_job := {"index":0}; photo.magazine.decorate(archive_job)
	check(str(archive_job.magazine_path).ends_with(".png"), "Other image containers keep existing lossless handoff")
	job.merge({"info":{"path":source}, "skip_thumbnail":true}, true)
	var decoded := Photo._decode(job)
	check(not decoded.has("error") and decoded.get("magazine", false), "Production decoder composes PDF spread")
	var bytes := FileAccess.get_file_as_bytes(job.magazine_path)
	check(bytes.size() > 2 and bytes[0] == 255 and bytes[1] == 216, "Native handoff contains actual JPEG bytes")
	var registered := Image.new()
	check(registered.load_jpg_from_buffer(bytes) == OK and registered.get_size() == Vector2i(640,480), "Native handoff keeps full spread dimensions")
	check(registered.get_pixel(10,300).r > .98 and registered.get_pixel(400,80).b > .4, "White page background and page ordering survive JPEG")
	check(not decoded.has("thumbnail") and decoded.image.get_size() == Vector2i(640,480), "No directory thumbnail or display resolution reduction")
	check(decoded.has("spread_encode_ms") and decoded.has("decode_ms"), "Separate encoding and decode timings are available")
	photo.magazine.cleanup_job(job); photo.queue_free(); await process_frame

	# Desktop CPU evidence only, using synthetic textured pages, never a PDF/Quest speed claim.
	var noise := FastNoiseLite.new(); noise.seed = 20261024; noise.frequency = 0.035
	var page := noise.get_image(2048,3072); page.convert(Image.FORMAT_RGBA8)
	for y in range(0,3072,256): page.fill_rect(Rect2i(0,y,2048,16),Color.WHITE)
	var spread := Magazine.compose(page.duplicate(),page.duplicate(),false)
	var report := {"environment":"Godot desktop synthetic image encoding; not Quest or PDF rendering", "samples":[]}
	for item in [{"name":"page", "image":page},{"name":"spread", "image":spread}]:
		for codec in ["png","jpg"]:
			var path := folder.path_join(str(item.name)+"."+codec)
			var started := Time.get_ticks_usec()
			var result: int = item.image.save_png(path) if codec=="png" else item.image.save_jpg(path,0.98)
			var elapsed := (Time.get_ticks_usec()-started)/1000.0
			check(result==OK,"Synthetic encoder succeeds: "+item.name+" "+codec)
			report.samples.append({"kind":item.name,"codec":codec,"width":item.image.get_width(),"height":item.image.get_height(),"encode_ms":elapsed,"bytes":FileAccess.get_file_as_bytes(path).size()})
	FileAccess.open(folder.path_join("report.json"),FileAccess.WRITE).store_string(JSON.stringify(report,"\t"))
	print(JSON.stringify(report))
	for failure in failures: push_error(failure)
	print("PDF encoding: %d checks, %d failures" % [checks,failures.size()])
	quit(0 if failures.is_empty() else 1)
