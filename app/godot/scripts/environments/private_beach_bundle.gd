extends Resource
## Imported resource graph: export follows these dependencies, not loose JSON.
@export var schema_version := 2
@export var scene_id := "private_beach"
@export var config: Dictionary = {}
@export var navigation: Dictionary = {}
@export var layout: Dictionary = {}
@export var mask_tiles: Array = []
@export var terrain: PackedScene
@export var props: PackedScene
@export var vegetation: PackedScene
@export var grill: PackedScene
@export var textures: Dictionary = {}
@export var sand_surface: Dictionary = {}
@export var study: Dictionary = {}
## Authored ETC2 mip chains that keep leaf coverage; the importer would rebuild them.
@export var canopy_images: Dictionary = {}
@export var firework_streams: Array = []
@export var cloud_width := 0
@export var cloud_height := 0
@export var cloud_data := PackedByteArray()

func validate() -> String:
	if schema_version != 2 or scene_id != "private_beach": return "Unsupported beach bundle"
	if not terrain or not props or not vegetation or not grill: return "Beach geometry unavailable"
	for key in ["micro_color","micro_normal","macro_color","wood_color","rock_color","rock_normal","rock_arm","static_mask","cliff_color","cliff_normal","sand_surface","wave_slopes","vegetation_contact","grill_contact","cloud_coverage","moon_albedo","groundcover_color","groundcover_normal","near_leaf_color","near_leaf_alpha","near_leaf_normal"]:
		if not textures.get(key) is Texture2D: return "Beach texture unavailable: "+key
	for kind in ["color","alpha","normal"]:
		if not canopy_images.get(kind) is Image: return "Beach canopy unavailable: "+kind
	if firework_streams.size()<4: return "Beach firework audio unavailable"
	for stream in firework_streams:
		if not stream is AudioStream: return "Beach firework audio unavailable"
	if cloud_width<=0 or cloud_data.size()!=cloud_width*cloud_height: return "Invalid beach cloud coverage"
	for key in ["wave_slope_range","groundcover_tile","vegetation_contact_rect","grill_contact_rect","grill_shadow_center","grill_palette","firework_launch_heights"]:
		if not study.has(key): return "Beach study data missing: "+key
	var launch_heights: Variant=study.firework_launch_heights
	if not launch_heights is Array or launch_heights.size()!=2: return "Invalid beach launch sites"
	for height in launch_heights:
		if not (height is float or height is int) or not is_finite(float(height)): return "Invalid beach launch height"
	var sand_bounds: Array=sand_surface.get("bounds_xz_size",[])
	if sand_bounds.size()!=4 or float(sand_surface.get("slope_range",0))<=0: return "Invalid sand surface mapping"
	if float(sand_surface.get("compaction_range",0))<=0: return "Invalid sand compaction encoding"
	for value in sand_bounds:
		if not is_finite(float(value)): return "Invalid sand surface bounds"
	if float(sand_bounds[2])<=0 or float(sand_bounds[3])<=0: return "Invalid sand surface extent"
	if layout.get("effective_config",{}) != config: return "Beach layout differs from configuration"
	if not config.get("shore") is Dictionary: return "Invalid beach shore"
	var coast: Array = config.shore.get("points",[])
	if coast.size()<2 or coast.size()>32: return "Invalid beach shore"
	for i in range(coast.size()):
		if not coast[i] is Array or coast[i].size()!=2: return "Invalid beach shore point"
		if i>0 and float(coast[i][0])<=float(coast[i-1][0]): return "Unordered beach shore"
	if not config.get("perimeter") is Dictionary or float(config.perimeter.get("rock_tile_metres",0))<=0: return "Invalid beach perimeter"
	if not config.get("screen") is Dictionary or not config.get("walk") is Dictionary: return "Invalid beach layout"
	if mask_tiles.size()<4 or mask_tiles.size()>6: return "Invalid beach mask atlas"
	var grid: Dictionary = navigation.get("grid",{})
	if int(grid.get("nx",0))<2 or int(grid.get("nz",0))<2 or float(grid.get("step",0))<=0: return "Invalid beach height field"
	if grid.get("heights",[]).size()!=int(grid.nx)*int(grid.nz): return "Beach height field is incomplete"
	return ""
