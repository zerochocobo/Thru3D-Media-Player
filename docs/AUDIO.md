# Audio resources

The global music player, offline imports and playlists are included in source. The twelve built-in recordings, original downloads and private provenance archive are excluded. Release notes describe the application release; a source checkout does not contain its built-in audio.

`app/godot/assets/audio/catalog.json` contains only the twelve expected filenames, sizes and SHA256 values. To reproduce that catalog, obtain appropriately licensed version-matched Ogg files separately and run:

```powershell
./tools/Import-AudioAssets.ps1 -FromDirectory /path/to/your/licensed-audio
./tools/Import-AudioAssets.ps1 -VerifyOnly
```

The helper verifies every input before copying. It does not download assets, grant recording rights or install narration models. Imported audio remains ignored by Git. Run Godot's normal import after supplying the files. Without them, built-in catalog entries cannot play; users can still import their own supported audio through the app. No hosted download of the generated music is supplied here.

The built-in decoding paths in `test_background_audio.gd` and `test_audio_native_transport.gd` require those files. Generated UI fixtures do not establish that the excluded recordings were supplied or tested. Source licensing and recording licensing are separate; see [licensing scope](LICENSING.md).

## 简体中文

公开版包含全局音乐播放器、离线导入与歌单源码，不包含十二段内置录音、原始下载或私有素材归档。更新日志描述应用发布功能，源码检出不自带内置音频。目录元数据只含文件名、大小及哈希。

要复现内置曲目，请自行取得有权使用的匹配 Ogg 文件，运行上述导入命令，再执行 Godot 正常资源导入。工具先核对全部文件再复制，不下载素材、不授予录音权利，也不安装朗读模型；导入后的文件继续被 Git 忽略。缺少这些资源时内置曲目无法播放，应用仍支持导入自己的兼容音频。内置解码相关测试同样需要匹配资源。
