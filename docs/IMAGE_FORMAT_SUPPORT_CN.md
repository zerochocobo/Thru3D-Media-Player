# 图片格式与解码范围

0.16.1 新增静态／动态 AVIF、APNG、GIF、动态 WebP，以及兼容的 DNG、CR2、CR3、NEF、NRW、ARW、RAF、RW2、ORF、PEF、SRW 相机 RAW。具体相机、容器变体、嵌入预览和输入预算会影响支持情况，后缀识别不等于所有文件都可解码。

动图按帧计时和循环信息显示，暂停后可使用兼容的静态图片特效；恢复播放时退出相关静态效果。解码采用有界帧队列，切图／关闭取消旧结果。高位深、宽色域及 HDR 输入转换为 RGBA8 sRGB 显示，不是原样 HDR 输出。

动画输出最长边 2048，静态输出最长边 8192。RAW 超出处理预算时可采用可用的内嵌预览；不支持或损坏输入应报错并允许继续浏览。libavif 的共享颜色／透明瓦片等部分变体仍有限制。桌面编辑器不包含 Android JNI 解码器，桌面界面检查不能替代头显格式／性能验收。

原始许可证、固定源码归档、大小及 SHA-256 见 `third_party/image/`，生产实现见 `native/image/`。[英文格式说明](IMAGE_FORMATS.md)列出构建工具与范围。

可选测试资源通过 `tools/media/Prepare-ImageFixtures.py --destination <目录>` 准备；原创图形生成器默认写入 `build/output/image-fixtures/`。资源来源目录是元数据，公开源码不包含个人照片、测试媒体载荷、模型权重或设备记录。运行 `tools/Test-ImageFormats.py` 时显式指定 `--fixtures <目录>`。准备及验证输出均应保留在可删除的构建目录中。
