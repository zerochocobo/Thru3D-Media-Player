# External scene and experience resources

This is a source release. Runtime code follows frozen 0.19.0 Release inputs. Full APK reproduction also needs separately supplied licensed assets, models, native dependencies and signing configuration.

## Wizard’s Attic

Scripts/shaders and tools/magic_cottage retain implementation and generation/packing code. Blender masters, packed meshes, textures and generated sounds are excluded. Build tools reuse separately supplied beach textures. Build output belongs in build/; modeling studies and design renders are not distributed. Supply matching licensed model/texture/material inputs before using the packer.

## Offline experience folder

builtin_experience.gd reads res://data/experience.dat as a ZIP containing catalog.json and its media/thumbnail files. Each files record supplies size and sha256. Items provide id, kind, localized title, file, thumbnail and optional experience; book editions provide locale and file. Build a compatible archive from your own licensed sample media. The product archive, media-source originals, generation prompts, photos, videos and sample books are excluded. Without a compatible archive the demo folder cannot be exercised as shipped. [Reading](BOOK_SOURCE.md) and regular media-source code remain public.

## Additional required paths excluded in 0.19.0

Earlier requirements in [MODELS.md](MODELS.md) still apply. Supply these payloads separately:

- `res://environments/magic_cottage/apparition_props.res`
- `res://environments/magic_cottage/coverlet.jpg`
- `res://environments/magic_cottage/flora/species-00.res`
- `res://environments/magic_cottage/flora/species-01.res`
- `res://environments/magic_cottage/flora/species-02.res`
- `res://environments/magic_cottage/flora/species-03.res`
- `res://environments/magic_cottage/flora/species-04.res`
- `res://environments/magic_cottage/flora/species-05.res`
- `res://environments/magic_cottage/flora/species-06.res`
- `res://environments/magic_cottage/flora/species-07.res`
- `res://environments/magic_cottage/flora/species-08.res`
- `res://environments/magic_cottage/flora/species-09.res`
- `res://environments/magic_cottage/ingredients.png`
- `res://environments/magic_cottage/sounds/attune.wav`
- `res://environments/magic_cottage/sounds/aurora.wav`
- `res://environments/magic_cottage/sounds/backward.wav`
- `res://environments/magic_cottage/sounds/bat_wing.wav`
- `res://environments/magic_cottage/sounds/brew_fail.wav`
- `res://environments/magic_cottage/sounds/bronze_bell.wav`
- `res://environments/magic_cottage/sounds/coffer.wav`
- `res://environments/magic_cottage/sounds/collapse.wav`
- `res://environments/magic_cottage/sounds/escaped.wav`
- `res://environments/magic_cottage/sounds/fire_air.wav`
- `res://environments/magic_cottage/sounds/fire_cast.wav`
- `res://environments/magic_cottage/sounds/fire_impact.wav`
- `res://environments/magic_cottage/sounds/forked_thunder.wav`
- `res://environments/magic_cottage/sounds/frost.wav`
- `res://environments/magic_cottage/sounds/gate_link.wav`
- `res://environments/magic_cottage/sounds/gate_open.wav`
- `res://environments/magic_cottage/sounds/ice_bloom.wav`
- `res://environments/magic_cottage/sounds/ingredient.wav`
- `res://environments/magic_cottage/sounds/ivy.wav`
- `res://environments/magic_cottage/sounds/koi_call.wav`
- `res://environments/magic_cottage/sounds/koi_swim.wav`
- `res://environments/magic_cottage/sounds/lanterns.wav`
- `res://environments/magic_cottage/sounds/meteors.wav`
- `res://environments/magic_cottage/sounds/moon_cast.wav`
- `res://environments/magic_cottage/sounds/moon_return.wav`
- `res://environments/magic_cottage/sounds/moths.wav`
- `res://environments/magic_cottage/sounds/page_vortex.wav`
- `res://environments/magic_cottage/sounds/pour.wav`
- `res://environments/magic_cottage/sounds/raven_wing.wav`
- `res://environments/magic_cottage/sounds/repelled.wav`
- `res://environments/magic_cottage/sounds/rose_bloom.wav`
- `res://environments/magic_cottage/sounds/scarab_wing.wav`
- `res://environments/magic_cottage/sounds/star_ink.wav`
- `res://environments/magic_cottage/sounds/ward_lost.wav`
- `res://environments/magic_cottage/sounds/ward_win.wav`
- `res://environments/magic_cottage/sounds/watcher.wav`
- `res://environments/magic_cottage/sounds/weightless.wav`
- `res://environments/magic_cottage/sounds/window_open.wav`
- `res://environments/magic_cottage/spell_surfaces.res`
- `res://environments/magic_cottage/star-atlas.jpg`
- `res://environments/magic_cottage/wall_ivy.res`
- `res://environments/magic_cottage/workshop.res`
- `res://data/experience.dat`

## 0.19.1 wand payloads

Supply `res://assets/wands/wands.res` and `res://assets/wands/wands.png` separately. Public tools/wands/build_wands.py and pack_wands.gd retain the generation/packing source; Blender masters, mesh libraries and the material atlas are excluded. Five small menu pictures are runtime UI previews, separate from the full model/texture payload.
