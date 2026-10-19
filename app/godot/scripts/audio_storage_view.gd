extends RefCounted
const I18n := preload("res://scripts/i18n.gd")

static func size(bytes: int) -> String:
	if bytes < 1024: return "%d B" % maxi(0, bytes)
	if bytes < 1024 * 1024: return "%.0f KB" % (float(bytes) / 1024)
	if bytes < 1024 * 1024 * 1024: return "%.0f MB" % (float(bytes) / (1024 * 1024))
	return "%.1f GB" % (float(bytes) / (1024 * 1024 * 1024))

static func usage(state: Dictionary) -> String:
	return I18n.t("Music storage: %s") % size(int(state.get("audio_storage", {}).get("used_bytes", 0)))

static func device_space(state: Dictionary) -> String:
	var storage: Dictionary = state.get("audio_storage", {})
	if int(storage.get("total_bytes", 0)) <= 0: return ""
	return I18n.t("Device free: %s / %s") % [size(int(storage.get("free_bytes", 0))), size(int(storage.total_bytes))]

static func file_limit(state: Dictionary) -> String:
	var maximum := int(state.get("audio_storage", {}).get("max_file_bytes", 512 * 1024 * 1024))
	return I18n.t("File limit: %s") % size(maximum)

static func draw(menu: Node3D, state: Dictionary, point: Vector2, width: float, include_limit: bool = false, single_row: bool = false) -> Array[Label3D]:
	var labels: Array[Label3D] = []
	var one_row := include_limit and single_row
	var left_width := width * (0.27 if one_row else 0.39)
	var left: Label3D = menu._label(menu._fit_title(usage(state), "", left_width, 14), Vector3(point.x - width / 2, point.y, 0.008), 14)
	left.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT; left.modulate = menu.MUTED
	left.set_meta("music_text_width", left_width); labels.append(left)
	left.set_meta("audio_storage_field", "usage")
	var right_width := width * (0.43 if one_row else 0.60)
	var right: Label3D = menu._label(menu._fit_title(device_space(state), "", right_width, 14), Vector3(point.x + width / 2, point.y, 0.008), 14)
	right.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT; right.modulate = menu.MUTED
	right.set_meta("music_text_width", right_width); labels.append(right)
	right.set_meta("audio_storage_field", "space")
	if include_limit:
		var limit_width := width * 0.26 if one_row else width
		var limit_x := point.x - width / 2 + left_width + width * 0.02 + limit_width / 2 if one_row else point.x
		var limit: Label3D = menu._label(menu._fit_title(file_limit(state), "", limit_width, 14), Vector3(limit_x, point.y if one_row else point.y - 0.045, 0.008), 14)
		limit.set_meta("music_text_width", limit_width)
		limit.modulate = menu.MUTED; limit.set_meta("audio_storage_field", "limit"); labels.append(limit)
	return labels

static func update(menu: Node3D, labels: Array[Label3D], state: Dictionary) -> void:
	for label in labels:
		if not is_instance_valid(label): continue
		var text: String = {"usage": usage(state), "space": device_space(state), "limit": file_limit(state)}.get(label.get_meta("audio_storage_field"), "")
		label.text = menu._fit_title(text, "", float(label.get_meta("music_text_width", 1.20)), 14)
