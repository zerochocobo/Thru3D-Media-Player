# Offline Simplified Chinese pinyin data

Upstream: https://github.com/rime/rime-pinyin-simp

Pinned commit: `0c6861ef7420ee780270ca6d993d18d4101049d0`.
`pinyin_simp.dict.yaml` SHA-256 (upstream LF bytes):
`e341598343a0f0f2035bb1aafc34a7f3bb7887deeecb3f60796262aaa2983e6b`.

The upstream AUTHORS identifies the dictionary as derived from Android Pinyin IME,
under Apache License 2.0. The original dictionary, AUTHORS and LICENSE are retained
here. No ChinaWander/Hanzi Bird mixed-source dictionary is distributed by this feature.

Thru3D modifications: `tools/Build-ChineseLexicon.py` normalizes syllable separators,
orders candidates by source weights, adds the small application vocabulary explicitly
listed in `app/godot/input/pinyin_overrides.json`, and emits a sorted key table, little
endian offsets and UTF-8 candidate blocks. Generated files and their checksums are in
`app/godot/input/`. Run the builder with `--check` to verify reproducibility.

The keyboard/composition UI is app code. This feature does not embed librime or an
Android system input-method service, download dictionaries, or learn from user text.
