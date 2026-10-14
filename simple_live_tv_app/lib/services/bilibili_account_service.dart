import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_tv_app/app/constant.dart';
import 'package:simple_live_tv_app/app/sites.dart';
import 'package:simple_live_tv_app/models/account/bilibili_user_info_page.dart';
import 'package:simple_live_tv_app/requests/http_client.dart';
import 'package:simple_live_tv_app/services/local_storage_service.dart';

class BiliBiliAccountService extends GetxService {
  static BiliBiliAccountService get instance =>
      Get.find<BiliBiliAccountService>();

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

  DateTime? _parseSessdataExpireTime(String cookieStr) {
    if (cookieStr.isEmpty) return null;
    var sessdata = _parseCookieValue(cookieStr, "SESSDATA");
    if (sessdata.isEmpty) return null;
    try {
      // SESSDATA 格式：{hash},{expire_timestamp},{extra_token}
      var decoded = Uri.decodeComponent(sessdata);
      var parts = decoded.split(',');
      if (parts.length >= 2) {
        var exp = int.tryParse(parts[1].trim());
        if (exp != null && exp > 0) {
          return DateTime.fromMillisecondsSinceEpoch(exp * 1000);
        }
      }
    } catch (_) {}
    return null;
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

  @override
  void onInit() {
    cookie = LocalStorageService.instance
        .getValue(LocalStorageService.kBilibiliCookie, "");
    logined.value = cookie.isNotEmpty;
    expireTime.value = _parseSessdataExpireTime(cookie);
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
      var result = await HttpClient.instance.getJson(
        "https://api.bilibili.com/x/member/web/account",
        header: {
          "Cookie": cookie,
        },
      );
      if (result["code"] == 0) {
        var info = BiliBiliUserInfoModel.fromJson(result["data"]);
        name.value = info.uname ?? "未登录";
        uid = info.mid ?? 0;
        setSite();
      } else {
        expireTime.value = DateTime.now().subtract(const Duration(minutes: 1));
        SmartDialog.showToast("哔哩哔哩登录已失效，请重新登录");
      }
    } catch (e) {
      SmartDialog.showToast("获取哔哩哔哩用户信息失败，可前往账号管理重试");
    }
  }

  void setSite() {
    try {
      var site = (Sites.allSites[Constant.kBiliBili]?.liveSite as BiliBiliSite?);
      if (site != null) {
        site.userId = uid;
        site.cookie = cookie;
      }
    } catch (_) {}
  }

  void setCookie(String cookie) {
    this.cookie = cookie;
    LocalStorageService.instance
        .setValue(LocalStorageService.kBilibiliCookie, cookie);
    logined.value = cookie.isNotEmpty;
    expireTime.value = _parseSessdataExpireTime(cookie);
    setSite();
  }

  void logout() async {
    cookie = "";
    uid = 0;
    name.value = "未登录";
    expireTime.value = null;
    setSite();
    LocalStorageService.instance
        .setValue(LocalStorageService.kBilibiliCookie, "");
    logined.value = false;
  }
}
