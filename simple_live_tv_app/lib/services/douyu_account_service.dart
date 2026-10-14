import 'dart:convert';
import 'dart:math';

import 'package:get/get.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_tv_app/app/constant.dart';
import 'package:simple_live_tv_app/app/sites.dart';
import 'package:simple_live_tv_app/requests/http_client.dart';
import 'package:simple_live_tv_app/services/local_storage_service.dart';

class DouyuAccountService extends GetxService {
  static DouyuAccountService get instance => Get.find<DouyuAccountService>();

  var logined = false.obs;

  var cookie = "";
  var uid = 0;
  var name = "未登录".obs;
  var expireTime = Rx<DateTime?>(null);

  bool get isExpired {
    if (!logined.value || cookie.isEmpty) return false;
    final exp = expireTime.value;
    if (exp == null) return false;
    return DateTime.now().isAfter(exp);
  }

  int get remainingDays {
    final exp = expireTime.value;
    if (exp == null) return 0;
    final diff = exp.difference(DateTime.now());
    if (diff.isNegative) return 0;
    return (diff.inHours / 24).ceil();
  }

  int get remainingHours {
    final exp = expireTime.value;
    if (exp == null) return 0;
    final diff = exp.difference(DateTime.now());
    if (diff.isNegative) return 0;
    return diff.inHours;
  }

  String get expireDateText {
    final exp = expireTime.value;
    if (exp == null) return "";
    var y = exp.year.toString().padLeft(4, '0');
    var m = exp.month.toString().padLeft(2, '0');
    var d = exp.day.toString().padLeft(2, '0');
    var h = exp.hour.toString().padLeft(2, '0');
    var min = exp.minute.toString().padLeft(2, '0');
    return "$y-$m-$d $h:$min";
  }

  DateTime? _parseJwtExpireTime(String cookieStr) {
    if (cookieStr.isEmpty) return null;
    var token = _parseCookieValue(cookieStr, "acf_jwt_token");
    if (token.isEmpty) {
      token = _parseCookieValue(cookieStr, "acf_dmjwt_token");
    }
    if (token.isEmpty) return null;
    var parts = token.split('.');
    if (parts.length < 2) return null;
    try {
      var normalized = base64Url.normalize(parts[1]);
      var payloadStr = utf8.decode(base64Url.decode(normalized));
      var payload = jsonDecode(payloadStr);
      if (payload is Map && payload.containsKey("exp")) {
        var exp = payload["exp"];
        if (exp is int) {
          return DateTime.fromMillisecondsSinceEpoch(exp * 1000);
        } else if (exp is num) {
          return DateTime.fromMillisecondsSinceEpoch(exp.toInt() * 1000);
        }
      }
    } catch (_) {}
    return null;
  }

  @override
  void onInit() {
    cookie = LocalStorageService.instance
        .getValue(LocalStorageService.kDouyuCookie, "");
    name.value = LocalStorageService.instance
        .getValue(LocalStorageService.kDouyuUserName, "未登录");
    logined.value = cookie.isNotEmpty;
    expireTime.value = _parseJwtExpireTime(cookie);
    setSite();
    if (logined.value) {
      loadUserInfo();
    }
    super.onInit();
  }

  Future loadUserInfo() async {
    if (cookie.isEmpty) {
      return;
    }
    try {
      // 优先从 cookie 中提取昵称与 uid
      var extractedName = _parseCookieValue(cookie, "acf_nickname");
      if (extractedName.isEmpty) {
        extractedName = _parseCookieValue(cookie, "acf_username");
      }
      var extractedUid =
          int.tryParse(_parseCookieValue(cookie, "acf_uid")) ?? 0;
      if (extractedName.isNotEmpty) {
        name.value = extractedName;
        LocalStorageService.instance
            .setValue(LocalStorageService.kDouyuUserName, extractedName);
      }
      if (extractedUid > 0) {
        uid = extractedUid;
      }
      setSite();

      // 请求斗鱼接口验证最新昵称与登录状态
      var result = await HttpClient.instance.getJson(
        "https://www.douyu.com/member/cp/get_user_info",
        header: {
          "Cookie": cookie,
          "User-Agent":
              "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
          "Referer": "https://www.douyu.com/",
        },
      );
      if (result is Map && result["error"] == 0 && result["data"] is Map) {
        var nickname = result["data"]["nickname"]?.toString();
        if (nickname != null && nickname.isNotEmpty) {
          name.value = nickname;
          LocalStorageService.instance
              .setValue(LocalStorageService.kDouyuUserName, nickname);
        }
      }
    } catch (_) {
      // 网络波动，不影响现有凭据继续生效
    }
  }

  String _parseCookieValue(String cookieStr, String key) {
    var pairs = cookieStr.split(";");
    for (var pair in pairs) {
      var parts = pair.trim().split("=");
      if (parts.length >= 2 && parts[0].trim() == key) {
        try {
          return Uri.decodeComponent(parts.sublist(1).join("=").trim());
        } catch (_) {
          return parts.sublist(1).join("=").trim();
        }
      }
    }
    return "";
  }

  void setSite() {
    try {
      var site = (Sites.allSites[Constant.kDouyu]?.liveSite as DouyuSite?);
      if (site != null) {
        site.cookie = cookie;
        site.deviceId = _ensureDeviceId();
      }
    } catch (_) {}
  }

  /// 匿名身份用的本设备持久化 did：首次生成 32 位 hex 并落盘，
  /// 之后所有斗鱼请求复用，不再共用签名脚本里写死的共享 did。
  String _ensureDeviceId() {
    var stored = LocalStorageService.instance
        .getValue(LocalStorageService.kDouyuDeviceId, "");
    if (stored.isEmpty) {
      stored = _generateHexDeviceId();
      LocalStorageService.instance
          .setValue(LocalStorageService.kDouyuDeviceId, stored);
    }
    return stored;
  }

  static String _generateHexDeviceId() {
    var random = Random.secure();
    return List.generate(
      32,
      (i) => random.nextInt(16).toRadixString(16),
    ).join();
  }

  void setCookie(String cookie, {String? userName}) {
    this.cookie = cookie;
    LocalStorageService.instance
        .setValue(LocalStorageService.kDouyuCookie, cookie);
    if (userName != null && userName.isNotEmpty) {
      name.value = userName;
      LocalStorageService.instance
          .setValue(LocalStorageService.kDouyuUserName, userName);
    } else {
      var extractedName = _parseCookieValue(cookie, "acf_nickname");
      if (extractedName.isEmpty) {
        extractedName = _parseCookieValue(cookie, "acf_username");
      }
      if (extractedName.isNotEmpty) {
        name.value = extractedName;
        LocalStorageService.instance
            .setValue(LocalStorageService.kDouyuUserName, extractedName);
      }
    }
    logined.value = cookie.isNotEmpty;
    expireTime.value = _parseJwtExpireTime(cookie);
    setSite();
  }

  void logout() async {
    cookie = "";
    uid = 0;
    name.value = "未登录";
    expireTime.value = null;
    setSite();
    LocalStorageService.instance
        .setValue(LocalStorageService.kDouyuCookie, "");
    LocalStorageService.instance
        .setValue(LocalStorageService.kDouyuUserName, "未登录");
    logined.value = false;
  }
}
