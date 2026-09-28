import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_tv_app/app/app_focus_node.dart';
import 'package:simple_live_tv_app/app/sites.dart';
import 'package:simple_live_tv_app/modules/parse/live_url_parser.dart';
import 'package:simple_live_tv_app/routes/app_navigation.dart';
import 'package:simple_live_tv_app/services/sync_service.dart';

class ParseController extends GetxController {
  final TextEditingController urlController = TextEditingController();

  final AppFocusNode inputFocusNode = AppFocusNode();
  final AppFocusNode pasteBtnFocusNode = AppFocusNode();
  final AppFocusNode playBtnFocusNode = AppFocusNode();
  final AppFocusNode clearBtnFocusNode = AppFocusNode();

  final isParsing = false.obs;
  final lanPushUrl = "".obs;

  @override
  void onInit() {
    super.onInit();
    _updateLanUrl();
  }

  void _updateLanUrl() {
    final ip = SyncService.instance.ipAddress.value;
    if (ip.isNotEmpty) {
      lanPushUrl.value = "http://$ip:${SyncService.httpPort}/parse";
    } else {
      lanPushUrl.value = "";
    }
  }

  Future<void> pasteFromClipboard() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text?.trim() ?? "";
      if (text.isEmpty) {
        SmartDialog.showToast("剪贴板内容为空");
        return;
      }
      urlController.text = text;
      SmartDialog.showToast("已粘贴剪贴板内容");
      await parseAndPlay(text);
    } catch (e) {
      SmartDialog.showToast("读取剪贴板失败：$e");
    }
  }

  void clearInput() {
    urlController.clear();
  }

  Future<bool> parseAndPlay(String rawText) async {
    final text = rawText.trim();
    if (text.isEmpty) {
      SmartDialog.showToast("请输入或粘贴直播间链接");
      return false;
    }

    if (isParsing.value) {
      return false;
    }

    isParsing.value = true;
    SmartDialog.showLoading(msg: "正在解析链接...");

    try {
      final parsed = await LiveUrlParser.parseFromText(text);
      if (parsed == null || parsed.roomId.isEmpty) {
        SmartDialog.dismiss(status: SmartStatus.loading);
        SmartDialog.showToast("无法识别该直播链接\n支持哔哩哔哩/斗鱼/虎牙/抖音");
        return false;
      }

      final site = Sites.allSites[parsed.siteId];
      if (site == null) {
        SmartDialog.dismiss(status: SmartStatus.loading);
        SmartDialog.showToast("不支持的直播平台：${parsed.siteId}");
        return false;
      }

      // 预检验证房间是否真实可访问，绝不盲目跳入未经验证的房间导致白屏崩溃
      SmartDialog.showLoading(msg: "正在连接 ${site.name} 直播间...");
      try {
        final roomDetail =
            await site.liveSite.getRoomDetail(roomId: parsed.roomId);
        if (roomDetail.roomId.isEmpty) {
          throw "返回房间号为空";
        }
      } catch (e) {
        SmartDialog.dismiss(status: SmartStatus.loading);
        SmartDialog.showToast("获取 ${site.name} 直播间信息失败：$e");
        return false;
      }

      SmartDialog.dismiss(status: SmartStatus.loading);
      AppNavigator.toLiveRoomDetail(site: site, roomId: parsed.roomId);
      return true;
    } catch (e) {
      SmartDialog.dismiss(status: SmartStatus.loading);
      SmartDialog.showToast("解析链接发生异常：$e");
      return false;
    } finally {
      isParsing.value = false;
    }
  }

  @override
  void onClose() {
    urlController.dispose();
    inputFocusNode.dispose();
    pasteBtnFocusNode.dispose();
    playBtnFocusNode.dispose();
    clearBtnFocusNode.dispose();
    super.onClose();
  }
}
