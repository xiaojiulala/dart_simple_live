import 'dart:async';
import 'dart:collection';

import 'package:canvas_danmaku/models/danmaku_content_item.dart';
import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_tv_app/app/constant.dart';
import 'package:simple_live_tv_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_tv_app/app/event_bus.dart';
import 'package:simple_live_tv_app/app/log.dart';
import 'package:simple_live_tv_app/app/sites.dart';
import 'package:simple_live_tv_app/app/utils.dart';
import 'package:simple_live_tv_app/models/db/follow_user.dart';
import 'package:simple_live_tv_app/models/db/history.dart';
import 'package:simple_live_tv_app/modules/live_room/player/player_controller.dart';
import 'package:simple_live_tv_app/services/db_service.dart';
import 'package:simple_live_tv_app/services/follow_user_service.dart';

class LiveRoomController extends PlayerController with WidgetsBindingObserver {
  final Site pSite;
  final String pRoomId;
  late LiveDanmaku liveDanmaku;
  LiveRoomController({
    required this.pSite,
    required this.pRoomId,
  }) {
    rxSite = pSite.obs;
    rxRoomId = pRoomId.obs;
    liveDanmaku = site.liveSite.getDanmaku();
  }
  final FocusNode focusNode = FocusNode();
  late Rx<Site> rxSite;
  Site get site => rxSite.value;
  late Rx<String> rxRoomId;
  String get roomId => rxRoomId.value;

  Rx<LiveRoomDetail?> detail = Rx<LiveRoomDetail?>(null);
  var online = 0.obs;
  var followed = false.obs;
  var liveStatus = false.obs;

  /// 清晰度数据
  RxList<LivePlayQuality> qualites = RxList<LivePlayQuality>();

  /// 当前清晰度
  var currentQuality = -1;
  var currentQualityInfo = "".obs;

  /// 线路数据
  RxList<String> playUrls = RxList<String>();

  Map<String, String>? playHeaders;

  /// 当前线路
  var currentLineIndex = -1;
  var currentLineInfo = "".obs;

  /// 是否处于后台
  var isBackground = false;

  var datetime = "00:00".obs;
  Timer? _resetRetryTimer;

  /// 播放器代际号：避免并发 open 造成解码器/Surface 竞态（卡死、崩溃）
  int _playerGeneration = 0;

  Timer? _playbackWatchdog;
  Duration? _lastWatchdogPosition;
  int _stallSampleCount = 0;
  int _bufferingSampleCount = 0;
  bool _watchdogRefreshing = false;
  DateTime? _lastWatchdogRefreshAt;

  void initTimer() {
    Timer.periodic(const Duration(seconds: 1), (timer) {
      var now = DateTime.now();
      datetime.value =
          "${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}";
    });
  }

  /// 双击退出Flag
  bool doubleClickExit = false;

  /// 双击退出Timer
  Timer? doubleClickTimer;
  final Queue<String> _recentDanmuFingerprints = Queue<String>();
  final Map<String, int> _recentDanmuCounts = <String, int>{};
  int _recentDanmuEventsSincePrune = 0;
  RxList<LiveRepeatedDanmuSummary> liveEventFlows =
      <LiveRepeatedDanmuSummary>[].obs;
  LiveRepeatedDanmuAggregator _liveEventFlowAggregator =
      LiveRepeatedDanmuAggregator();
  Timer? _liveEventFlowTimer;

  @override
  void onInit() {
    initTimer();
    _startLiveEventFlowTimer();
    showDanmakuState.value = AppSettingsController.instance.danmuEnable.value;
    followed.value = DBService.instance.getFollowExist("${site.id}_$roomId");

    loadData();

    super.onInit();
  }

  void refreshRoom() {
    //messages.clear();

    liveDanmaku.stop();
    _clearDanmuDedupeState();

    loadData();
  }

  /// 初始化弹幕接收事件
  void initDanmau() {
    liveDanmaku.onMessage = onWSMessage;
    liveDanmaku.onClose = onWSClose;
    liveDanmaku.onReady = onWSReady;
  }

