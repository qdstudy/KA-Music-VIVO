import 'package:audio_service/audio_service.dart';

import '../models/music_models.dart';
import '../services/music_audio_handler.dart';
import 'vivo_bridge.dart';

/// 在 3.3 基线的 [MusicAudioHandler] 之上叠加 vivo 原子随身听协议。
///
/// 这里只覆写协议相关的方法，播放重试、进度归属、歌词字段等逻辑全部继承
/// 上游实现，因此上游的功能更新会自动生效，不需要同步维护。
class VivoMusicAudioHandler extends MusicAudioHandler {
  VivoMusicAudioHandler() {
    // MediaSession 侧的 RATING_HEART 已固定在 packages/audio_service 内，
    // 这里同步 Dart 侧的 ratingStyle，供插件回传原生前做校验。
    ratingStyle.add(RatingStyle.heart);
  }

  /// vivo MusicWidgetMix EventType 位掩码：
  /// 0x01f 传输/歌词/进度、0x020 上一首/下一首/播放暂停控制、
  /// 0x040 红心、0x080 播放模式、0x100 当前队列、0x200 收藏、0x400 已下载。
  static const int supportEvents = 0x7ff;

  static const String _supportEventKey =
      'vivomusicmix.media.metadata.support_event';
  static const String _loopModeKey = 'vivomusicmix.media.metadata.LOOP_MODE';
  static const String _playModeAction = 'vivomusicmix.media.action.PLAY_MODE';
  static const String _pageKey = 'vivomusicmix_key_media_page';
  static const String _hasMoreKey = 'vivomusicmix_key_has_more';
  static const int _pageSize = 50;

  List<Song> _queueSongs = const [];
  Song? _currentSong;
  Duration? _resolvedDuration;

  /// mediaId -> Song，用于把 vivo 传回来的 id 还原成可播放的歌曲。
  final Map<String, Song> _songsById = {};

  /// 收藏 / 下载列表的分页结果，供 playFromMediaId 播放整张列表。
  final Map<String, List<Song>> _browseQueues = {};

  int? _lastLoopMode;
  bool? _lastLiked;
  String? _lastSongId;

  @override
  Future<void> loadSong({
    required Song song,
    required String url,
    required List<Song> queueSongs,
    required int queueIndex,
  }) async {
    _currentSong = song;
    _resolvedDuration = null;
    _queueSongs = List<Song>.of(queueSongs);
    _remember(queueSongs);
    _remember([song]);

    await super.loadSong(
      song: song,
      url: url,
      queueSongs: queueSongs,
      queueIndex: queueIndex,
    );

    // just_audio 在准备音源后才拿到真实时长，部分接口不返回 duration，
    // 补一次给外部浏览器（含 vivo 卡片）用于渲染进度与拖动。
    final resolved = audioPlayer.duration;
    if ((song.duration == null || song.duration == Duration.zero) &&
        resolved != null &&
        resolved > Duration.zero) {
      _resolvedDuration = resolved;
    }
    refreshVivoMetadata(force: true);
  }

  @override
  Future<void> setSongQueue({
    required List<Song> queueSongs,
    required int queueIndex,
    Song? currentSong,
  }) async {
    if (currentSong != null) _currentSong = currentSong;
    _queueSongs = List<Song>.of(queueSongs);
    _remember(queueSongs);
    if (currentSong != null) _remember([currentSong]);

    await super.setSongQueue(
      queueSongs: queueSongs,
      queueIndex: queueIndex,
      currentSong: currentSong,
    );
    refreshVivoMetadata(force: true);
  }

  @override
  void updateLyricMetadata({
    String? lyricText,
    String? translationText,
    String? romanizationText,
    String? fullLyricLrc,
  }) {
    super.updateLyricMetadata(
      lyricText: lyricText,
      translationText: translationText,
      romanizationText: romanizationText,
      fullLyricLrc: fullLyricLrc,
    );
    // 上游刚发布的 MediaItem 里没有 vivo 字段，这里原地补一次。
    _publishCurrent();
  }

  @override
  Future<List<MediaItem>> getChildren(
    String parentMediaId, [
    Map<String, dynamic>? options,
  ]) async {
    final page = (options?[_pageKey] as num?)?.toInt() ?? 0;
    final List<Song> songs;
    switch (parentMediaId) {
      case 'vivomusicmix_current_list':
        // 正常情况下由 packages/audio_service 在原生侧同步返回（isolate 未就绪
        // 时也能出列表），这里只是兜底。
        songs = _queueSongs
            .skip(page * _pageSize)
            .take(_pageSize)
            .toList(growable: false);
      case 'vivomusicmix_favorite_list':
        songs =
            await VivoBridge.auth?.likedSongsPage(page, _pageSize) ??
            const <Song>[];
      case 'vivomusicmix_local_list':
        songs = (VivoBridge.downloads?.downloadedSongs ?? const <Song>[])
            .skip(page * _pageSize)
            .take(_pageSize)
            .toList(growable: false);
      default:
        return super.getChildren(parentMediaId, options);
    }

    _remember(songs);
    for (final song in songs) {
      _browseQueues[_songId(song)] = songs;
    }

    final items = <MediaItem>[];
    for (var i = 0; i < songs.length; i++) {
      final isLast = i == songs.length - 1;
      items.add(
        _decorate(
          _mediaItemForSong(songs[i]),
          song: songs[i],
          page: isLast ? page + 1 : null,
          hasMore: isLast ? songs.length == _pageSize : null,
        ),
      );
    }
    return items;
  }

