extends RefCounted
const Geometry := preload("res://scripts/puzzle/puzzle_geometry.gd")
const Sphere := preload("res://scripts/puzzle/puzzle_sphere.gd")
var thread: Thread
var mutex := Mutex.new()
var cancelled := false
var cpu_ms := 0.0

func start(job: Dictionary) -> bool:
	if thread!=null: return false
	cancelled=false; thread=Thread.new()
	if thread.start(_work.bind(job))!=OK: thread=null; return false
	return true

func _work(job: Dictionary) -> Dictionary:
	var began := Time.get_ticks_usec()
	var results: Array[Dictionary]=[]
	var grid: Vector2i=job.grid
	for y in grid.y:
		for x in grid.x:
			mutex.lock(); var stop := cancelled; mutex.unlock()
			if stop: return {}
			var geometry := Sphere.patch(Vector2i(x,y),grid,true,int(job.options.seed)) if job.get("projection","flat")=="sphere" else Geometry.flat(Vector2i(x,y),grid,job.size,job.options)
			if geometry.is_empty(): return {"error":"Invalid geometry"}
			results.append(geometry)
	return {"pieces":results,"cpu_ms":float(Time.get_ticks_usec()-began)/1000.0}

func poll() -> Dictionary:
	if thread==null or thread.is_alive(): return {}
	var result: Dictionary=thread.wait_to_finish(); thread=null
	cpu_ms=float(result.get("cpu_ms",0))
	return result

func shutdown() -> void:
	mutex.lock(); cancelled=true; mutex.unlock()
	if thread!=null: thread.wait_to_finish(); thread=null