  /// 接收到WebSocket信息
  void onWSMessage(LiveMessage msg) {
    if (msg.type == LiveMessageType.chat) {
      // 关键词屏蔽检查
      for (var keyword in AppSettingsController.instance.shieldList) {
        Pattern? pattern;
        if (Utils.isRegexFormat(keyword)) {
          String removedSlash = Utils.removeRegexFormat(keyword);
          try {
            pattern = RegExp(removedSlash);
          } catch (e) {
            // should avoid this during add keyword
            Log.d("关键词：$keyword 正则格式错误");
          }
        } else {
          pattern = keyword;
        }
        if (pattern != null && msg.message.contains(pattern)) {
          Log.d("关键词：$keyword\n已屏蔽消息内容：${msg.message}");
          return;
        }
      }

      if (_isDuplicateDanmu(msg)) {
        return;
      }

      _recordLiveEventFlow(msg);

      if (!liveStatus.value || isBackground) {
        return;
      }

      final renderEmoji = AppSettingsController.instance.danmuRenderEmoji.value;
      final parts = renderEmoji ? _buildDanmakuContentParts(msg.spans) : null;
      addDanmaku([
        DanmakuContentItem(
          msg.message,
          color: Color.fromARGB(255, msg.color.r, msg.color.g, msg.color.b),
          imageUrls: renderEmoji && parts == null ? msg.imageUrls : null,
          parts: parts,
        ),
      ]);
    } else if (msg.type == LiveMessageType.online) {
      online.value = msg.data;
    } else if (msg.type == LiveMessageType.superChat) {
      //superChats.add(msg.data);
    }
  }

  List<DanmakuContentPart>? _buildDanmakuContentParts(
    List<LiveMessageSpan>? spans,
  ) {
    final source = spans ?? const <LiveMessageSpan>[];
    if (source.isEmpty) {
      return null;
    }
    final parts = <DanmakuContentPart>[];
    for (final span in source) {
      if (span.isText) {
        final text = span.text ?? "";
        if (text.isNotEmpty) {
          parts.add(DanmakuContentPart.text(text));
        }
      } else if (span.isImage) {
        final imageUrl = (span.imageUrl ?? "").trim();
        if (imageUrl.isNotEmpty) {
          parts.add(DanmakuContentPart.image(imageUrl));
        }
      }
    }
    return parts.isEmpty ? null : parts;
  }

  bool _isDuplicateDanmu(LiveMessage msg) {
    final settings = AppSettingsController.instance;
    if (!settings.danmuDedupeEnable.value) {
      return false;
    }
    final strictMode = settings.danmuDedupeStrictMode;
    final fingerprint = _buildDanmuFingerprint(
      msg,
      includeUserName: !strictMode,
    );
    if (fingerprint == null) {
      return false;
    }
    final windowSize = settings.effectiveDanmuDedupeWindow;
    final duplicate = _recentDanmuCounts.containsKey(fingerprint);
    _recentDanmuFingerprints.addLast(fingerprint);
    _recentDanmuCounts[fingerprint] =
        (_recentDanmuCounts[fingerprint] ?? 0) + 1;
    if (strictMode) {
      _recentDanmuEventsSincePrune = 0;
      _pruneRecentDanmuFingerprints(windowSize);
      return duplicate;
    }

    final step = settings.danmuDedupeStep.value.clamp(1, 20).toInt();
    _recentDanmuEventsSincePrune += 1;
    final shouldPrune = _recentDanmuEventsSincePrune >= step ||
        _recentDanmuFingerprints.length > windowSize + step - 1;
    if (shouldPrune) {
      _recentDanmuEventsSincePrune = 0;
    }
    if (shouldPrune) {
      _pruneRecentDanmuFingerprints(windowSize);
    }
    return duplicate;
  }

  void _pruneRecentDanmuFingerprints(int windowSize) {
    while (_recentDanmuFingerprints.length > windowSize) {
      final removed = _recentDanmuFingerprints.removeFirst();
      final count = (_recentDanmuCounts[removed] ?? 0) - 1;
      if (count <= 0) {
        _recentDanmuCounts.remove(removed);
      } else {
        _recentDanmuCounts[removed] = count;
      }
    }
  }

