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
import 'package:simple_live_tv_app/services/bilibili_account_service.dart';
import 'package:simple_live_tv_app/services/db_service.dart';
import 'package:simple_live_tv_app/services/douyu_account_service.dart';
import 'package:simple_live_tv_app/services/follow_user_service.dart';
import 'package:simple_live_tv_app/modules/home/home_controller.dart';

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

  /// 断流自动恢复记账：恢复成功即重置重试计数（"连续失败"语义），
  /// 并记录恢复时刻；5 分钟内成功恢复次数过多说明流本身不可持续，
  /// 不再无限重试，走下播/换台兜底，避免死循环。
  final List<DateTime> _playbackRecoveryTimes = [];
  static const int _maxRecoveriesPerWindow = 6;
  static const Duration _recoveryWindow = Duration(minutes: 5);

  @override
  void onInit() {
    FollowUserService.instance.isInLiveRoom = true;
    initTimer();
    _startLiveEventFlowTimer();
    showDanmakuState.value = AppSettingsController.instance.danmuEnable.value;
    followed.value = site.id != Constant.kXiaohongshu &&
        DBService.instance.getFollowExist("${site.id}_$roomId");

    loadData();

    super.onInit();
  }

  void refreshRoom() {
    //messages.clear();
    _resetPlaybackRecoveryBookkeeping();
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
    _resetPlaybackRecoveryBookkeeping();
    try {
      pageLoadding.value = true;
      detail.value = await site.liveSite.getRoomDetail(roomId: roomId);

      // 小红书平台单场次特性：关播后场次失效，不支持常驻关注；若数据库中有历史遗留的旧场次关注，自动清理
      if (site.id == Constant.kXiaohongshu && detail.value != null) {
        _cleanXiaohongshuOldFollows(detail.value!);
      }

      addHistory();
      online.value = detail.value!.online;
      liveStatus.value = detail.value!.status || detail.value!.isRecord;
      if (liveStatus.value) {
        getPlayQualites();
      }
      if (detail.value!.isRecord) {
        SmartDialog.showToast("当前主播未开播，正在轮播录像");
      } else if (site.id == Constant.kXiaohongshu && !liveStatus.value) {
        SmartDialog.showToast("当前小红书场次未在直播。小红书每次开播均为新场次，若主播正在直播，请投送最新链接。");
      }

      initDanmau();
      liveDanmaku.start(detail.value?.danmakuData);
    } catch (e) {
      if (site.id == Constant.kXiaohongshu) {
        _handleXiaohongshuLoadError(e);
      } else {
        SmartDialog.showToast(e.toString());
      }
    } finally {
      pageLoadding.value = false;
    }
  }

  bool _isSameXiaohongshuAnchor(String a, String b) {
    final cleanA = a.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
    final cleanB = b.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
    return cleanA.isNotEmpty && cleanA != "小红书主播" && cleanA == cleanB;
  }

  void _cleanXiaohongshuOldFollows(LiveRoomDetail roomDetail) {
    final name = roomDetail.userName.trim();
    if (name.isEmpty || name == "小红书主播") {
      return;
    }
    try {
      final allFollows = DBService.instance.getFollowList();
      final oldFollows = allFollows.where((f) =>
          f.siteId == Constant.kXiaohongshu &&
          _isSameXiaohongshuAnchor(f.userName, name)).toList();

      for (final old in oldFollows) {
        DBService.instance.deleteFollow(old.id);
        EventBus.instance.emit(Constant.kUpdateFollow, old.id);
      }
    } catch (e, stackTrace) {
      Log.e("小红书旧关注清理失败: $e", stackTrace);
    }
  }

  void _handleXiaohongshuLoadError(dynamic e) async {
    final isFollowed = DBService.instance.getFollowExist("${site.id}_$roomId");
    if (isFollowed) {
      final shouldRemove = await Utils.showAlertDialog(
        "小红书采用单场次直播机制（Session ID），历史场次下播后即永久关闭。\n\n"
        "若该主播已开启新一场直播，请通过手机或网页控制台投送最新直播链接，系统会自动识别并迁移更新关注。\n\n"
        "是否取消关注当前已失效的历史场次？",
        title: "小红书直播场次已结束",
        confirm: "取消关注此场次",
        cancel: "我知道了",
      );
      if (shouldRemove) {
        removeFollowUser();
        Get.back();
      }
    } else {
      SmartDialog.showToast(
        "该小红书直播场次已结束。小红书每次开播均生成新场次号，若主播已开启新直播，请投送最新分享链接。",
        displayTime: const Duration(seconds: 4),
      );
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
      _checkDouyuCookieExpirationNotice();
      _checkBilibiliCookieExpirationNotice();
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast("无法读取播放清晰度");
    }
  }

  bool _douyuExpiryNoticeChecked = false;

  void _checkDouyuCookieExpirationNotice() {
    if (_douyuExpiryNoticeChecked) return;
    if (site.id != Constant.kDouyu) return;
    final account = DouyuAccountService.instance;
    if (!account.logined.value || account.cookie.isEmpty) return;

    _douyuExpiryNoticeChecked = true;

    if (account.isExpired) {
      Future.delayed(const Duration(seconds: 2), () {
        if (isClosed || isBackground) return;
        const text = "⚠️【系统提醒】斗鱼登录授权已过期，4K/2K 超清已受限，请重新扫码登录！";
        if (showDanmakuState.value && danmakuController != null) {
          addDanmaku([
            DanmakuContentItem(
              text,
              type: DanmakuItemType.top,
              selfSend: true,
              color: const Color(0xFFFF5252),
            ),
          ]);
        } else {
          SmartDialog.showToast(
            text,
            displayTime: const Duration(seconds: 6),
          );
        }
      });
    } else if (account.remainingDays <= 1) {
      final hours = account.remainingHours;
      Future.delayed(const Duration(seconds: 2), () {
        if (isClosed || isBackground) return;
        final text = "💡【系统提醒】斗鱼登录授权将在 $hours 小时后到期，请抽空重新扫码续期";
        if (showDanmakuState.value && danmakuController != null) {
          addDanmaku([
            DanmakuContentItem(
              text,
              type: DanmakuItemType.top,
              selfSend: true,
              color: const Color(0xFFFFB300),
            ),
          ]);
        } else {
          SmartDialog.showToast(
            text,
            displayTime: const Duration(seconds: 5),
          );
        }
      });
    }
  }

  bool _bilibiliExpiryNoticeChecked = false;

  void _checkBilibiliCookieExpirationNotice() {
    if (_bilibiliExpiryNoticeChecked) return;
    if (site.id != Constant.kBiliBili) return;
    final account = BiliBiliAccountService.instance;

    _bilibiliExpiryNoticeChecked = true;

    if (account.cookie.isNotEmpty && account.isExpired) {
      Future.delayed(const Duration(seconds: 2), () {
        if (isClosed || isBackground) return;
        const text = "⚠️【系统提醒】哔哩哔哩登录授权已过期，高清画质已受限（最高720P），请重新扫码登录！";
        if (showDanmakuState.value && danmakuController != null) {
          addDanmaku([
            DanmakuContentItem(
              text,
              type: DanmakuItemType.top,
              selfSend: true,
              color: const Color(0xFFFF5252),
            ),
          ]);
        } else {
          SmartDialog.showToast(
            text,
            displayTime: const Duration(seconds: 6),
          );
        }
      });
    } else if (!account.logined.value || account.cookie.isEmpty) {
      Future.delayed(const Duration(seconds: 2), () {
        if (isClosed || isBackground) return;
        const text = "💡【系统提醒】哔哩哔哩未登录，当前画质受限最高720P，前往“设置”扫码可解锁1080P/原画";
        if (showDanmakuState.value && danmakuController != null) {
          addDanmaku([
            DanmakuContentItem(
              text,
              type: DanmakuItemType.top,
              selfSend: true,
              color: const Color(0xFFFFB300),
            ),
          ]);
        } else {
          SmartDialog.showToast(
            text,
            displayTime: const Duration(seconds: 5),
          );
        }
      });
    } else if (account.remainingDays <= 7) {
      final days = account.remainingDays;
      Future.delayed(const Duration(seconds: 2), () {
        if (isClosed || isBackground) return;
        final text = "💡【系统提醒】哔哩哔哩登录授权将在 $days 天后到期，请抽空重新扫码续期";
        if (showDanmakuState.value && danmakuController != null) {
          addDanmaku([
            DanmakuContentItem(
              text,
              type: DanmakuItemType.top,
              selfSend: true,
              color: const Color(0xFFFFB300),
            ),
          ]);
        } else {
          SmartDialog.showToast(
            text,
            displayTime: const Duration(seconds: 5),
          );
        }
      });
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

    _resetRetryTimer?.cancel();
    Log.d("播放链接\r\n：${playUrls[currentLineIndex]}");
    _startPlaybackWatchdog();
    _onPlaybackRecovered();
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
          last != null && position.inMilliseconds - last.inMilliseconds >= 250;
      _lastWatchdogPosition = position;

      if (advanced) {
        // 播放进度正常前进，说明画面正在流畅渲染，绝非卡死；直接清空采样计数
        _stallSampleCount = 0;
        _bufferingSampleCount = 0;
        return;
      }

      // 仅在进度停滞（画面冻结）时，才累计采样
      _stallSampleCount += 1;
      if (player.state.buffering) {
        _bufferingSampleCount += 1;
      } else {
        _bufferingSampleCount = 0;
      }

      if ((_stallSampleCount >= 3 || _bufferingSampleCount >= 4) &&
          !_watchdogRefreshing &&
          (_lastWatchdogRefreshAt == null ||
              DateTime.now().difference(_lastWatchdogRefreshAt!) >=
                  const Duration(seconds: 10))) {
        _watchdogRefreshing = true;
        _lastWatchdogRefreshAt = DateTime.now();
        _stallSampleCount = 0;
        _bufferingSampleCount = 0;
        Log.w("检测到播放真正停滞卡死，自动刷新播放");
        _refreshPlayerFromWatchdog().whenComplete(() {
          _watchdogRefreshing = false;
        });
      }
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

  /// 播放器成功打开后调用：把断流重试计数归零（"连续失败"语义——
  /// 周期性被服务端掐流的房间，不再第 3 次断流就被误判下播），
  /// 同时记录恢复时刻用于恢复风暴检测。
  void _onPlaybackRecovered() {
    if (mediaErrorRetryCount > 0) {
      final now = DateTime.now();
      _playbackRecoveryTimes.add(now);
      _playbackRecoveryTimes.removeWhere(
        (t) => t.isBefore(now.subtract(_recoveryWindow)),
      );
      if (_playbackRecoveryTimes.length >= _maxRecoveriesPerWindow) {
        Log.i(
          "断流恢复风暴：${_recoveryWindow.inMinutes}分钟内已恢复"
          "${_playbackRecoveryTimes.length}次，暂停自动重试",
        );
      }
    }
    mediaErrorRetryCount = 0;
  }

  /// 恢复风暴：短时间内反复"断→恢复"，说明流本身不可持续
  bool get _playbackRecoveryStormDetected {
    final cutoff = DateTime.now().subtract(_recoveryWindow);
    _playbackRecoveryTimes.removeWhere((t) => t.isBefore(cutoff));
    return _playbackRecoveryTimes.length >= _maxRecoveriesPerWindow;
  }

  /// 手动刷新 / 进入新房间时清空恢复记账
  void _resetPlaybackRecoveryBookkeeping() {
    mediaErrorRetryCount = 0;
    _playbackRecoveryTimes.clear();
  }

  /// 单次断流恢复：刷新播放地址并重开播放器。取流/打开抛出的异常
  /// 不再静默逃逸（旧逻辑页面会冻住在"播放中"），立即走兜底判定。
  Future<void> _recoverPlaybackOnce() async {
    try {
      await setPlayer(refreshUrls: _shouldRefreshUrlsOnPlaybackRetry);
    } catch (e, stackTrace) {
      Log.e("断流恢复失败：$e", stackTrace);
      await _playbackRetriesExhausted();
    }
  }

  /// 重试耗尽后的兜底：优先切换剩余线路；已是最末线路且未触发恢复风暴时，
  /// 虎牙/斗鱼重置计数重新签名再试一轮（斗鱼常只返回一条线路，靠重签兜底）；
  /// 否则判定下播。
  Future<void> _playbackRetriesExhausted({
    bool fromError = false,
    String? error,
  }) async {
    if (playUrls.length - 1 != currentLineIndex) {
      changePlayLine(currentLineIndex + 1);
      return;
    }
    if ((site.id == Constant.kHuya || site.id == Constant.kDouyu) &&
        !_playbackRecoveryStormDetected) {
      Log.d("末线路重试耗尽，重新签名再试一轮：${site.id}/$roomId");
      currentLineIndex = 0;
      mediaErrorRetryCount = 0;
      try {
        await setPlayer(refreshUrls: true);
      } catch (e, stackTrace) {
        Log.e("重签恢复失败：$e", stackTrace);
        _markPlaybackGivenUp(fromError: fromError, error: error ?? e.toString());
      }
      return;
    }
    _markPlaybackGivenUp(fromError: fromError, error: error);
  }

  void _markPlaybackGivenUp({bool fromError = false, String? error}) {
    liveStatus.value = false;
    if (fromError) {
      errorMsg.value = "播放失败";
      SmartDialog.showToast("播放失败:${error ?? ''}");
    }
  }

  bool get _shouldRefreshUrlsOnPlaybackRetry =>
      site.id == Constant.kHuya || site.id == Constant.kDouyu;

  @override
  void mediaEnd() async {
    if (mediaErrorRetryCount < 2 && !_playbackRecoveryStormDetected) {
      Log.d("播放结束，尝试第${mediaErrorRetryCount + 1}次刷新");
      if (mediaErrorRetryCount == 1) {
        await Future.delayed(const Duration(seconds: 1));
      }
      mediaErrorRetryCount += 1;
      await _recoverPlaybackOnce();
      return;
    }

    Log.d("播放结束");
    await _playbackRetriesExhausted();
  }

  int mediaErrorRetryCount = 0;
  @override
  void mediaError(String error) async {
    if (mediaErrorRetryCount < 2 && !_playbackRecoveryStormDetected) {
      Log.d("播放失败，尝试第${mediaErrorRetryCount + 1}次刷新");
      if (mediaErrorRetryCount == 1) {
        await Future.delayed(const Duration(seconds: 1));
      }
      mediaErrorRetryCount += 1;
      await _recoverPlaybackOnce();
      return;
    }

    await _playbackRetriesExhausted(fromError: true, error: error);
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
    if (site.id == Constant.kXiaohongshu) {
      SmartDialog.showToast("小红书为单场次直播，不支持常驻关注。\n下次观看请直接通过手机分享链接投送。");
      return;
    }
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
    var id = "${site.id}_$roomId";
    DBService.instance.deleteFollow(id);
    followed.value = false;
    EventBus.instance.emit(Constant.kUpdateFollow, id);
    SmartDialog.showToast("已取消关注");
  }

  void resetRoom(Site site, String roomId) async {
    FollowUserService.instance.isInLiveRoom = true;
    if (this.site == site && this.roomId == roomId) {
      return;
    }

    rxSite.value = site;
    rxRoomId.value = roomId;
    _douyuExpiryNoticeChecked = false;
    _bilibiliExpiryNoticeChecked = false;

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

  DateTime? _pausedAt;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    if (state == AppLifecycleState.paused) {
      Log.d("进入后台");
      _pausedAt = DateTime.now();
      //进入后台，关闭弹幕
      danmakuController?.clear();
      isBackground = true;
    } else if (state == AppLifecycleState.resumed) {
      Log.d("返回前台");
      isBackground = false;
      final pausedTime = _pausedAt;
      _pausedAt = null;

      final bgDuration = pausedTime != null
          ? DateTime.now().difference(pausedTime)
          : null;

      // 如果在后台挂起超过 15 秒（特别是在 Fire TV 等待机休眠设备上），
      // 底层网络拉流连接和硬件解码 Surface 极大概率已经超时断开，直接极速重新拉流与重连弹幕
      if (bgDuration != null &&
          bgDuration.inSeconds >= 15 &&
          liveStatus.value) {
        Log.w("从长时间后台恢复前台(${bgDuration.inSeconds}秒)，直接主动重刷新播放与弹幕");
        _refreshPlayerFromWatchdog();
        try {
          liveDanmaku.stop();
          liveDanmaku.start(detail.value?.danmakuData);
        } catch (e) {
          Log.w("恢复弹幕连接异常: $e");
        }
      }
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
    FollowUserService.instance.onExitLiveRoom();
    if (Get.isRegistered<HomeController>()) {
      Get.find<HomeController>().resetToTopAndFocusFirstRoom();
    }
    super.onClose();
  }
}
