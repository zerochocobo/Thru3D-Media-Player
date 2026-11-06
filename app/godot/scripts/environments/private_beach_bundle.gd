extends Resource
## Imported resource graph: export follows these dependencies, not loose JSON.
@export var schema_version := 1
@export var scene_id := "private_beach"
@export var config: Dictionary = {}
@export var navigation: Dictionary = {}
@export var layout: Dictionary = {}
@export var mask_tiles: Array = []
@export var terrain: PackedScene
@export var props: PackedScene
@export var textures: Dictionary = {}
@export var sand_surface: Dictionary = {}

func validate() -> String:
	if schema_version != 1 or scene_id != "private_beach": return "Unsupported beach bundle"
	if not terrain or not props: return "Beach geometry unavailable"
	for key in ["micro_color","micro_normal","macro_color","wood_color","rock_color","rock_normal","rock_arm","static_mask","cliff_color","cliff_normal","day_sky","day_reflection","sand_surface"]:
		if not textures.get(key) is Texture2D: return "Beach texture unavailable: "+key
	var sand_bounds: Array=sand_surface.get("bounds_xz_size",[])
	if sand_bounds.size()!=4 or float(sand_surface.get("slope_range",0))<=0: return "Invalid sand surface mapping"
	if float(sand_surface.get("compaction_range",0))<=0: return "Invalid sand compaction encoding"
	for value in sand_bounds:
		if not is_finite(float(value)): return "Invalid sand surface bounds"
	if float(sand_bounds[2])<=0 or float(sand_bounds[3])<=0: return "Invalid sand surface extent"
	if layout.get("effective_config",{}) != config: return "Beach layout differs from configuration"
	if not config.get("shore") is Dictionary: return "Invalid beach shore"
	var coast: Array = config.shore.get("points",[])
	if coast.size()<2 or coast.size()>16: return "Invalid beach shore"
	for i in range(coast.size()):
		if not coast[i] is Array or coast[i].size()!=2: return "Invalid beach shore point"
		if i>0 and float(coast[i][0])<=float(coast[i-1][0]): return "Unordered beach shore"
	if not config.get("perimeter") is Dictionary or float(config.perimeter.get("rock_tile_metres",0))<=0: return "Invalid beach perimeter"
	if not config.get("screen") is Dictionary or not config.get("walk") is Dictionary: return "Invalid beach layout"
	if mask_tiles.size()!=4: return "Invalid beach mask atlas"
	var grid: Dictionary = navigation.get("grid",{})
	if int(grid.get("nx",0))<2 or int(grid.get("nz",0))<2 or float(grid.get("step",0))<=0: return "Invalid beach height field"
	if grid.get("heights",[]).size()!=int(grid.nx)*int(grid.nz): return "Beach height field is incomplete"
	return ""
