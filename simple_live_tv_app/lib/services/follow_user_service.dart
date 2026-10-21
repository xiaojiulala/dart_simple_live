import 'dart:async';
import 'dart:collection';

import 'package:get/get.dart';
import 'package:simple_live_tv_app/app/constant.dart';
import 'package:simple_live_tv_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_tv_app/app/controller/base_controller.dart';
import 'package:simple_live_tv_app/app/event_bus.dart';
import 'package:simple_live_tv_app/app/log.dart';
import 'package:simple_live_tv_app/app/sites.dart';
import 'package:simple_live_tv_app/app/utils.dart';
import 'package:simple_live_tv_app/models/db/follow_user.dart';
import 'package:simple_live_tv_app/services/db_service.dart';

class FollowUserService extends BasePageController<FollowUser> {
  static const Duration updateStatusCooldown = Duration(seconds: 30);
  static FollowUserService get instance => Get.find<FollowUserService>();
  StreamSubscription<dynamic>? subscription;

  RxList<FollowUser> allList = RxList<FollowUser>();
  RxList<FollowUser> livingList = RxList<FollowUser>();
  Timer? updateTimer;
  bool needUpdate = true;
  int _updateGeneration = 0;
  DateTime? _lastUpdateStatusStartedAt;
  DateTime? _lastRefreshInvokeAt;
  bool _forceNextStatusRefresh = false;

  /// 是否当前处于直播间播放中（处于直播间时挂起定时刷新，退出后再按需刷新）
  bool isInLiveRoom = false;

  /// 在直播间内期间是否有推迟的刷新请求
  bool pendingRefresh = false;

  /// 刷新状态指示：0=空闲隐藏, 1=刷新中, 2=刷新完毕
  var updateState = 0.obs;
  var refreshStatusText = "".obs;
  Timer? _completeNoticeTimer;

  FollowUserService() {
    pageSize = 60;
  }
  @override
  void onInit() {
    subscription = EventBus.instance.listen(Constant.kUpdateFollow, (p0) {
      needUpdate = false;
      allList.assignAll(_sortFollowUsers(DBService.instance.getFollowList()));
      sortList();
      startUpdateStatus(allList.toList(), force: true);
    });

    if (list.isEmpty) {
      refreshData();
    }
    initTimer();
    super.onInit();
  }

  void initTimer() {
    if (AppSettingsController.instance.autoUpdateFollowEnable.value) {
      updateTimer?.cancel();
      updateTimer = Timer.periodic(
        Duration(
          minutes:
              AppSettingsController.instance.autoUpdateFollowDuration.value,
        ),
        (timer) {
          Log.logPrint("Update Follow Timer triggered");
          // 看直播时不刷新，避免后台并发请求导致前台播放丢帧卡顿
          if (isInLiveRoom) {
            Log.logPrint("当前处于直播间播放中，推迟关注状态刷新");
            pendingRefresh = true;
            return;
          }
          refreshData(forceStatus: false);
        },
      );
    } else {
      updateTimer?.cancel();
    }
  }

  /// 退出直播间时调用：恢复挂起的刷新检查
  void onExitLiveRoom() {
    isInLiveRoom = false;
    final now = DateTime.now();
    final duration = Duration(
      minutes:
          AppSettingsController.instance.autoUpdateFollowDuration.value,
    );
    final elapsed = _lastUpdateStatusStartedAt != null
        ? now.difference(_lastUpdateStatusStartedAt!)
        : null;

    Log.logPrint(
      "退出直播间：pendingRefresh=$pendingRefresh, 距上次刷新=${elapsed?.inSeconds ?? -1}秒, 设定周期=${duration.inSeconds}秒",
    );

    // 如果看播期间定时器到达过（pendingRefresh），或距上次刷新已达到设定周期（如10分钟），才执行刷新
    if (pendingRefresh || (elapsed != null && elapsed >= duration)) {
      pendingRefresh = false;
      Log.logPrint("退出直播间触发待处理的刷新任务");
      refreshData(forceStatus: false);
    } else {
      Log.logPrint("退出直播间未达设定周期，跳过网络刷新");
    }
  }

