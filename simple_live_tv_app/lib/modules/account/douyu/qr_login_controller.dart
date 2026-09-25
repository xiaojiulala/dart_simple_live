import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_tv_app/app/log.dart';
import 'package:simple_live_tv_app/modules/account/bilibili/qr_login_controller.dart'
    show QRStatus;
import 'package:simple_live_tv_app/requests/http_client.dart';
import 'package:simple_live_tv_app/services/douyu_account_service.dart';

class DouyuQRLoginController extends GetxController {
  @override
  void onInit() {
    loadQRCode();
    super.onInit();
  }

  Timer? timer;

  var qrcodeUrl = "".obs;
  var qrcodeKey = "";

  Rx<QRStatus> qrStatus = QRStatus.loading.obs;

  void loadQRCode() async {
    try {
      timer?.cancel();
      qrStatus.value = QRStatus.loading;

      var result = await HttpClient.instance.postJson(
        "https://passport.douyu.com/scan/generateCode",
        data: {
          "client_id": 1,
          "isMultiAccount": 0,
        },
        header: {
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
          'Referer': 'https://passport.douyu.com/',
          'Origin': 'https://passport.douyu.com',
        },
        formUrlEncoded: true,
      );

      if (result is! Map || result["error"] != 0) {
        throw result["msg"] ?? "获取斗鱼登录二维码失败";
      }

      qrcodeKey = result["data"]["code"].toString();
      qrcodeUrl.value = result["data"]["url"].toString();
      qrStatus.value = QRStatus.unscanned;
      startPoll();
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast(e.toString());
      qrStatus.value = QRStatus.failed;
    }
  }

  void startPoll() {
    timer?.cancel();
    timer = Timer.periodic(
      const Duration(seconds: 2),
      (timer) {
        pollQRStatus();
      },
    );
  }

  void pollQRStatus() async {
    if (qrcodeKey.isEmpty) {
      return;
    }
    try {
      var t = DateTime.now().millisecondsSinceEpoch;
      var response = await HttpClient.instance.getJson(
        "https://passport.douyu.com/japi/scan/auth",
        queryParameters: {
          "time": t,
          "code": qrcodeKey,
        },
        header: {
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
          'Referer': 'https://passport.douyu.com/',
          'Origin': 'https://passport.douyu.com',
        },
      );

      if (response is! Map) {
        return;
      }

      var err = response["error"];
      if (err == 0) {
        // 扫码确认成功
        timer?.cancel();
        var authUrl = response["data"]?["url"]?.toString() ?? "";
        if (authUrl.isNotEmpty) {
          var cookies = <String>[];
          void extractCookies(Response resp) {
            resp.headers["set-cookie"]?.forEach((element) {
              var cookie = element.split(";")[0].trim();
              if (cookie.isNotEmpty) {
                cookies.add(cookie);
              }
            });
          }

          // 1. 先尝试官方标准的 JSONP 回调方式
          try {
            var jsonpUrl = authUrl;
            if (!jsonpUrl.contains("callback=")) {
              jsonpUrl += (jsonpUrl.contains("?") ? "&" : "?") +
                  "callback=appClient_json_callback";
            }
            var resp = await HttpClient.instance.dio.get(
              jsonpUrl,
              options: Options(
                responseType: ResponseType.plain,
                headers: {
                  'User-Agent':
                      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
                  'Referer': 'https://passport.douyu.com/',
                },
              ),
            );
            extractCookies(resp);
          } catch (_) {}

          // 2. 如果 JSONP 未获取到 cookie，使用手动重定向跟踪（followRedirects: false）访问原始 authUrl
          if (cookies.isEmpty) {
            String currentUrl = authUrl;
            for (int i = 0; i < 5; i++) {
              try {
                var resp = await HttpClient.instance.dio.get(
                  currentUrl,
                  options: Options(
                    followRedirects: false,
                    validateStatus: (status) => status != null && status < 500,
                    responseType: ResponseType.plain,
                    headers: {
                      'User-Agent':
                          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
                      'Referer': 'https://passport.douyu.com/',
                    },
                  ),
                );
                extractCookies(resp);

                if (resp.statusCode == 301 ||
                    resp.statusCode == 302 ||
                    resp.statusCode == 303 ||
                    resp.statusCode == 307) {
                  var location = resp.headers.value("location");
                  if (location != null && location.isNotEmpty) {
                    currentUrl = location.startsWith("http")
                        ? location
                        : "https://www.douyu.com$location";
                    continue;
                  }
                }
                break;
              } catch (_) {
                break;
              }
            }
          }

          // 3. 去重并组装完整 Cookie 字符串
          if (cookies.isNotEmpty) {
            Map<String, String> cookieMap = {};
            for (var item in cookies) {
              var parts = item.split("=");
              if (parts.length >= 2) {
                cookieMap[parts[0].trim()] = parts.sublist(1).join("=").trim();
              }
            }
            var cookieStr =
                cookieMap.entries.map((e) => "${e.key}=${e.value}").join("; ");
            Log.i("Douyu login cookie: $cookieStr");
            DouyuAccountService.instance.setCookie(cookieStr);
            await DouyuAccountService.instance.loadUserInfo();
            SmartDialog.showToast("斗鱼账号登录成功");
            Get.back();
            return;
          }
        }
        SmartDialog.showToast("登录成功但未能解析凭证，请重试");
        loadQRCode();
      } else if (err == 1) {
        // 已扫描，待手机确认
        qrStatus.value = QRStatus.scanned;
      } else if (err == -1) {
        // 二维码已失效
        qrStatus.value = QRStatus.expired;
        qrcodeKey = "";
        timer?.cancel();
      } else if (err == -2) {
        // 未扫码，保持
        qrStatus.value = QRStatus.unscanned;
      }
    } catch (e) {
      Log.logPrint(e);
    }
  }

  @override
  void onClose() {
    timer?.cancel();
    super.onClose();
  }
}
