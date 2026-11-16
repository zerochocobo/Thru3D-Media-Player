extends "res://scripts/file_mode_memory.gd"
## Each folder of pictures keeps the atmosphere chosen in it. It is one of the per-file settings:
## the same privacy switch and the same "clear settings" action govern it.
const Catalog := preload("res://scripts/atmosphere/atmosphere_catalog.gd")

func _bank_path(bank: int) -> String:
	return directory.path_join("atmosphere_folders_%d.json" % bank)

func _value_field() -> String: return "atmosphere"

func _limit() -> int: return 256

## Off ("") is a choice worth remembering too.
func _valid_value(value: Variant) -> bool:
	if not value is Dictionary or value.size() != 1 or not value.get("theme") is String: return false
	return value.theme == "" or value.theme in Catalog.ids()

func _normalize_value(value: Dictionary) -> Dictionary:
	return {"theme": str(value.theme)}

## The folder a picture is in, as a URI the store can key; "" when it has none worth remembering
## (pages of an archive or a PDF, a bare document id).
static func folder_of(uri: String) -> String:
	if uri.is_empty() or uri.begins_with("archive-image://") or preload("res://scripts/pdf_pages.gd").container_page(uri): return ""
	var path := uri.get_slice("?", 0).get_slice("#", 0)
	var scheme := path.find("://")
	if scheme < 0: return ""
	# Android document ids carry their path percent-encoded behind the last real slash.
	var cut := maxi(path.rfind("/"), path.rfindn("%2f"))
	return path.substr(0, cut) if cut > scheme + 2 else ""