  var updating = false.obs;

  @override
  Future refreshData({bool forceStatus = true}) async {
    final now = DateTime.now();
    final lastRefreshAt = _lastRefreshInvokeAt;
    if (lastRefreshAt != null &&
        now.difference(lastRefreshAt) < BasePageController.refreshCooldown) {
      return;
    }
    _lastRefreshInvokeAt = now;
    _forceNextStatusRefresh = forceStatus;

    if (allList.isEmpty) {
      allList.assignAll(_sortFollowUsers(DBService.instance.getFollowList()));
      updateLivingList();
      list.assignAll(allList.take(pageSize));
    }

    // 原地双缓冲更新，绝不清空 list.value = []，彻底避免界面黑屏闪烁
    await startUpdateStatus(allList.toList(), force: forceStatus);
  }

  @override
  Future<List<FollowUser>> getData(int page, int pageSize) async {
    if (page == 1) {
      if (allList.isEmpty) {
        allList.assignAll(_sortFollowUsers(DBService.instance.getFollowList()));
        updateLivingList();
      }
      if (needUpdate) {
        unawaited(startUpdateStatus(
          allList.toList(),
          force: _forceNextStatusRefresh,
        ));
      }
      _forceNextStatusRefresh = false;
      needUpdate = true;
      if (allList.isEmpty) {
        updating.value = false;
        updateState.value = 0;
      }
    }
    final start = (page - 1) * pageSize;
    if (start >= allList.length) {
      return [];
    }
    final end = (start + pageSize).clamp(0, allList.length).toInt();
    return allList.sublist(start, end);
  }

  void sortList() {
    allList.assignAll(_sortFollowUsers(allList));
    final preferredCount = list.isEmpty ? pageSize : list.length;
    final visibleCount = preferredCount.clamp(0, allList.length).toInt();
    list.assignAll(allList.take(visibleCount));
    currentPage = visibleCount < allList.length
        ? (visibleCount ~/ pageSize) + 1
        : currentPage;
    canLoadMore.value = visibleCount < allList.length;
    updateLivingList();
  }

  List<FollowUser> _sortFollowUsers(Iterable<FollowUser> items) {
    return items.toList()
      ..sort((a, b) => b.liveStatus.value.compareTo(a.liveStatus.value));
  }

  void updateLivingList() {
    livingList.assignAll(allList.where((x) => x.liveStatus.value == 2));
  }

  /// 获取最优并发数
  /// 后台按关注规模自动控制，不再读取用户配置，避免超大关注列表刷崩。
  int _getConcurrency(int total) {
    if (total <= 0) {
      return 1;
    }
    if (total <= 300) {
      return total < 48 ? total : 48;
    }
    if (total <= 1000) {
      return 32;
    }
    if (total <= 3000) {
      return 20;
    }
    if (total <= 5000) {
      return 12;
    }
    return 8;
  }

  /// 按平台交错排列，避免单一平台阻塞
  List<FollowUser> _interleaveByPlatform(List<FollowUser> list) {
    var grouped = <String, Queue<FollowUser>>{};
    for (var item in list) {
      grouped.putIfAbsent(item.siteId, () => Queue<FollowUser>()).add(item);
    }

    var result = <FollowUser>[];
    while (grouped.values.any((queue) => queue.isNotEmpty)) {
      for (var queue in grouped.values) {
        if (queue.isNotEmpty) {
          result.add(queue.removeFirst());
        }
      }
    }

    return result;
  }

