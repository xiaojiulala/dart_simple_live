import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:simple_live_tv_app/app/controller/base_controller.dart';
import 'package:simple_live_tv_app/app/log.dart';
import 'package:simple_live_tv_app/routes/route_path.dart';
import 'package:simple_live_tv_app/services/follow_user_service.dart';
import 'package:simple_live_tv_app/services/sync_service.dart';

class HomeController extends BaseController with WidgetsBindingObserver {
  var datetime = "00:00".obs;
  final ScrollController scrollController = ScrollController();
  DateTime? _pausedAt;

  @override
  void onInit() {
    WidgetsBinding.instance.addObserver(this);
    initTimer();
    super.onInit();
  }

  void initTimer() {
    Timer.periodic(const Duration(seconds: 1), (timer) {
      var now = DateTime.now();
      datetime.value =
          "${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}";
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.paused) {
      _pausedAt = DateTime.now();
      Log.d("HomeController 进入后台: $_pausedAt");
    } else if (state == AppLifecycleState.resumed) {
      final pausedTime = _pausedAt;
      _pausedAt = null;
      final now = DateTime.now();
      final bgDuration =
          pausedTime != null ? now.difference(pausedTime) : null;
      Log.d("HomeController 返回前台，后台挂起时长: ${bgDuration?.inSeconds ?? -1}秒");

      // 1. 立即校准时钟显示
      datetime.value =
          "${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}";

      // 2. 挂起超过5分钟或未记录时长，触发关注状态自愈自检
      if (bgDuration == null || bgDuration.inMinutes >= 5) {
        FollowUserService.instance.onAppResumeCheck();
      }

      // 3. 焦点自愈：如果从系统桌面唤醒导致焦点脱落，自动恢复至首项
      _checkAndRestoreFocus();

      // 4. 刷新局域网服务 IP
      SyncService.instance.updateLocalIP();
    }
  }

  void _checkAndRestoreFocus() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      try {
        final currentFocus = FocusManager.instance.primaryFocus;
        if (currentFocus == null ||
            currentFocus == FocusManager.instance.rootScope ||
            !currentFocus.hasFocus) {
          if (FollowUserService.instance.list.isNotEmpty) {
            FollowUserService.instance.list.first.focusNode.requestFocus();
          }
        }
      } catch (e) {
        Log.logPrint("恢复前台焦点自愈异常: $e");
      }
    });
  }

  /// 退出直播间时静默无感归顶，并将焦点落在第一个直播间卡片上
  void resetToTopAndFocusFirstRoom() {
    // 强制清空之前所有卡片的残留焦点，彻底杜绝被卸载后的幽灵假光标
    for (var item in FollowUserService.instance.allList) {
      if (item.focusNode.isFoucsed.value || item.focusNode.hasFocus) {
        item.focusNode.forceUnfocus();
      }
    }

    try {
      if (scrollController.hasClients) {
        scrollController.jumpTo(0);
      }
    } catch (e) {
      Log.logPrint("scrollController jumpTo(0) error: $e");
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      try {
        if (scrollController.hasClients) {
          scrollController.jumpTo(0);
        }
        if (FollowUserService.instance.list.isNotEmpty) {
          FollowUserService.instance.list.first.focusNode.requestFocus();
        }
      } catch (e) {
        Log.logPrint("firstRoom focusNode requestFocus error: $e");
      }
    });
  }

  @override
  void onClose() {
    WidgetsBinding.instance.removeObserver(this);
    scrollController.dispose();
    super.onClose();
  }

  void toSync() {
    Get.toNamed(RoutePath.kSync);
  }

  void toFollow() {
    Get.toNamed(RoutePath.kFollow);
  }

  void toSettings() {
    Get.toNamed(RoutePath.kSettings);
  }

  void toHistory() {
    Get.toNamed(RoutePath.kHistory);
  }

  void toHotLive() {
    Get.toNamed(RoutePath.kHotLive);
  }

  void toParseLink() {
    Get.toNamed(RoutePath.kParse);
  }

  void toSearchRoom(String keyword) {
    Get.toNamed(RoutePath.kSearchRoom, arguments: keyword);
  }

  void toSearchAnchor(String keyword) {
    Get.toNamed(RoutePath.kSearchAnchor, arguments: keyword);
  }

  void toCategory() {
    Get.toNamed(RoutePath.kCategory);
  }
}
