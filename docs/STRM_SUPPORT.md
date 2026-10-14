# STRM 支持

STRM 是媒体地址的纯文本索引。媒体库按原来的文件名显示，点击播放时读取目标地址；不会在扫描目录时下载视频。实现参考 [Emby STRM 文档](https://emby.media/support/articles/Strm-Files.html) 与 [Kodi STRM 文档](https://kodi.wiki/view/Internet_video_and_audio_streams)。

## 使用

将 `电影.SBS.strm` 放在头显本地存储、SMB 共享或已连接的网盘/WebDAV 目录中，像普通视频一样点击播放。系统文件选择器也可选择 STRM。首次使用本地目录仍需原有的文件访问授权。

文件内只填写一个媒体地址。例如下面每个代码块分别对应一个 STRM 文件：

```text
https://media.example.com/video.mkv?token=example
```

```text
smb://192.168.1.10/Movies/video.mkv
```

```text
\\NAS\Movies\video.mkv
```

```text
/storage/emulated/0/Movies/video.mkv
```

```text
../Movies/video.mkv
```

支持 UTF-8（可带 BOM）和带 BOM 的 UTF-16，兼容 Windows 换行，忽略空行及以 `#` 开头的注释。单文件上限 64 KiB，最多解析四层 STRM，循环引用会报错。

HTTP/HTTPS 地址可带签名参数，可指向 MP4/MKV、HLS 等现有播放器支持的媒体，包括没有文件扩展名的下载接口。HTTP STRM 文件可经过重定向，相对目标按最终 STRM 地址解析；不会把原地址的查询参数或网盘账号凭据自动附加到目标。

SMB 目标使用媒体库中已保存的服务器连接及授权；先添加与目标地址匹配的 SMB 服务器。如果同一地址有多套账号，优先使用当前 STRM 所在连接，否则需要消除歧义。服务器以 IP 添加时，STRM 也应使用该 IP；这里不自动猜测主机别名。

相对路径按 STRM 所在目录解析。本地路径对应头显文件系统；SMB 相对路径不能跳出共享，网盘相对路径不能跳出当前账号挂载。SMB/网盘文件内以 `/` 开头的路径对应共享/挂载根目录。Android 文件选择器返回的 `content://` 文档通常无法确定同级目录，应在其中填写完整地址。

文件名中的现有 SBS、TB、180° 等模式标记仍可识别。历史、断点、画面设置和字幕选择以 STRM 原文件为索引，不使用会过期的目标 URL。与 STRM 同名、放在其目录里的字幕和配音继续按现有规则加载。重命名或删除操作针对索引文件及现有同名伴随文件规则，不追踪删除目标媒体。

## 错误提示与范围

格式错误、无法读取或无法播放时自动显示播放信息页及简短原因。区分空文件、多地址、编码错误、过大文件、无效地址、不支持的协议、Windows 盘符、缺少 SMB 连接、循环引用、STRM 读取超时、HTTP 授权/文件不存在及目标无法访问。原生播放器的加载和格式错误转换成可读提示；等待首帧超过 60 秒且没有继续读入媒体数据时，报超时并关闭该播放请求。实际读取进展会延长期限。错误页自动换行，不显示带凭据的完整 URL。

STRM 不会将网盘分享网页转换成视频直链，也不会自动登录未配置的网盘账号。目标必须能被头显及现有播放器访问。`D:\Movies\video.mkv` 这样的电脑盘符不能直接在 Android 头显上使用，应改成 SMB/HTTP 地址。

本次不实现 Kodi 的 `plugin://`、`URL|Header=...` 附加请求头、任意脚本协议、多地址播放列表或自动生成 STRM。地址过期需更新文件内容；STRM 本身不提供网盘直链刷新凭据。Emby/Jellyfin 媒体库里的 STRM 由服务器先解析；应用支持 PlaybackInfo 返回的远程 HTTP/HTTPS 原文件及 RequiredHttpHeaders，独立读取上游且不转发已保存的服务器 token。远程文件须支持 Range；没有新增 Plex 客户端。

所有远程媒体（含 DLNA、普通视频及图片）的打开阶段、等待时间、读取速度、通用播放错误及完整菜单恢复见 [网络媒体加载反馈](MEDIA_LOADING.md)。


STRM在共享Android播放插件中实现。主机解析或打包检查不等同于头显视听及长期性能验收。