  Future<void> startUpdateStatus(
    List<FollowUser> followList, {
    bool force = false,
  }) async {
    final now = DateTime.now();
    final lastStartedAt = _lastUpdateStatusStartedAt;
    if (!force &&
        lastStartedAt != null &&
        now.difference(lastStartedAt) < updateStatusCooldown) {
      Log.logPrint("关注状态刷新过于频繁，已跳过本次网络刷新");
      updating.value = false;
      updateState.value = 0;
      sortList();
      return;
    }
    _lastUpdateStatusStartedAt = now;
    final generation = ++_updateGeneration;
    if (updating.value) {
      Log.logPrint("已有关注状态刷新任务，取消旧任务并启动新任务");
    }
    updating.value = true;
    updateState.value = 1;
    refreshStatusText.value = "刷新中...";
    _completeNoticeTimer?.cancel();

    if (followList.isEmpty) {
      updating.value = false;
      updateState.value = 0;
      return;
    }

    var concurrency = _getConcurrency(followList.length);

    Log.logPrint(
      "开始更新关注状态，并发数: $concurrency，总数: ${followList.length}",
    );

    var taskQueue = Queue<FollowUser>.from(_interleaveByPlatform(followList));
    // 双缓冲状态缓存：收集所有主播最新开播状态，不立即修改 UI 项，避免卡片逐个闪烁抽搐
    final statusBuffer = <String, int>{};

    Future<void> worker() async {
      while (taskQueue.isNotEmpty) {
        if (generation != _updateGeneration) {
          return;
        }
        var item = taskQueue.removeFirst();
        try {
          var site = Sites.allSites[item.siteId]!;
          final isLiving =
              await site.liveSite.getLiveStatus(roomId: item.roomId);
          if (generation != _updateGeneration) {
            return;
          }
          statusBuffer[item.id] = isLiving ? 2 : 1;
        } catch (e) {
          if (generation != _updateGeneration) {
            return;
          }
          Log.logPrint("获取主播[${item.userName}]状态异常: $e");
        }
      }
    }

    var workers = <Future>[];
    for (var i = 0; i < concurrency; i++) {
      workers.add(worker());
    }
    await Future.wait(workers);

    if (generation != _updateGeneration) {
      return;
    }

    // 双缓冲应用：所有并发请求完成后，一次性原子更新状态值
    for (var item in allList) {
      if (statusBuffer.containsKey(item.id)) {
        item.liveStatus.value = statusBuffer[item.id]!;
      }
    }

    // 一次性原子排序并更新可见列表，杜绝分批洗牌跳位
    sortList();
    updating.value = false;

    // 显示“刷新完毕”反馈，3秒后自动淡出消失
    updateState.value = 2;
    refreshStatusText.value = livingList.isEmpty
        ? "刷新完毕"
        : "刷新完毕 (${livingList.length}人开播)";
    _completeNoticeTimer?.cancel();
    _completeNoticeTimer = Timer(const Duration(seconds: 3), () {
      updateState.value = 0;
    });

    Log.logPrint("关注状态更新完成（双缓冲原子就位）");
  }

  Future updateLiveStatus(FollowUser item, {int? generation}) async {
    try {
      var site = Sites.allSites[item.siteId]!;
      final isLiving = await site.liveSite.getLiveStatus(roomId: item.roomId);
      if (generation != null && generation != _updateGeneration) {
        return;
      }
      item.liveStatus.value = isLiving ? 2 : 1;
    } catch (e) {
      if (generation != null && generation != _updateGeneration) {
        return;
      }
      Log.logPrint(e);
    }
  }

  void removeItem(FollowUser item, {bool refresh = true}) async {
    var result =
        await Utils.showAlertDialog("确定要取消关注${item.userName}吗?", title: "取消关注");
    if (!result) {
      return;
    }
    await DBService.instance.followBox.delete(item.id);
    if (refresh) {
      refreshData();
    } else {
      allList.remove(item);
      list.remove(item);
      livingList.remove(item);
    }
  }

  @override
  void onClose() {
    _updateGeneration++;
    updating.value = false;
    updateState.value = 0;
    _completeNoticeTimer?.cancel();
    updateTimer?.cancel();
    subscription?.cancel();

    super.onClose();
  }
}
