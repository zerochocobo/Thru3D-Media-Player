# Offline release notes / 离线更新记录

The committed `app/godot/data/release_notes.json` snapshot provides four independent copies for every title and item: `zh`, `zh_Hant`, `en`, `ja`. It supports archived per-language notes and structured items with stable IDs. Versions use numeric segments, including four-part versions. Entries are capped at the installed version and filtered by headset/runtime/channel. Missing exact Release notes or translations fail packaging.

Validate locally with `python tools/check_release_notes.py app/godot/data/release_notes.json 0.18.8 --build-type Release` and `python tools/test_release_notes.py`. The export plugin and Build-Player also validate the bundled snapshot.

Structured entries contain version, date, four-language title and items. Each item has a unique lowercase ID, four-language text and optional scope. Omitted scope is shared; accepted values are quest, pico, openxr, pico_cn_store and qiyu. Scope matches by union; PICO China includes common, pico and pico_cn_store items. A machine without applicable entries skips that version.

Review titles and bodies for Quest, international PICO and PICO China, with the same item selection across all four languages. Keep hardware test limits and brand names consistent. Existing snapshots describe official release history; the public source has no configured scene-download origins or log-upload endpoint. Prepare new snapshots independently and commit them before packaging.

每条标题和正文分别填写简中、繁中、英文和日文；条目按安装版本、平台、渠道及运行时筛选，机型名称只说明测试范围。发布前校验精确版本与四套文本，并核对三个发行渠道的实际显示内容。公开源码使用独立维护文档，不包含内部网站维护流程。
