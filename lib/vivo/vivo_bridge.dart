import '../controllers/auth_controller.dart';
import '../controllers/download_controller.dart';
import '../controllers/player_controller.dart';
import '../models/music_models.dart';
import '../services/music_api.dart';

/// vivo 原子随身听（OriginOS MusicWidgetMix）的全局依赖注册表。
///
/// vivo 相关代码全部集中在 `lib/vivo/` 与 `packages/audio_service/` 两处，
/// 上游文件只保留一行 [bind] 接线，因此跟随上游发版升级时几乎不会产生
/// Git 冲突。
class VivoBridge {
  VivoBridge._();

  static PlayerController? player;
  static AuthController? auth;
  static DownloadController? downloads;
  static MusicApi? api;

  static bool get isReady => player != null && auth != null;

  /// 在 [main] 的控制器创建完成后调用一次。
  static void bind({
    required PlayerController player,
    required AuthController auth,
    required DownloadController downloads,
    required MusicApi api,
  }) {
    VivoBridge.player = player;
    VivoBridge.auth = auth;
    VivoBridge.downloads = downloads;
    VivoBridge.api = api;
  }

  static bool isLiked(Song song) => auth?.isLiked(song) ?? false;

  /// vivo 的循环模式取值：1 列表循环、2 单曲循环、3 随机。
  static int get loopMode => player?.vivoLoopMode ?? 1;

  static void setLoopMode(int mode) => player?.setVivoLoopMode(mode);
}

/// vivo 循环模式与 [PlaybackMode] 之间的映射。
///
/// 内部复用 [PlayerController.cyclePlaybackMode]，因此状态落盘、随机播放历史
/// 重置和 UI 通知都沿用上游逻辑，不需要修改 `player_controller.dart`。
extension VivoPlaybackMode on PlayerController {
  int get vivoLoopMode => switch (playbackMode) {
    PlaybackMode.playlistLoop => 1,
    PlaybackMode.singleLoop => 2,
    PlaybackMode.shuffle => 3,
  };

  void setVivoLoopMode(int mode) {
    final target = switch (mode) {
      2 => PlaybackMode.singleLoop,
      3 => PlaybackMode.shuffle,
      _ => PlaybackMode.playlistLoop,
    };
    // cyclePlaybackMode 每次只前进一格，最多两次即可到达目标模式。
    for (var i = 0; i < 3 && playbackMode != target; i++) {
      cyclePlaybackMode();
    }
  }
}

/// 「喜欢」相关能力。
///
/// 上游 3.3 已把 `setLiked` 重构为 [AuthController.toggleLike]，这里基于公开
/// API 重新实现，因此上游继续改动收藏逻辑也不会让 vivo 侧编译失败。
extension VivoLibrary on AuthController {
  /// 幂等地把歌曲设置为喜欢 / 取消喜欢。
  Future<void> setLiked(Song song, bool shouldLike) async {
    if (isLiked(song) != shouldLike) {
      await toggleLike(song);
    }
  }

  /// vivo 收藏列表分页（page 从 0 开始）。
  Future<List<Song>> likedSongsPage(int page, int pageSize) async {
    final playlist = likedPlaylist;
    final client = VivoBridge.api;
    if (playlist == null || client == null) return const [];
    try {
      return await client.playlistSongs(
        playlist.id,
        page: page + 1,
        pageSize: pageSize,
      );
    } catch (_) {
      // 未登录或网络异常时返回空列表，避免 vivo 卡片卡在加载态。
      return const [];
    }
  }
}
