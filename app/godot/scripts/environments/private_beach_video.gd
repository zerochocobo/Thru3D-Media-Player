extends RefCounted
## Mount the existing MPV surface on the physical beach screen. No decoder,
## frame lease or compositor layer is created here. Caller owns activation.
var picture_fraction := 0.0
var _video: Node3D
var _host: Node3D
var _saved := {}
var _front: MeshInstance3D
var _front_material: Material
var _matte: StandardMaterial3D
var _aspect_tried := 0.0

func sync(host: Node3D,video: Node3D,fraction := 1.0) -> bool:
	if not host or not host.is_ready or not video or not video.panel or video.geometry!=0:
		detach(); return false
	if _video!=video or _host!=host:
		detach(); _video=video; _host=host
		_saved={"screen_scale":video.screen_scale,"screen_curve":video.screen_curve,"screen_rotation":video.screen_rotation,
			"curve_radius":video.curve_radius,"screen_preset":video.screen_preset,"flat_pose":video.flat_pose,
			"cinema_enabled":video.cinema.enabled,"front_only":video._surface_front_only,
			"subtitle_ground_provider":video.subtitle_ground_provider}
	video.subtitle_ground_provider=Callable(host.navigation,"ground")
	var layout: Dictionary = host.screen_layout
	var base: Vector2 = video._screen_base
	# The whole panel is the picture: it takes the video's shape instead of framing it in black.
	var aspect := base.x/maxf(base.y,.001)
	if absf(aspect-float(layout.parameters.aspect))>.01 and not is_equal_approx(aspect,_aspect_tried) and not host.screen_loading:
		_aspect_tried=aspect
		host.request_screen({"aspect":aspect})
	var size: Vector2 = layout.half_size*2
	var scale := minf(size.x/maxf(base.x,.001),size.y/maxf(base.y,.001))*clampf(fraction,.1,1)
	video.cinema.enabled=false; video.screen_preset=""
	# The picture bends with the panel it lies on.
	var radius: float=float(layout.get("radius",0.0))
	var curve: float=rad_to_deg(size.x/radius) if radius>0.0 else 0.0
	if not is_equal_approx(video.screen_scale,scale) or not is_equal_approx(video.screen_curve,curve) or not is_equal_approx(video.curve_radius,radius) or video.screen_rotation!=0:
		video.screen_scale=scale; video.screen_curve=curve; video.curve_radius=radius; video.screen_rotation=0
		video._apply_geometry()
	var pose := Transform3D(Basis(layout.right,layout.up,layout.normal),layout.center+layout.normal*.035)
	if not (video.global_transform*video.flat_pose).is_equal_approx(pose): video.set_flat_world_pose(pose)
	video.set_surface_front_only(true)
	# The authored front remains as a black, depth-writing mat around letterbox
	# content. Its opaque back and supports remain separate physical geometry.
	if not is_instance_valid(_front):
		var fronts: Array = host._content.find_children("Screen_Front","MeshInstance3D",true,false)
		if not fronts.is_empty():
			_front=fronts[0]; _front_material=_front.material_override
			if not _matte:
				_matte=StandardMaterial3D.new(); _matte.shading_mode=BaseMaterial3D.SHADING_MODE_UNSHADED
				_matte.albedo_color=Color.BLACK; _matte.cull_mode=BaseMaterial3D.CULL_BACK
			_front.material_override=_matte
	picture_fraction=(base.x*base.y*scale*scale)/(size.x*size.y)
	return true

func detach(restore_pose := true) -> void:
	if is_instance_valid(_front): _front.material_override=_front_material
	_front=null; _front_material=null
	if is_instance_valid(_video) and not _saved.is_empty():
		_video.subtitle_ground_provider=_saved.subtitle_ground_provider
		if restore_pose:
			for key in ["screen_scale","screen_curve","screen_rotation","curve_radius","screen_preset","flat_pose"]:
				_video.set(key,_saved[key])
			_video.cinema.enabled=_saved.cinema_enabled
		_video.set_surface_front_only(_saved.front_only)
		_video._apply_geometry()
	_video=null; _host=null; _saved={}; picture_fraction=0
