# Appearance palettes

Six presets retain stable IDs: Obsidian black(default), Pearl, Warm sand, Jade mist, Deep ocean and Dusk violet. Custom background/accent/text seeds generate a complete palette; preview, apply and cancel are separate actions, and saved custom choices can be selected again. This colors app chrome/vector glyphs, not source media, subtitle samples, provider artwork or personal pictures. Classic values remain available; light palettes retain readable text, outlined swatches and neutral grayscale detail in the footer logo. Device brightness/comfort still need hardware assessment.

Palette preferences live in private app settings. No user palette export, account, history or screenshot is bundled with source. Glass/translucent menu research is not implemented by this change. The theme editor and color-picker shader are app source, not model assets.

Run `tools/Test-UiThemes.ps1` with an explicit Godot executable for host checks. Optional historical pixel comparisons require `-BaselineRef` naming a suitable local pre-theme Git revision; private development commits are not present in this repository. `ui_theme_check.py` can capture selected fixtures into build/output and records failures separately. Required source media or generated cinema assets must be prepared independently; a capture that reports zero failed assertions before the process crashes is not a clean pass.

六套预设及自定义颜色只调整应用界面；个人偏好不随源码分发。浅色文字、图标与底栏Logo分别处理，保留经典配色与媒体／字幕原色。宿主渲染不能代表所有头显上的亮度、舒适度或完整功能验收。
