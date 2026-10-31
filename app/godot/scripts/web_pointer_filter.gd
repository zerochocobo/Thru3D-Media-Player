extends RefCounted
## Filter the webpage's local position once; its reticle and native events consume the same result.
var point := Vector2.ZERO
var at := -1
var previous_raw := Vector2.ZERO
var velocity := Vector2.ZERO
func reset() -> void: at = -1
func sample(raw: Vector2, time_us: int) -> Vector2:
	if not raw.is_finite(): reset(); return raw
	if at < 0 or time_us - at > 150000 or raw.distance_to(point) > 0.15:
		point = raw; previous_raw = raw; velocity = Vector2.ZERO; at = time_us; return point
	if time_us <= at: return point
	var dt := clampf(float(time_us - at) / 1000000.0, 0.001, 0.05)
	# A slow resting tip has a short damping window; deliberate movement rapidly releases it.
	velocity = velocity.lerp((raw - previous_raw) / dt, 1.0 - exp(-TAU * 3.0 * dt))
	previous_raw = raw
	var speed := velocity.length()
	var cutoff := lerpf(7.0, 45.0, clampf(speed / 0.25, 0.0, 1.0))
	point = point.lerp(raw, 1.0 - exp(-TAU * cutoff * dt)); at = time_us
	return point