  String? _buildDanmuFingerprint(
    LiveMessage msg, {
    required bool includeUserName,
  }) {
    final parts = <String>[];
    final message = _normalizeDanmuFingerprintPart(msg.message);
    if (message.isNotEmpty) {
      parts.add("m:$message");
    }
    for (final span in msg.spans ?? const <LiveMessageSpan>[]) {
      final text = _normalizeDanmuFingerprintPart(span.text ?? "");
      final imageUrl = _normalizeDanmuFingerprintPart(span.imageUrl ?? "");
      if (text.isNotEmpty) {
        parts.add("t:$text");
      }
      if (imageUrl.isNotEmpty) {
        parts.add("i:$imageUrl");
      }
    }
    for (final imageUrl in msg.imageUrls ?? const <String>[]) {
      final value = _normalizeDanmuFingerprintPart(imageUrl);
      if (value.isNotEmpty) {
        parts.add("u:$value");
      }
    }
    if (parts.isEmpty) {
      return null;
    }
    if (!includeUserName) {
      return parts.join("\u0002");
    }
    final userName = _normalizeDanmuFingerprintPart(msg.userName);
    if (userName.isEmpty) {
      return null;
    }
    return "$userName\u0001${parts.join("\u0002")}";
  }

  String _normalizeDanmuFingerprintPart(String value) {
    return value.trim().replaceAll(RegExp(r"\s+"), " ");
  }

  void _clearDanmuDedupeState() {
    _recentDanmuFingerprints.clear();
    _recentDanmuCounts.clear();
    _recentDanmuEventsSincePrune = 0;
  }

