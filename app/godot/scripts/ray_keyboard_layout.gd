extends RefCounted
## Shared layout from the existing account/login keyboard. Callers own actions and focus.
const I18n := preload("res://scripts/i18n.gd")

static func draw(menu: Node, base: int, key: int, enabled: bool, shift: bool, symbols: bool, offset: Vector2) -> void:
	var layer: Array = menu.SYMBOLS if symbols else menu.KEYS
	for row in 4:
		for col in 10:
			var value: String = layer[row][col]
			menu._button(key + row * 10 + col, value.to_upper() if shift else value, Vector2(-0.40 + col * 0.125, -0.10 - row * 0.071) + offset, Vector2(0.114, 0.061), enabled)
	for spec in [[1,"⇧",-0.36,0.16],[2,"#+=" if not symbols else "abc",-0.16,0.2],[3,"␣",0.15,0.36],[4,"⌫",0.46,0.2],[5,I18n.t("Paste"),0.7,0.22]]:
		menu._button(base + int(spec[0]), str(spec[1]), Vector2(float(spec[2]), -0.405) + offset, Vector2(float(spec[3]), 0.073), enabled, "", (spec[0] == 1 and shift) or (spec[0] == 2 and symbols))
