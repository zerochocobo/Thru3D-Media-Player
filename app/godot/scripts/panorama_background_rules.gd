extends RefCounted
## The import limits and the help text share these rules.
const MAX_BYTES := 256 * 1024 * 1024
const MAX_EDGE := 8192
const MAX_PIXELS := 32 * 1024 * 1024
const FORMAT := "Use a JPG, PNG or WebP panorama."
const FILE_SIZE := "Keep each background file within 256 MiB."
const DIMENSIONS := "Reduce this image to ≤8192 px per side and ≤33.5 MP before adding it."
const RATIO := "Use a full 360° panorama (2:1) or VR180 image (1:1)."
const CROP := "Use the complete panorama; cropped panoramas cannot be backgrounds."
const PROJECTION := "For panoramic images, switch to 360° or VR180 in the projection controls first."
const LAYOUT := "Match the projection and stereo layout to this panorama before setting a background."
const EXPORT := "Export this image as JPG, PNG or WebP, then reopen it."
const READ := "Could not read the image. Reopen it or choose another file."
const SAVE := "Could not save the background. Check free storage and try again."
const DECODE := "Could not decode the image. Re-export it as JPG, PNG or WebP."
const LOADING := "Wait for the image to finish loading."
const OPEN := "Open a panorama before setting a background."

static func size_issue(size: Vector2) -> String:
	return DIMENSIONS if size.x > MAX_EDGE or size.y > MAX_EDGE or size.x * size.y > MAX_PIXELS else ""

static func file_issue(bytes: int, header: Dictionary) -> String:
	if bytes > MAX_BYTES: return FILE_SIZE
	if bytes <= 0 or header.is_empty() or header.get("codec", "") not in ["jpg", "png", "webp"]: return FORMAT
	return size_issue(Vector2(header.width, header.height))

static func source_supported(size: Vector2, geometry: int, stereo: bool, top_bottom: bool) -> bool:
	if geometry not in [1, 3] or size.x <= 0 or size.y <= 0: return false
	var aspect := size.x / size.y
	var eye_aspect := aspect * (2.0 if top_bottom else 0.5) if stereo else aspect
	var wanted := 1.0 if geometry == 1 else 2.0
	return absf(eye_aspect - wanted) < 0.02 or (stereo and absf(aspect - wanted) < 0.02)
