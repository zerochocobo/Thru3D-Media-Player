extends RefCounted
## Folder priority never reverses. Missing metadata stays last in either direction.
const ORDERS := ["name_asc", "name_desc", "modified_desc", "modified_asc", "size_desc", "size_asc", "source"]
const LABELS := ["Name · A–Z", "Name · Z–A", "Modified · newest", "Modified · oldest", "Size · largest", "Size · smallest", "Source order"]

static func normalize(value: Variant) -> String:
	return str(value) if str(value) in ORDERS else "name_asc"

static func compare_names(a: String, b: String) -> int:
	var natural := a.naturalnocasecmp_to(b)
	# Case/zero-padding equivalents must not depend on a provider's opaque file IDs.
	return natural if natural != 0 else (0 if a == b else (-1 if a < b else 1))

static func preserves_order(previous: Array, incoming: Array) -> bool:
	var positions := {}
	for index in incoming.size(): positions[str(incoming[index].uri)] = index
	var last := -1
	for entry in previous:
		var index := int(positions.get(str(entry.uri), -1))
		if index < 0: continue
		if index <= last: return false
		last = index
	return true

static func before(a: Dictionary, b: Dictionary, order: String) -> bool:
	var folder_a := a.has("container")
	var folder_b := b.has("container")
	if folder_a != folder_b: return folder_a
	var field := order.get_slice("_", 0)
	if field == "modified" or (field == "size" and not folder_a):
		var av := int(a.get(field, -1))
		var bv := int(b.get(field, -1))
		if (av < 0) != (bv < 0): return bv < 0
		if av != bv: return av > bv if order.ends_with("desc") else av < bv
	var comparison := compare_names(str(a.title), str(b.title))
	if comparison != 0: return comparison > 0 if field == "name" and order.ends_with("desc") else comparison < 0
	return str(a.get("uri", a.get("container", {}).get("id", ""))) < str(b.get("uri", b.get("container", {}).get("id", "")))
