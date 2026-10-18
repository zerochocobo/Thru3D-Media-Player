extends Node3D
## Fixed world-space bursts; one small instanced mesh, no lights or physics bodies.
const BURSTS := 3
const SPARKS := 40
const TAILS := 3
const STARTS := [0.0,0.28,0.56]
const ASCENT := 0.38
const LIFETIME := 1.45
const DURATION := 2.5
var audio: Node3D
var elapsed := 0.0
var mesh: MultiMeshInstance3D
var velocities: Array[Vector3]=[]
var centres := [Vector3(-0.6,0.62,-1.85),Vector3(0.6,0.75,-1.85),Vector3(0,0.92,-1.95)]
var colours := [Color(1.0,0.75,0.36),Color(0.4,0.95,0.85),Color(1.0,0.56,0.68)]
var launched := [false,false,false]
var exploded := [false,false,false]
var sphere_centre: Variant=null
var particle_positions := PackedVector3Array()
var particle_alpha := PackedFloat32Array()

func configure(head: Transform3D, sound: Node3D = null, sphere_origin: Variant = null, frame: Variant = null, frame_size: Vector2 = Vector2.ZERO) -> void:
	audio=sound
	global_transform=Transform3D(head.basis.orthonormalized(),head.origin)
	if frame is Transform3D:
		global_transform=Transform3D(frame.basis.orthonormalized(),frame.origin)
		var half := frame_size*0.5
		centres=[Vector3(-half.x*0.8,half.y+0.20,0.16),Vector3(half.x*0.8,half.y+0.28,0.16),Vector3(0,half.y+0.44,0.18)]
	sphere_centre=to_local(sphere_origin) if sphere_origin is Vector3 else null
	mesh=MultiMeshInstance3D.new(); mesh.multimesh=MultiMesh.new()
	mesh.multimesh.transform_format=MultiMesh.TRANSFORM_3D; mesh.multimesh.use_colors=true
	var spark := CapsuleMesh.new(); spark.radius=0.0055; spark.height=0.045; spark.radial_segments=6; spark.rings=1
	var ink := StandardMaterial3D.new(); ink.shading_mode=BaseMaterial3D.SHADING_MODE_UNSHADED
	ink.vertex_color_use_as_albedo=true; ink.transparency=BaseMaterial3D.TRANSPARENCY_ALPHA
	ink.no_depth_test=false; spark.material=ink; mesh.multimesh.mesh=spark
	mesh.multimesh.instance_count=BURSTS*SPARKS*TAILS; mesh.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF; add_child(mesh)
	particle_positions.resize(mesh.multimesh.instance_count); particle_alpha.resize(mesh.multimesh.instance_count)
	var rng := RandomNumberGenerator.new(); rng.seed=92017
	for i in BURSTS*SPARKS:
		var direction := Vector3(rng.randfn(),rng.randfn(),rng.randfn()).normalized()
		velocities.append(direction*rng.randf_range(0.48,0.9))
	sample(0.0)

func _process(delta: float) -> void:
	elapsed+=delta; sample(elapsed)
	if elapsed>=DURATION: queue_free()

func sample(time: float) -> void:
	if mesh==null: return
	for burst in BURSTS:
		var age := time-float(STARTS[burst]); var centre: Vector3=centres[burst]
		if age>=0 and not launched[burst]:
			launched[burst]=true
			if is_instance_valid(audio): audio.play("launch",to_global(centre-Vector3.UP*0.6))
		if age>=ASCENT and not exploded[burst]:
			exploded[burst]=true
			if is_instance_valid(audio): audio.play("burst",to_global(centre))
		for spark in SPARKS:
			for tail in TAILS:
				var index := (burst*SPARKS+spark)*TAILS+tail
				var point := centre; var alpha := 0.0; var size := 1.0; var heading := Vector3.UP
				if age>=0 and age<ASCENT and spark==0:
					point=centre-Vector3.UP*(0.6*(1.0-age/ASCENT)+tail*0.045); alpha=1.0-float(tail)*0.28; size=1.2
				elif age>=ASCENT:
					var life := age-ASCENT-tail*0.035
					if life>=0 and life<LIFETIME:
						point=centre+velocities[burst*SPARKS+spark]*life+Vector3.DOWN*0.32*life*life
						heading=(velocities[burst*SPARKS+spark]+Vector3.DOWN*0.64*life).normalized()
						alpha=pow(1.0-life/LIFETIME,1.5)*(1.0-float(tail)*0.28); size=0.75+0.35*alpha
				if sphere_centre is Vector3:
					var offset: Vector3=point-sphere_centre
					if offset.length()>2.25: point=sphere_centre+offset.normalized()*2.25
				var colour: Color=colours[burst]; colour.a=alpha
				particle_positions[index]=point; particle_alpha[index]=alpha
				var axis := Vector3.FORWARD.cross(heading)
				if axis.length_squared()<0.001: axis=Vector3.RIGHT.cross(heading)
				axis=axis.normalized()
				var orientation := Basis(axis,heading,axis.cross(heading)).scaled(Vector3.ONE*(size if alpha>0 else 0.001))
				mesh.multimesh.set_instance_transform(index,Transform3D(orientation,point))
				mesh.multimesh.set_instance_color(index,colour)
