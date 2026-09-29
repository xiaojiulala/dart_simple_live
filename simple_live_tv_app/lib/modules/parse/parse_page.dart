import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:get/get.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:simple_live_tv_app/app/app_style.dart';
import 'package:simple_live_tv_app/modules/parse/parse_controller.dart';
import 'package:simple_live_tv_app/services/sync_service.dart';
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
                focusNode: controller.backBtnFocusNode,
                iconData: Icons.arrow_back,
                text: "返回",
                autofocus: true,
                onTap: () {
                  Get.back();
                },
              ),
              AppStyle.hGap32,
              Text(
                "手机投送 / 控制台",
                style: AppStyle.titleStyleWhite.copyWith(
                  fontSize: 36.w,
                  fontWeight: FontWeight.bold,
                ),
              ),
              AppStyle.hGap24,
              Obx(() {
                final running = SyncService.instance.httpRunning.value;
                return Container(
                  padding:
                      EdgeInsets.symmetric(horizontal: 16.w, vertical: 6.w),
                  decoration: BoxDecoration(
                    color: running
                        ? Colors.green.withOpacity(0.2)
                        : Colors.red.withOpacity(0.2),
                    borderRadius: AppStyle.radius12,
                    border: Border.all(
                      color: running ? Colors.green : Colors.red,
                      width: 1,
                    ),
                  ),
                  child: Text(
                    running ? "服务已就绪" : "服务启动中",
                    style: TextStyle(
                      color: running ? Colors.greenAccent : Colors.redAccent,
                      fontSize: 20.w,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                );
              }),
              const Spacer(),
            ],
          ),
          AppStyle.vGap24,
          Expanded(
            child: Padding(
              padding: AppStyle.edgeInsetsH48,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 左侧：二维码与访问网址
                  Expanded(
                    flex: 5,
                    child: Container(
                      padding: AppStyle.edgeInsetsA32,
                      decoration: BoxDecoration(
                        color: Get.theme.cardColor,
                        borderRadius: AppStyle.radius24,
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            "手机扫码直达控制台",
                            style: AppStyle.titleStyleWhite.copyWith(
                              fontSize: 30.w,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          AppStyle.vGap12,
                          Text(
                            "手机与电视连接同一 Wi-Fi，扫码即可直接粘贴投送",
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Colors.white60,
                              fontSize: 22.w,
                            ),
                          ),
                          AppStyle.vGap24,
                          Obx(() {
                            final url = controller.lanUrl.value;
                            return url.isNotEmpty
                                ? QrImageView(
                                    data: url,
                                    version: QrVersions.auto,
                                    backgroundColor: Colors.white,
                                    padding: AppStyle.edgeInsetsA16,
                                    size: 320.w,
                                  )
                                : Container(
                                    width: 320.w,
                                    height: 320.w,
                                    alignment: Alignment.center,
                                    decoration: BoxDecoration(
                                      color: Colors.black26,
                                      borderRadius: AppStyle.radius16,
                                    ),
                                    child: const CircularProgressIndicator(),
                                  );
                          }),
                          AppStyle.vGap24,
                          Text(
                            "浏览器访问地址：",
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 22.w,
                            ),
                          ),
                          AppStyle.vGap8,
                          Container(
                            padding: EdgeInsets.symmetric(
                                horizontal: 24.w, vertical: 10.w),
                            decoration: BoxDecoration(
                              color: Colors.black38,
                              borderRadius: AppStyle.radius12,
                              border: Border.all(
                                color: Colors.white12,
                              ),
                            ),
                            child: Obx(
                              () => SelectableText(
                                controller.lanUrl.value.isNotEmpty
                                    ? controller.lanUrl.value
                                    : "获取内网 IP 中...",
                                style: TextStyle(
                                  color: Colors.amberAccent,
                                  fontSize: 26.w,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 1,
                                ),
                              ),
                            ),
                          ),
                          AppStyle.vGap24,
                          HighlightButton(
                            focusNode: controller.clipboardBtnFocusNode,
                            iconData: Icons.paste,
                            text: "读取电视剪贴板播放",
                            onTap: controller.pasteFromClipboard,
                          ),
                        ],
                      ),
                    ),
                  ),
                  AppStyle.hGap32,
                  // 右侧：使用指南与支持平台
                  Expanded(
                    flex: 6,
                    child: Container(
                      padding: AppStyle.edgeInsetsA32,
                      decoration: BoxDecoration(
                        color: Get.theme.cardColor,
                        borderRadius: AppStyle.radius24,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            "投送与管理指南",
                            style: AppStyle.titleStyleWhite.copyWith(
                              fontSize: 30.w,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          AppStyle.vGap24,
                          _buildStepItem(
                            step: "1",
                            icon: Icons.wifi,
                            title: "连接相同局域网",
                            desc: "确保手机或电脑与本电视连接在同一个 Wi-Fi 或路由器网络下。",
                          ),
                          AppStyle.vGap20,
                          _buildStepItem(
                            step: "2",
                            icon: Icons.qr_code_scanner,
                            title: "扫码打开控制台",
                            desc: "使用微信、手机浏览器扫描左侧二维码，无需下载任何额外 App 即可秒级开启。",
                          ),
                          AppStyle.vGap20,
                          _buildStepItem(
                            step: "3",
                            icon: Icons.send_rounded,
                            title: "粘贴链接一键投送",
                            desc:
                                "在手机中复制直播分享文本或链接，在控制台点击“立即投送”，电视端将自动解析并无缝切台播放！",
                          ),
                          AppStyle.vGap20,
                          _buildStepItem(
                            step: "4",
                            icon: Icons.favorite,
                            title: "关注管理与备份",
                            desc:
                                "在网页端还可直接查看、一键导出或批量导入主播关注列表，免去遥控器搜索之苦。",
                          ),
                          const Spacer(),
                          Container(
                            padding: AppStyle.edgeInsetsA16,
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.04),
                              borderRadius: AppStyle.radius12,
                            ),
                            child: Row(
                              children: [
                                Text(
                                  "支持平台：",
                                  style: TextStyle(
                                    color: Colors.white70,
                                    fontSize: 22.w,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                AppStyle.hGap12,
                                _buildPlatformTag(
                                    "哔哩哔哩", const Color(0xFF00AEEC)),
                                AppStyle.hGap12,
                                _buildPlatformTag(
                                    "斗鱼直播", const Color(0xFFFF5D23)),
                                AppStyle.hGap12,
                                _buildPlatformTag(
                                    "虎牙直播", const Color(0xFFFFAA00),
                                    textColor: Colors.black),
                                AppStyle.hGap12,
                                _buildPlatformTag(
                                    "抖音直播", const Color(0xFFFE2C55)),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          AppStyle.vGap32,
        ],
      ),
    );
  }

  Widget _buildStepItem({
    required String step,
    required IconData icon,
    required String title,
    required String desc,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 44.w,
          height: 44.w,
          decoration: BoxDecoration(
            color: Get.theme.primaryColor.withOpacity(0.2),
            borderRadius: BorderRadius.circular(22.w),
          ),
          child: Center(
            child: Icon(
              icon,
              color: Get.theme.primaryColor,
              size: 24.w,
            ),
          ),
        ),
        AppStyle.hGap16,
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 24.w,
                  fontWeight: FontWeight.bold,
                ),
              ),
              AppStyle.vGap6,
              Text(
                desc,
                style: TextStyle(
                  color: Colors.white60,
                  fontSize: 20.w,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPlatformTag(String name, Color color,
      {Color textColor = Colors.white}) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 6.w),
      decoration: BoxDecoration(
        color: color.withOpacity(0.2),
        borderRadius: AppStyle.radius8,
        border: Border.all(color: color.withOpacity(0.5)),
      ),
      child: Text(
        name,
        style: TextStyle(
          color: color,
          fontSize: 20.w,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}
