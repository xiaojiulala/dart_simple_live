import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_tv_app/app/app_focus_node.dart';
import 'package:simple_live_tv_app/app/controller/base_controller.dart';
import 'package:simple_live_tv_app/app/utils.dart';
import 'package:simple_live_tv_app/routes/app_navigation.dart';
import 'package:simple_live_tv_app/services/bilibili_account_service.dart';
import 'package:simple_live_tv_app/services/douyu_account_service.dart';

class SettingsController extends BaseController
    with GetTickerProviderStateMixin {
  late TabController tabController;
  var tabIndex = 0.obs;

  SettingsController() {
    tabController = TabController(length: 6, vsync: this);
    tabController.animation?.addListener(() {
      var currentIndex = (tabController.animation?.value ?? 0).round();
      if (tabIndex.value == currentIndex) {
        return;
      }
      tabIndex.value = currentIndex;
      if (tabIndex.value == 0) {
        hardwareDecodeFocusNode.requestFocus();
      }
      if (tabIndex.value == 1) {
        danmakuFoucsNode.requestFocus();
      }
      if (tabIndex.value == 2) {
        autoUpdateFollowEnableFocusNode.requestFocus();
      }
      if (tabIndex.value == 3) {
        multiRoomGapFocusNode.requestFocus();
      }
      if (tabIndex.value == 4) {
        bilibiliFoucsNode.requestFocus();
      }
      if (tabIndex.value == 5) {
        versionFocusNode.requestFocus();
      }
    });
  }
  var hardwareDecodeFocusNode = AppFocusNode()..isFoucsed.value = true;
  var compatibleModeFocusNode = AppFocusNode();
  var scaleFoucsNode = AppFocusNode();
  var defaultQualityFocusNode = AppFocusNode();
  var danmakuFoucsNode = AppFocusNode();
  var danmakuSizeFoucsNode = AppFocusNode();
  var danmakuEmojiFoucsNode = AppFocusNode();
  var danmakuSpeedFoucsNode = AppFocusNode();
  var danmakuAreaFoucsNode = AppFocusNode();
  var danmakuOpacityFoucsNode = AppFocusNode();
  var danmakuStorkeFoucsNode = AppFocusNode();
  var liveEventFlowFoucsNode = AppFocusNode();
  var liveEventFlowOverlayFoucsNode = AppFocusNode();
  var liveEventFlowWindowFoucsNode = AppFocusNode();
  var liveEventFlowDisplayFoucsNode = AppFocusNode();
  var liveEventFlowMinCountFoucsNode = AppFocusNode();
  var danmakuDedupeFoucsNode = AppFocusNode();
  var danmakuDedupeModeFoucsNode = AppFocusNode();
  var danmakuDedupeWindowFoucsNode = AppFocusNode();
  var danmakuDedupeStepFoucsNode = AppFocusNode();

  var autoUpdateFollowEnableFocusNode = AppFocusNode();
  var autoUpdateFollowDurationFocusNode = AppFocusNode();
  var multiRoomGapFocusNode = AppFocusNode();

  var bilibiliFoucsNode = AppFocusNode();
  var douyuFocusNode = AppFocusNode();
  var versionFocusNode = AppFocusNode();

  void bilibiliTap() async {
    if (BiliBiliAccountService.instance.logined.value) {
      var result = await Utils.showAlertDialog("确定要退出哔哩哔哩账号吗？", title: "退出登录");
      if (result) {
        BiliBiliAccountService.instance.logout();
      }
    } else {
      AppNavigator.toBiliBiliLogin();
    }
  }

  void douyuTap() async {
    if (DouyuAccountService.instance.logined.value) {
      var result = await Utils.showAlertDialog("确定要退出斗鱼账号吗？", title: "退出登录");
      if (result) {
        DouyuAccountService.instance.logout();
      }
    } else {
      AppNavigator.toDouyuLogin();
    }
  }
}
