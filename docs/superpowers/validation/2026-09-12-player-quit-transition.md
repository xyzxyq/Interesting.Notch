# 播放器退出衔接

复现：网易云退出菜单（Command+Q 对应操作）后，MediaRemote stream 最终返回 diff=false、payload={}；旧逻辑把它当作暂停，立即清空歌名、歌词和时钟，但等待 waitInterval 后才移除音乐布局。

修改：
- MusicManager 将无播放来源单独处理：取消暂停倒计时和歌词请求，立即进入空闲，保留退场视图需要的歌词、封面和最后播放位置。
- NowPlayingController 订阅 NSWorkspace 应用退出通知，系统未及时发出空状态时也结束当前来源。
- 已退出应用的迟到消息被忽略；检测到应用已重新运行后允许新的播放状态。
- 正常暂停仍沿用原有等待时间。

验证：完整 Debug build、稳定签名、安装校验通过，安装进程 65303；MultiPlayerLyricsChecks 新增退出冻结状态与空 payload 检查，通过；MusicIdleChecks 通过。

实机：网易云 3.1.9 播放《美丽的泡沫》，MediaRemote playing=true。退出前截图有燃油、日间图标和右侧波纹；执行退出菜单后，确认网易云进程消失，最终截图只保留燃油和火箭，无残留音乐布局。未逐帧测量动画 FPS。
