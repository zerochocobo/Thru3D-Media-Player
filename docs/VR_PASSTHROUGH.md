# Temporary immersive-video passthrough

0.16.3 can suspend an eligible immersive-video presentation into a small paused stereo globe while the environment is visible. The exit control follows the head; short transitions restore the original view and previous play/pause state. The original media projection and saved preferences are preserved. Unsupported presentation states fail or return through the existing path rather than inventing a captured frame. It is not live background playback, a permanent spatial anchor or a new video format.

沉浸视频临时透视仅使用本次会话的暂停双眼预览；随头退出后恢复原视图和播放状态，不更改片源投影／保存设置，不代表持续后台播放或任意组合均兼容。

From0.16.7 the paused globe samples a single source eye for both eyes, reducing conflicting stereo cues in the miniature preview. Original stereo playback is restored on exit. 从0.16.7起，临时球体为双眼显示同一源眼画面，退出后恢复原立体播放；此前双眼预览描述仅对应历史实现。
