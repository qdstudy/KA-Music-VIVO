# KA Music · VIVO 原子随身听兼容版

以 **上游 `umr-xiaomai/kgka_Music_hl` v3.3.0** 为基线，叠加 vivo OriginOS
「原子随身听」(MusicWidgetMix) 支持。

设计目标：**上游每次发版只需要 `git merge`，不需要重新解决冲突。**

## 与上游的差异（全部）

| 类型 | 路径 | 说明 |
|---|---|---|
| 修改 | `pubspec.yaml` | `audio_service` 改为 `path: packages/audio_service`（3 行） |
| 修改 | `lib/main.dart` | builder 换成 `VivoMusicAudioHandler` + 一行 `VivoBridge.bind(...)` + 两行监听（4 行） |
| 新增 | `packages/audio_service/` | 内联 fork 的 audio_service 0.18.19 |
| 新增 | `lib/vivo/vivo_audio_handler.dart` | vivo 协议层（继承上游 handler） |
| 新增 | `lib/vivo/vivo_bridge.dart` | 依赖注入 + 扩展方法 |
| 新增 | `.github/workflows/vivo-upstream-release.yml` | 跟随上游自动构建发布 |
| 新增 | `.github/workflows/build-smoke.yml` | 手动构建验证（不发布） |

除上表外，**所有文件都与上游完全一致**，包括 `AndroidManifest.xml`、
`music_audio_handler.dart`、`auth_controller.dart`、`player_controller.dart`。
`git diff upstream/master..vivo` 应该只剩 2 个文件 + 新增文件。

## 三处原生补丁（都在 `packages/audio_service` 内）

1. `AudioService.java` — `onBind()` 把 vivo 的私有 action
   `com.vivo.musicwidgetmix.support.service` 翻译成标准
   `android.media.browse.MediaBrowserService`。
   → 因此 **App 模块不再需要 `VivoAudioService` 子类**。
2. `AudioService.java` — `mediaSession.setRatingType(RATING_HEART)`，让卡片显示红心。
3. `AudioService.java` — `onLoadChildren("vivomusicmix_current_list")` 由原生
   `MediaSession` 队列同步分页返回，避免 Flutter isolate 尚未就绪时卡片永久空白。

厂商声明（`support_vivo_musicwidgetmix_*` 三条 meta-data + vendor intent-filter）
写在 **插件自己的** `packages/audio_service/android/src/main/AndroidManifest.xml`，
构建时由 manifest merger 合并进 App，App 的 Manifest 保持上游原样。

## 关键约束

- **包名必须是 `com.apple.android.music`**：vivo 的 `support_vivo_musicwidgetmix_token`
  是按包名下发的，换成别的 applicationId 元数据即失效、卡片不出现。
  构建时通过 `--android-project-arg=customPackageName=com.apple.android.music` 指定。
  副作用：不能与 Android 版 Apple Music 同时安装。
- 只出 `arm64-v8a`。

## 本地验证

```bash
flutter pub get
flutter analyze --no-fatal-infos --no-fatal-warnings
flutter test
flutter build apk --release --target-platform android-arm64 \
  --android-project-arg=customPackageName=com.apple.android.music
```

## 跟随上游发版

`.github/workflows/vivo-upstream-release.yml` 每天 03:17 UTC 检查上游最新 release：

1. 已有同名 `vivo-v<tag>` release 且未强制 → 跳过；
2. `git merge` 上游 tag，**冲突时打印冲突文件并 `::error::` 后退出**（不再静默 `exit 1`）；
3. 校验 `packages/audio_service` 的版本与上游约束是否漂移；
4. `pub get` + `test` + 构建；
5. **构建成功后**才 push 合并结果，再发布 release。

需要的仓库配置：

| 项 | 值 |
|---|---|
| Settings → Actions → General → Workflow permissions | **Read and write permissions** |
| Secret `VIVO_KEYSTORE_BASE64` | keystore 的 base64 |
| Secret `VIVO_STORE_PASSWORD` / `VIVO_KEY_ALIAS` / `VIVO_KEY_PASSWORD` | 签名信息 |
| Variable `SYNC_PAUSED` | 设为 `true` 可暂停自动同步 |

## 已知取舍

- `setVivoLoopMode` 走 `cyclePlaybackMode()`，最多调用两次到达目标模式；
  不修改 `player_controller.dart`，代价是随机播放历史会按上游逻辑重置。
- 收藏列表分页复用 `MusicApi.playlistSongs`，未登录时返回空列表。
- `about_page.dart` 保持上游文案（含上游仓库链接），如需强调 VIVO 版本
  可在该页改一行，或只改仓库 About 描述。