  @override
  Future<void> playFromMediaId(
    String mediaId, [
    Map<String, dynamic>? extras,
  ]) async {
    final player = VivoBridge.player;
    if (player == null) return;

    for (final song in _queueSongs) {
      if (_songId(song) == mediaId) {
        await player.playSong(song, queue: _queueSongs);
        return;
      }
    }

    final browseQueue = _browseQueues[mediaId];
    if (browseQueue == null) return;
    for (final song in browseQueue) {
      if (_songId(song) == mediaId) {
        await player.playSong(song, queue: browseQueue);
        return;
      }
    }
  }

  @override
  Future<void> setRating(
    Rating rating, [
    Map<String, dynamic>? extras,
  ]) async {
    if (rating.getRatingStyle() != RatingStyle.heart) return;
    final auth = VivoBridge.auth;
    if (auth == null) return;

    final song = _currentSong ?? _songFor(mediaItem.value?.id);
    if (song == null) return;

    final shouldLike = rating.hasHeart();
    if (auth.isLiked(song) != shouldLike) {
      await auth.toggleLike(song);
    }
    refreshVivoMetadata(force: true);
  }

  @override
  Future<dynamic> customAction(
    String name, [
    Map<String, dynamic>? extras,
  ]) async {
    if (name == _playModeAction) {
      final mode = (extras?[_loopModeKey] as num?)?.toInt();
      if (mode != null && mode >= 1 && mode <= 3) {
        VivoBridge.setLoopMode(mode);
        refreshVivoMetadata(force: true);
      }
      return null;
    }
    return super.customAction(name, extras);
  }

  /// 把 vivo 需要的 extras / 红心状态补进当前 MediaItem 与队列。
  ///
  /// [force] 为 false 时只在循环模式、收藏状态或当前歌曲发生变化时才重新
  /// 发布，避免 PlayerController 每秒多次 notify 造成无谓的刷新。
  void refreshVivoMetadata({bool force = false}) {
    if (!force && !_needsRefresh()) return;
    _lastLoopMode = VivoBridge.loopMode;
    _lastLiked = _currentSong == null ? null : VivoBridge.isLiked(_currentSong!);
    _lastSongId = _currentSong == null ? null : _songId(_currentSong!);

    _publishCurrent();
    final currentQueue = queue.value;
    if (currentQueue.isNotEmpty) {
      queue.add([for (final item in currentQueue) _decorate(item)]);
    }
  }

  bool _needsRefresh() {
    final song = _currentSong;
    if (song == null) return false;
    return _lastLoopMode != VivoBridge.loopMode ||
        _lastLiked != VivoBridge.isLiked(song) ||
        _lastSongId != _songId(song);
  }

  void _publishCurrent() {
    final item = mediaItem.value;
    if (item == null) return;
    mediaItem.add(_decorate(item));
  }

  MediaItem _decorate(
    MediaItem item, {
    Song? song,
    int? page,
    bool? hasMore,
  }) {
    final track = song ?? _songFor(item.id);
    final extras = <String, dynamic>{
      ...?item.extras,
      _supportEventKey: supportEvents,
      _loopModeKey: VivoBridge.loopMode,
      if (page != null) _pageKey: page,
      if (hasMore != null) _hasMoreKey: hasMore,
    };
    return item.copyWith(
      duration: _durationFor(track, item.duration),
      playable: true,
      rating: Rating.newHeartRating(track != null && VivoBridge.isLiked(track)),
      extras: extras,
    );
  }

  MediaItem _mediaItemForSong(Song song) => MediaItem(
    id: _songId(song),
    album: song.albumName,
    title: song.title,
    artist: song.artist,
    duration: _durationFor(song, null),
    artUri: song.coverUrl == null ? null : Uri.tryParse(song.coverUrl!),
  );

  Duration? _durationFor(Song? song, Duration? fallback) {
    if (song == null) return fallback;
    if (identical(song, _currentSong) && _resolvedDuration != null) {
      return _resolvedDuration;
    }
    final own = song.duration;
    if (own != null && own > Duration.zero) return own;
    return fallback;
  }

  String _songId(Song song) => song.hash.isEmpty ? song.id : song.hash;

  Song? _songFor(String? id) => id == null ? null : _songsById[id];

  void _remember(Iterable<Song> songs) {
    for (final song in songs) {
      _songsById[_songId(song)] = song;
    }
  }
}
