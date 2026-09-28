import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:get/get.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:simple_live_tv_app/app/app_focus_node.dart';
import 'package:simple_live_tv_app/app/app_style.dart';
import 'package:simple_live_tv_app/modules/parse/parse_controller.dart';
import 'package:simple_live_tv_app/widgets/app_scaffold.dart';
import 'package:simple_live_tv_app/widgets/button/highlight_button.dart';

class ParsePage extends GetView<ParseController> {
  const ParsePage({super.key});

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      child: Column(
        children: [
          AppStyle.vGap24,
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              AppStyle.hGap48,
              HighlightButton(
                focusNode: AppFocusNode(),
                iconData: Icons.arrow_back,
                text: "返回",
                autofocus: true,
                onTap: () {
                  Get.back();
                },
              ),
              AppStyle.hGap32,
              Text(
                "链接解析",
                style: AppStyle.titleStyleWhite.copyWith(
                  fontSize: 36.w,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Spacer(),
            ],
          ),
          AppStyle.vGap24,
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 左侧：电视直接输入/粘贴解析
                Expanded(
                  flex: 3,
                  child: ListView(
                    padding: AppStyle.edgeInsetsH48,
                    children: [
                      Text(
                        "电视端输入",
                        style: AppStyle.titleStyleWhite.copyWith(
                          fontSize: 32.w,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      AppStyle.vGap16,
                      Container(
                        padding: AppStyle.edgeInsetsA12,
                        decoration: BoxDecoration(
                          color: Get.theme.cardColor,
                          borderRadius: AppStyle.radius16,
                        ),
                        child: TextField(
                          controller: controller.urlController,
                          focusNode: controller.inputFocusNode,
                          style: AppStyle.textStyleWhite,
                          minLines: 3,
                          maxLines: 4,
                          textInputAction: TextInputAction.go,
                          onSubmitted: (val) {
                            controller.parseAndPlay(val);
                          },
                          decoration: InputDecoration(
                            hintText:
                                "在此输入或粘贴直播间链接/分享文本（支持B站、斗鱼、虎牙、抖音）",
                            hintStyle: TextStyle(
                              color: Colors.white38,
                              fontSize: 26.w,
                            ),
                            border: InputBorder.none,
                            contentPadding: AppStyle.edgeInsetsA16,
                          ),
                        ),
                      ),
                      AppStyle.vGap24,
                      Row(
                        children: [
                          HighlightButton(
                            focusNode: controller.pasteBtnFocusNode,
                            iconData: Icons.paste,
                            text: "从剪贴板粘贴并播放",
                            onTap: controller.pasteFromClipboard,
                          ),
                          AppStyle.hGap24,
                          HighlightButton(
                            focusNode: controller.playBtnFocusNode,
                            iconData: Icons.play_arrow,
                            text: "解析并播放",
                            onTap: () {
                              controller.parseAndPlay(
                                  controller.urlController.text);
                            },
                          ),
                          AppStyle.hGap24,
                          HighlightButton(
                            focusNode: controller.clearBtnFocusNode,
                            iconData: Icons.clear,
                            text: "清空",
                            onTap: controller.clearInput,
                          ),
                        ],
                      ),
                      AppStyle.vGap32,
                      Container(
                        padding: AppStyle.edgeInsetsA24,
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.05),
                          borderRadius: AppStyle.radius16,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              "支持格式与特性说明：",
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 26.w,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            AppStyle.vGap12,
                            Text(
                              "• 哔哩哔哩：live.bilibili.com/xxx 或 b23.tv 短链\n"
                              "• 斗鱼直播：douyu.com/xxx 或 topic 专题页面\n"
                              "• 虎牙直播：huya.com/xxx 直播间链接\n"
                              "• 抖音直播：live.douyin.com/xxx 或 v.douyin.com 短链\n"
                              "• 智能容错：自动过滤从手机分享时附带的多余中文文案，短链自动重定向展开\n"
                              "• 防崩溃机制：跳转前校验房间合法性，避免进入异常链接导致白屏",
                              style: TextStyle(
                                color: Colors.white70,
                                fontSize: 24.w,
                                height: 1.6,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                // 右侧：手机局域网扫码快捷投送
                Expanded(
                  flex: 2,
                  child: Center(
                    child: Container(
                      margin: AppStyle.edgeInsetsH48,
                      padding: AppStyle.edgeInsetsA32,
                      decoration: BoxDecoration(
                        color: Get.theme.cardColor,
                        borderRadius: AppStyle.radius24,
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Text(
                            "手机扫码快捷投送",
                            style: AppStyle.titleStyleWhite.copyWith(
                              fontSize: 30.w,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          AppStyle.vGap12,
                          Text(
                            "手机与电视连接同一 WiFi，扫码即可直接粘贴链接投送播放",
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Colors.white60,
                              fontSize: 22.w,
                            ),
                          ),
                          AppStyle.vGap24,
                          Obx(
                            () => controller.lanPushUrl.value.isNotEmpty
                                ? QrImageView(
                                    data: controller.lanPushUrl.value,
                                    version: QrVersions.auto,
                                    backgroundColor: Colors.white,
                                    padding: AppStyle.edgeInsetsA16,
                                    size: 320.w,
                                  )
                                : Container(
                                    width: 320.w,
                                    height: 320.w,
                                    alignment: Alignment.center,
                                    color: Colors.black26,
                                    child: Text(
                                      "局域网服务启动中...",
                                      style: AppStyle.textStyleWhite,
                                    ),
                                  ),
                          ),
                          AppStyle.vGap16,
                          Obx(
                            () => Text(
                              controller.lanPushUrl.value,
                              style: TextStyle(
                                color: Colors.white54,
                                fontSize: 22.w,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