  void _startLiveEventFlowTimer() {
    _liveEventFlowTimer?.cancel();
    _liveEventFlowTimer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => _flushLiveEventFlow(),
    );
  }

  void _recordLiveEventFlow(LiveMessage msg) {
    if (msg.userName == "LiveSysMessage") {
      return;
    }
    final settings = AppSettingsController.instance;
    if (!settings.liveEventFlowEnable.value) {
      clearLiveEventFlow();
      return;
    }
    final text = _normalizeDanmuFingerprintPart(msg.message);
    if (text.isEmpty) {
      return;
    }
    _ensureLiveEventFlowAggregatorSettings();
    _liveEventFlowAggregator.add(text);
    _flushLiveEventFlow();
  }

  void _flushLiveEventFlow() {
    final settings = AppSettingsController.instance;
    if (!settings.liveEventFlowEnable.value) {
      clearLiveEventFlow();
      return;
    }
    _ensureLiveEventFlowAggregatorSettings();
    final summaries = _liveEventFlowAggregator.preview(
      displayTtl: Duration(
        seconds: settings.effectiveLiveEventFlowDisplaySeconds,
      ),
    );
    liveEventFlows.assignAll(summaries);
  }

  void _ensureLiveEventFlowAggregatorSettings() {
    final settings = AppSettingsController.instance;
    final countWindow = Duration(
      seconds: settings.effectiveLiveEventFlowWindowSeconds,
    );
    final minDisplayCount = settings.effectiveLiveEventFlowMinCount;
    if (_liveEventFlowAggregator.countWindow == countWindow &&
        _liveEventFlowAggregator.minDisplayCount == minDisplayCount) {
      return;
    }
    _liveEventFlowAggregator = LiveRepeatedDanmuAggregator(
      countWindow: countWindow,
      minDisplayCount: minDisplayCount,
    );
    liveEventFlows.clear();
  }

  void clearLiveEventFlow() {
    _liveEventFlowAggregator.clear();
    liveEventFlows.clear();
  }

  /// 接收 WebSocket 关闭消息
  void onWSClose(String msg) {
    Log.d("弹幕服务器连接状态：$msg");
    final shouldNotify = msg.contains("失败") || msg.contains("超过最大次数");
    if (shouldNotify && AppSettingsController.instance.danmuEnable.value) {
      SmartDialog.showToast("弹幕连接异常：$msg");
    }
  }

  /// WebSocket 已连接完成
  void onWSReady() {
    Log.d("弹幕服务器连接成功");
  }

  /// 加载直播间信息
  void loadData() async {
    try {
      pageLoadding.value = true;
      detail.value = await site.liveSite.getRoomDetail(roomId: roomId);

      addHistory();
      online.value = detail.value!.online;
      liveStatus.value = detail.value!.status || detail.value!.isRecord;
      if (liveStatus.value) {
        getPlayQualites();
      }
      if (detail.value!.isRecord) {
        SmartDialog.showToast("当前主播未开播，正在轮播录像");
      }

      initDanmau();
      liveDanmaku.start(detail.value?.danmakuData);
    } catch (e) {
      SmartDialog.showToast(e.toString());
    } finally {
      pageLoadding.value = false;
    }
  }

  /// 初始化播放器
  void getPlayQualites() async {
    qualites.clear();
    currentQuality = -1;
    try {
      var playQualites =
          await site.liveSite.getPlayQualites(detail: detail.value!);

      if (playQualites.isEmpty) {
        SmartDialog.showToast("无法读取播放清晰度");
        return;
      }
      qualites.value = playQualites;
      var qualityLevel = AppSettingsController.instance.qualityLevel.value;
      if (qualityLevel == 2) {
        //最高
        currentQuality = 0;
      } else if (qualityLevel == 0) {
        //最低
        currentQuality = playQualites.length - 1;
      } else {
        //中间值
        int middle = (playQualites.length / 2).floor();
        currentQuality = middle;
      }

      getPlayUrl();
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast("无法读取播放清晰度");
    }
  }

  void getPlayUrl() async {
    playUrls.clear();
    currentQualityInfo.value = qualites[currentQuality].quality;
    currentLineInfo.value = "";
    currentLineIndex = -1;
    var playUrl = await site.liveSite
        .getPlayUrls(detail: detail.value!, quality: qualites[currentQuality]);
    if (playUrl.urls.isEmpty) {
      SmartDialog.showToast("无法读取播放地址");
      return;
    }
    playUrls.value = playUrl.urls;
    playHeaders = playUrl.headers;
    currentLineIndex = 0;
    currentLineInfo.value = "线路${currentLineIndex + 1}";
    //重置错误次数
    mediaErrorRetryCount = 0;
    setPlayer();
  }

  void changePlayLine(int index) {
    currentLineIndex = index;
    //重置错误次数
    mediaErrorRetryCount = 0;
    setPlayer();
  }

  Future<bool> reloadPlayUrls({bool silent = true}) async {
    if (detail.value == null ||
        currentQuality < 0 ||
        currentQuality >= qualites.length) {
      return false;
    }
    try {
      var playUrl = await site.liveSite
          .getPlayUrls(detail: detail.value!, quality: qualites[currentQuality]);
      if (playUrl.urls.isEmpty) {
        if (!silent) {
          SmartDialog.showToast("无法读取播放地址");
        }
        return false;
      }
      playUrls.value = playUrl.urls;
      playHeaders = playUrl.headers;
      if (currentLineIndex < 0) {
        currentLineIndex = 0;
      } else if (currentLineIndex >= playUrls.length) {
        currentLineIndex = playUrls.length - 1;
      }
      currentLineInfo.value = "线路${currentLineIndex + 1}";
      return true;
    } catch (e) {
      if (!silent) {
        SmartDialog.showToast("读取播放地址失败");
      }
      return false;
    }
  }

  Future<bool> setPlayer({bool refreshUrls = false}) async {
    final generation = ++_playerGeneration;
    if (refreshUrls) {
      var reloaded = await reloadPlayUrls(silent: true);
      if (generation != _playerGeneration) return true;
      if (!reloaded) return false;
    }
    if (playUrls.isEmpty ||
        currentLineIndex < 0 ||
        currentLineIndex >= playUrls.length) {
      return false;
    }
    currentLineInfo.value = "线路${currentLineIndex + 1}";
    errorMsg.value = "";
    if (generation != _playerGeneration) return true;

    // 全平台：停止旧流并等待资源释放，避免解码器/Surface 渲染冲突
    if (player.state.playing || player.state.playlist.medias.isNotEmpty) {
      try {
        await player.stop();
        await Future.delayed(const Duration(milliseconds: 120));
      } catch (e, stackTrace) {
        Log.e("停止旧播放失败: $e", stackTrace);
      }
    }
    if (generation != _playerGeneration) return true;

    try {
      await player.open(
        Media(
          playUrls[currentLineIndex],
          httpHeaders: playHeaders,
        ),
      );
    } catch (e, stackTrace) {
      Log.e("打开播放失败: $e", stackTrace);
    }
    if (generation != _playerGeneration) return true;

    // 播放正常维持 15 秒后重置重试计数器，使得每次10分钟断开都能成功续播
    _resetRetryTimer?.cancel();
    _resetRetryTimer = Timer(const Duration(seconds: 15), () {
      mediaErrorRetryCount = 0;
    });

    Log.d("播放链接\r\n：${playUrls[currentLineIndex]}");
    _startPlaybackWatchdog();
    return true;
  }

  void _startPlaybackWatchdog() {
    _playbackWatchdog?.cancel();
    _lastWatchdogPosition = null;
    _stallSampleCount = 0;
    _bufferingSampleCount = 0;
    _playbackWatchdog = Timer.periodic(const Duration(seconds: 5), (timer) {
      if (isBackground || !liveStatus.value) {
        _lastWatchdogPosition = null;
        _stallSampleCount = 0;
        _bufferingSampleCount = 0;
        return;
      }
      if (!player.state.playing) {
        _lastWatchdogPosition = null;
        _stallSampleCount = 0;
        _bufferingSampleCount = 0;
        return;
      }
      final position = player.state.position;
      final last = _lastWatchdogPosition;
      final advanced =
          last == null || position.inMilliseconds - last.inMilliseconds >= 250;
      final bufferLead = player.state.buffer - position;
      final bufferExhausted = bufferLead <= const Duration(milliseconds: 350);
      if (player.state.buffering || bufferExhausted) {
        _bufferingSampleCount += 1;
      } else {
        _bufferingSampleCount = 0;
      }
      if (!advanced) {
        _stallSampleCount += 1;
      } else {
        _stallSampleCount = 0;
      }
      if ((_stallSampleCount >= 2 || _bufferingSampleCount >= 3) &&
          !_watchdogRefreshing &&
          (_lastWatchdogRefreshAt == null ||
              DateTime.now().difference(_lastWatchdogRefreshAt!) >=
                  const Duration(seconds: 8))) {
        _watchdogRefreshing = true;
        _lastWatchdogRefreshAt = DateTime.now();
        _stallSampleCount = 0;
        _bufferingSampleCount = 0;
        Log.w("检测到播放停滞或持续缓冲卡死，自动刷新播放");
        _refreshPlayerFromWatchdog().whenComplete(() {
          _watchdogRefreshing = false;
        });
      }
      _lastWatchdogPosition = position;
    });
  }

  Future<void> _refreshPlayerFromWatchdog() async {
    final reloaded = await setPlayer(refreshUrls: true);
    if (!reloaded) {
      Log.w("看门狗刷新失败，尝试切线路恢复");
      if (playUrls.length > 1) {
        changePlayLine((currentLineIndex + 1) % playUrls.length);
      }
    }
  }

  @override
  void mediaEnd() async {
    if (mediaErrorRetryCount < 3) {
      Log.d("播放结束，尝试第${mediaErrorRetryCount + 1}次刷新");
      if (mediaErrorRetryCount > 0) {
        //延迟一秒再刷新
        await Future.delayed(const Duration(seconds: 1));
      }
      mediaErrorRetryCount += 1;
      bool shouldRefresh =
          site.id == Constant.kDouyu || site.id == Constant.kHuya;
      setPlayer(refreshUrls: shouldRefresh);
      return;
    }

    Log.d("播放结束");
    // 遍历线路，如果全部链接都断开就是直播结束了
    if (playUrls.length - 1 == currentLineIndex) {
      liveStatus.value = false;
    } else {
      changePlayLine(currentLineIndex + 1);
    }
  }

  int mediaErrorRetryCount = 0;
  @override
  void mediaError(String error) async {
    if (mediaErrorRetryCount < 3) {
      Log.d("播放失败，尝试第${mediaErrorRetryCount + 1}次刷新");
      if (mediaErrorRetryCount > 0) {
        //延迟一秒再刷新
        await Future.delayed(const Duration(seconds: 1));
      }
      mediaErrorRetryCount += 1;
      bool shouldRefresh =
          site.id == Constant.kDouyu || site.id == Constant.kHuya;
      setPlayer(refreshUrls: shouldRefresh);
      return;
    }

    if (playUrls.length - 1 == currentLineIndex) {
      errorMsg.value = "播放失败";
      SmartDialog.showToast("播放失败:$error");
    } else {
      changePlayLine(currentLineIndex + 1);
    }
  }

  /// 添加历史记录
  void addHistory() {
    if (detail.value == null) {
      return;
    }
    var id = "${site.id}_$roomId";
    var history = DBService.instance.getHistory(id);
    if (history != null) {
      history.updateTime = DateTime.now();
    }
    history ??= History(
      id: id,
      roomId: roomId,
      siteId: site.id,
      userName: detail.value?.userName ?? "",
      face: detail.value?.userAvatar ?? "",
      updateTime: DateTime.now(),
    );

    DBService.instance.addOrUpdateHistory(history);
  }

  /// 关注用户
  void followUser() {
    if (detail.value == null) {
      return;
    }
    var id = "${site.id}_$roomId";
    DBService.instance.addFollow(
      FollowUser(
        id: id,
        roomId: roomId,
        siteId: site.id,
        userName: detail.value?.userName ?? "",
        face: detail.value?.userAvatar ?? "",
        addTime: DateTime.now(),
      ),
    );
    followed.value = true;
    EventBus.instance.emit(Constant.kUpdateFollow, id);
    SmartDialog.showToast("已关注");
  }

  /// 取消关注用户
  void removeFollowUser() async {
    if (detail.value == null) {
      return;
    }
    // if (!await Utils.showAlertDialog("确定要取消关注该用户吗？", title: "取消关注")) {
    //   return;
    // }

    var id = "${site.id}_$roomId";
    DBService.instance.deleteFollow(id);
    followed.value = false;
    EventBus.instance.emit(Constant.kUpdateFollow, id);
    SmartDialog.showToast("已取消关注");
  }

  void resetRoom(Site site, String roomId) async {
    if (this.site == site && this.roomId == roomId) {
      return;
    }

    rxSite.value = site;
    rxRoomId.value = roomId;

    // 清除全部消息
    liveDanmaku.stop();
    _clearDanmuDedupeState();
    clearLiveEventFlow();

    danmakuController?.clear();

    // 重新设置LiveDanmaku
    liveDanmaku = site.liveSite.getDanmaku();

    // 停止播放
    await player.stop();

    // 刷新信息
    loadData();
  }

  void nextChannel() {
    //读取正在直播的频道
    var liveChannels = FollowUserService.instance.livingList;
    if (liveChannels.isEmpty) {
      SmartDialog.showToast("没有正在直播的频道");
      return;
    }
    var index = liveChannels
        .indexWhere((element) => element.id == "${site.id}_$roomId");
    // if (index == -1) {
    //   //当前频道不在列表中

    //   return;
    // }
    index += 1;
    if (index >= liveChannels.length) {
      index = 0;
    }
    var nextChannel = liveChannels[index];

    resetRoom(Sites.allSites[nextChannel.siteId]!, nextChannel.roomId);
  }

  void prevChannel() {
    //读取正在直播的频道
    var liveChannels = FollowUserService.instance.livingList;
    if (liveChannels.isEmpty) {
      SmartDialog.showToast("没有正在直播的频道");
      return;
    }
    var index = liveChannels
        .indexWhere((element) => element.id == "${site.id}_$roomId");
    // if (index == -1) {
    //   //当前频道不在列表中

    //   return;
    // }
    index -= 1;
    if (index < 0) {
      index = liveChannels.length - 1;
    }
    var nextChannel = liveChannels[index];

    resetRoom(Sites.allSites[nextChannel.siteId]!, nextChannel.roomId);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    if (state == AppLifecycleState.paused) {
      Log.d("进入后台");
      //进入后台，关闭弹幕
      danmakuController?.clear();
      isBackground = true;
    } else
    //返回前台
    if (state == AppLifecycleState.resumed) {
      Log.d("返回前台");
      isBackground = false;
    }
  }

  @override
  void onClose() {
    _playbackWatchdog?.cancel();
    _resetRetryTimer?.cancel();
    liveDanmaku.stop();
    _liveEventFlowTimer?.cancel();
    clearLiveEventFlow();

    danmakuController = null;
    super.onClose();
  }
}
