# Apple Music 封面缺失与串图修复

## 实际复现

用户反馈 Apple Music 当前没有封面。直接读取同一播放状态时，《看看》/莫文蔚/《不散,不見》正在播放，Music 的 AppleScript 返回 artworks 数量 0，data 为 0 字节，读取 artwork 出错。系统当前媒体源同时属于视频应用，因此不能把系统媒体封面直接补到音乐槽位。

另一个确认的缺陷是 MediaRemote 切歌差量未带封面时，原 reducer 会继续携带前一首 artwork。MusicManager 的异步解码也仅检查数据相等，没有完整的请求世代约束；无法解码时没有补取路径。

## 修改

- AppleMusicController 将整次读取绑定到一个 track，返回 persistent ID 并在读取后核对，优先读取原始封面格式。空字符串不再视为有效图片数据。
- PlaybackState 保存歌曲标识；歌曲标识、歌名、歌手或专辑改变时丢弃旧封面和旧目录 ID，播放进度/暂停更新保留同曲封面。
- MusicManager 切换歌曲立即撤下旧图，所有异步解码、目录补取和重试都受请求世代与取消状态约束。同曲已成功的封面不会因暂时缺失而隐藏；重复进度更新不重新请求。
- Apple Music 缺失或损坏封面时查询 Apple 目录。已知 catalog ID 时按 ID；否则要求简繁与标点规范化后的歌名、歌手、专辑全匹配，时长相差不超过 3 秒，并且封面 URL 无歧义。不以搜索排名猜测封面。
- 请求仅在缺图时发生。网络错误有限重试，换曲取消；明确刷新可在重试用尽后重新请求。图片解码在线程池执行；旧图平均色回调也不能覆盖新图颜色。

目录使用项目已有的 iTunes API 域名，另向 Apple 图片 CDN 请求对应图片。参考 [Apple 搜索结果字段](https://developer.apple.com/library/archive/documentation/AudioVideo/Conceptual/iTuneSearchAPI/UnderstandingSearchResults.html)。补取使用目录提供的图片尺寸，不假设高分辨率地址规则。

## 验证

- `python3 scripts/check-album-artwork.py`：生产管理器封面路径抽取执行；真实图片解码、严格目录匹配、错误歌手/专辑/现场版/时长拒绝、HTTP 失败、A/B 请求乱序、同专辑切歌、重复状态、源切换、失败恢复、同曲临时缺图、MediaRemote 差量。
- `python3 scripts/check-album-artwork.py --live`：读取真实 Apple Music，不改变播放；《勇敢》/张惠妹/《勇敢》原始封面 0 字节，新路径取得可解码的 88×100 图片。
- 原有音乐来源、空闲状态、专注媒体路由测试通过；构建和单实例启动通过后供用户查看。

## 边界

新目录补取只针对 Apple Music；其他播放器使用原封面读取方式，共享更严格的请求隔离。离线、目录无结果或匹配不唯一时不补入猜测封面。未人工逐曲核对整个资料库，也未完成长时间资源占用测试。
