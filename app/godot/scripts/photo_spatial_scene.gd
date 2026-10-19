extends Node3D
const Geometry := preload("res://scripts/photo_spatial_geometry.gd")
const SHADER := preload("res://shaders/photo_spatial.gdshader")
var worker: Thread
var epoch := 0
var pending := {}
var prepared := false
var error := ""
var report := {}
var reference := Vector3(0,0,3)
var reference_size := Vector2.ONE
var coverage := 0.0
var surfaces: Array[MeshInstance3D] = []
signal completed

func begin(source: Image, depth: Image, rect: Vector4, eye: Vector3, size: Vector2, native_pair: bool,
	strength: float = 1.0, fill_enabled: bool = true, eye_separation: float = 0.064) -> void:
	clear()
	pending={"epoch":epoch,"source":source,"depth":depth,"rect":rect,"eye":eye,"size":size,"native":native_pair,
		"strength":strength,"fill":fill_enabled,"eye_separation":eye_separation}
	set_process(true)

func clear() -> void:
	epoch+=1; pending={}; prepared=false; error=""; report={}; visible=false; coverage=0.0
	for surface in surfaces: surface.queue_free()
	surfaces.clear()

func _process(_delta: float) -> void:
	if worker and not worker.is_alive():
		var result: Dictionary=worker.wait_to_finish(); worker=null
		if int(result.get("epoch",-1))==epoch:
			if result.get("data",{}).is_empty(): error="Spatial view unavailable"
			else: _accept(result.data)
			completed.emit()
	if worker==null and not pending.is_empty():
		var job:=pending; pending={}; worker=Thread.new()
		if worker.start(_prepare.bind(job),Thread.PRIORITY_LOW)!=OK:
			worker=null; error="Spatial view unavailable"; completed.emit()
	if worker==null and pending.is_empty(): set_process(false)

static func _prepare(job: Dictionary) -> Dictionary:
	return {"epoch":job.epoch,"data":Geometry.prepare(job.source,job.depth,job.rect,job.eye,job.size,job.native,job.strength,job.fill,job.eye_separation)}

func _accept(data: Dictionary) -> void:
	reference=data.reference; reference_size=data.size
	var arrays:=[]; arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX]=data.vertices; arrays[Mesh.ARRAY_TEX_UV]=data.uv
	var front:=ArrayMesh.new(); front.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays)
	_surface(front,data.color,-8)
	report={"triangles":data.triangles,"texture_bytes":data.texture_bytes,"source_eye":"left" if data.native_pair else "converted_2d",
		"max_texture_edge":Geometry.MAX_EDGE,"strength":data.strength,"fill_strategy":"photo_limit_gradient_xy" if data.fill else "disabled_diagnostic",
		"gradient_half_cells":str(data.gradient_half_cells),"background_layers":0,"parallax_gain":data.span,
		"relief_limit_m":data.relief_limit_m,"depth_scale":"display_short_edge_reference_distance","boundary":"fixed_portal","head_motion_fallback":false}
	prepared=true

func _surface(mesh: Mesh, picture: Image, order: int) -> void:
	var surface:=MeshInstance3D.new(); surface.mesh=mesh
	var mat:=ShaderMaterial.new(); mat.shader=SHADER
	mat.render_priority=order
	mat.set_shader_parameter("image_texture",ImageTexture.create_from_image(picture))
	mat.set_shader_parameter("portal_size",reference_size)
	mat.set_shader_parameter("reference_eye",reference)
	surface.material_override=mat; add_child(surface); surfaces.append(surface)

func sync(pose: Transform3D, size: Vector2, _eye: Vector3, base_order: int = -10) -> void:
	# Explicit photo resizing scales relief too. The calibration reference stays fixed;
	# current head distance must never make scene depth breathe or snap back.
	var depth_scale:=Geometry.relief_limit(reference,size)/Geometry.relief_limit(reference,reference_size)
	var display_scale:=Vector3(size.x/reference_size.x,size.y/reference_size.y,depth_scale)
	transform=pose.scaled_local(display_scale)
	# The scene has one world anchor. Head movement only changes the real camera projection;
	# never cross-fade to an incompatible stereo plane, rescale, or recenter on a head threshold.
	coverage=1.0 if prepared else 0.0
	visible=prepared
	for index in surfaces.size():
		var surface:=surfaces[index]
		surface.material_override.set_shader_parameter("display_scale",display_scale)
		surface.material_override.render_priority=clampi(base_order+(2 if index==0 else 1),-126,127)

func _exit_tree() -> void:
	if worker: worker.wait_to_finish(); worker=null
