import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:simple_live_tv_app/app/controller/base_controller.dart';
import 'package:simple_live_tv_app/app/log.dart';
import 'package:simple_live_tv_app/routes/route_path.dart';
import 'package:simple_live_tv_app/services/follow_user_service.dart';

class HomeController extends BaseController {
  var datetime = "00:00".obs;
  final ScrollController scrollController = ScrollController();

  @override
  void onInit() {
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

  /// 方案1：退出直播间时静默无感归顶，并将焦点落在第一个直播间卡片上
  void resetToTopAndFocusFirstRoom() {
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
