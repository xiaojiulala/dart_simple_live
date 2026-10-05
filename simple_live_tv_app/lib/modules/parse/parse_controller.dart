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
  final AppFocusNode backBtnFocusNode = AppFocusNode();
  final AppFocusNode clipboardBtnFocusNode = AppFocusNode();

  final isParsing = false.obs;
  final lanUrl = "".obs;

  @override
  void onInit() {
    super.onInit();
    _updateLanUrl();
    ever(SyncService.instance.ipAddress, (_) => _updateLanUrl());
  }

  void _updateLanUrl() {
    final rawIp = SyncService.instance.ipAddress.value;
    final ip = rawIp.split(';').first.trim();
    if (ip.isNotEmpty) {
      lanUrl.value = "http://$ip:${SyncService.httpPort}";
    } else {
      lanUrl.value = "";
    }
  }

  Future<void> pasteFromClipboard() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text?.trim() ?? "";
      if (text.isEmpty) {
        SmartDialog.showToast("电视剪贴板内容为空");
        return;
      }
      SmartDialog.showToast("已读取电视剪贴板内容");
      await parseAndPlay(text);
    } catch (e) {
      SmartDialog.showToast("读取剪贴板失败：$e");
    }
  }

  Future<bool> parseAndPlay(String rawText) async {
    final text = rawText.trim();
    if (text.isEmpty) {
      SmartDialog.showToast("链接内容为空");
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
        SmartDialog.showToast("无法识别该直播链接\n支持哔哩哔哩/斗鱼/虎牙/抖音/小红书");
        return false;
      }

      final site = Sites.allSites[parsed.siteId];
      if (site == null) {
        SmartDialog.dismiss(status: SmartStatus.loading);
        SmartDialog.showToast("不支持的直播平台：${parsed.siteId}");
        return false;
      }

      // 预检验证房间是否真实可访问
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
      SmartDialog.showToast("正在进入 ${site.name} 直播间...");
      AppNavigator.toLiveRoomDetail(site: site, roomId: parsed.roomId);
      return true;
    } catch (e) {
      SmartDialog.dismiss(status: SmartStatus.loading);
      SmartDialog.showToast("解析出错：$e");
      return false;
    } finally {
      isParsing.value = false;
    }
  }
}
