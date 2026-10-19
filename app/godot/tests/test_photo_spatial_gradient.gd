extends SceneTree
const Geometry:=preload("res://scripts/photo_spatial_geometry.gd")
var checks:=0
var worst:=0.0
var failures: Array[String]=[]
func _initialize() -> void:
	var executable:=OS.get_environment("THRU3D_PHOTO_GRADIENT_PROBE")
	if executable.is_empty(): push_error("Run through Test-PhotoSpatial.ps1 to compile the native parity oracle"); quit(1); return
	var folder:=ProjectSettings.globalize_path("res://../../build/output/photo-spatial/gradient")
	DirAccess.make_dir_recursive_absolute(folder)
	for dims in [Vector2i(518,518),Vector2i(252,140)]:
		var w: int=dims.x; var h: int=dims.y
		var rect:=Vector4(.10,.15,.75,.7)
		var data:=PackedFloat32Array(); data.resize(w*h)
		for y in h:
			for x in w: data[y*w+x]=clampf(sin(x*.27)*cos(y*.21)*.48+.5,0,1)
		var source:=Image.create_from_data(w,h,false,Image.FORMAT_RF,data.to_byte_array())
		for half in [Vector2(0,0),Vector2(9.065,0),Vector2(18.13,7.5),Vector2(85,120)]:
			FileAccess.open(folder.path_join("input.bin"),FileAccess.WRITE).store_buffer(data.to_byte_array())
			var args:=PackedStringArray([folder.path_join("input.bin"),folder.path_join("native.bin"),str(w),str(h),
				str(roundi(rect.x*w)),str(roundi(rect.y*h)),str(roundi(rect.z*w)),str(roundi(rect.w*h)),str(half.x),str(half.y)])
			if OS.execute(executable,args)!=0: failures.append("Native oracle did not complete"); continue
			var expected:=FileAccess.get_file_as_bytes(folder.path_join("native.bin")).to_float32_array()
			var actual:=Geometry.limit_gradient(source,rect,half.x,half.y).get_data().to_float32_array()
			var difference:=0.0
			for i in actual.size(): difference=maxf(difference,absf(actual[i]-expected[i]))
			worst=maxf(worst,difference); checks+=1
			if difference>0.000002: failures.append("Native/Godot gradient mismatch: %s %s %f"%[dims,half,difference])
	FileAccess.open(folder.path_join("result.json"),FileAccess.WRITE).store_string(JSON.stringify({"checks":checks,"failures":failures,"max_abs_error":worst}))
	for message in failures: push_error(message)
	print("Photo spatial gradient parity: %d checks, %d failures, max error %.9f"%[checks,failures.size(),worst])
	quit(0 if failures.is_empty() else 1)
