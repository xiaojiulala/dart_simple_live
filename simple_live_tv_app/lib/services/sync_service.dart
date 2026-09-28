import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:simple_live_tv_app/app/constant.dart';
import 'package:simple_live_tv_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_tv_app/app/event_bus.dart';
import 'package:simple_live_tv_app/app/log.dart';
import 'package:simple_live_tv_app/app/utils.dart';
import 'package:simple_live_tv_app/models/db/follow_user.dart';
import 'package:simple_live_tv_app/models/db/history.dart';
import 'package:simple_live_tv_app/services/bilibili_account_service.dart';
import 'package:simple_live_tv_app/services/db_service.dart';
import 'package:simple_live_tv_app/services/douyin_account_service.dart';
import 'package:simple_live_tv_app/app/sites.dart';
import 'package:simple_live_tv_app/modules/parse/live_url_parser.dart';
import 'package:simple_live_tv_app/routes/app_navigation.dart';
import 'package:simple_live_tv_app/services/douyu_account_service.dart';
import 'package:udp/udp.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:uuid/uuid.dart';

class SyncService extends GetxService {
  static SyncService get instance => Get.find<SyncService>();

  UDP? udp;
  static const int udpPort = 23235;
  static const int httpPort = 23234;
  DeviceInfoPlugin deviceInfo = DeviceInfoPlugin();
  NetworkInfo networkInfo = NetworkInfo();
  HttpServer? server;

  var ipAddress = "".obs;
  var httpRunning = false.obs;
  var httpErrorMsg = "".obs;

  var deviceId = "";
  @override
  void onInit() {
    Log.d('SyncService init');
    deviceId = (const Uuid().v4()).split('-').first;
    listenUDP();
    initServer();
    super.onInit();
  }

  /// 监听来自其他客户端的UDP广播
  /// - 如果收到广播，回复自己的信息
  void listenUDP() async {
    udp = await UDP.bind(Endpoint.any(port: const Port(udpPort)));
    udp!.asStream().listen((datagram) {
      var str = String.fromCharCodes(datagram!.data);
      Log.i("Received: $str from ${datagram.address}:${datagram.port}");
      if (str.startsWith('{') && str.endsWith('}')) {
        var data = json.decode(str);

        //处理Hello的广播
        if (data["type"] == "hello") {
          //如果http服务已经启动，就回复自己的信息
          if (httpRunning.value) {
            sendInfo();
          }
          return;
        }
      } else if (str == 'Who is SimpleLive?') {
        //如果http服务已经启动，就回复自己的信息
        if (httpRunning.value) {
          sendInfo();
        }
      }
    });
  }

  /// 发送自己的信息
  void sendInfo() async {
    //var ip = await getLocalIP();

    var name = await getDeviceName();

    var data = {
      "id": deviceId,
      "type": "tv",
      "name": name,
      //"address": ip,
      //"port": httpPort,
    };

    await udp!.send(
      json.encode(data).codeUnits,
      Endpoint.broadcast(
        port: const Port(udpPort),
      ),
    );
    Log.i("send udp info: $data");
  }

  /// 读取本地IP
  /// - 如果是wifi，直接获取wifi的IP
  /// - 如果是有线，获取所有的IP，找到全部的IP
  Future<String> getLocalIP() async {
    var ip = await networkInfo.getWifiIP();
    if (ip == null || ip.isEmpty) {
      var interfaces = await NetworkInterface.list();
      var ipList = <String>[];
      for (var interface in interfaces) {
        for (var addr in interface.addresses) {
          if (addr.type.name == 'IPv4' &&
              !addr.address.startsWith('127') &&
              !addr.isMulticast &&
              !addr.isLoopback) {
            ipList.add(addr.address);
            break;
          }
        }
      }
      ip = ipList.join(';');
    }
    return ip;
  }

  Future<String> getDeviceName() async {
    var name = "SimpleLive-TV";
    if (Platform.isAndroid) {
      var info = await deviceInfo.androidInfo;
      name = info.model;
    } else if (Platform.isIOS) {
      var info = await deviceInfo.iosInfo;
      name = info.name;
    } else if (Platform.isMacOS) {
      var info = await deviceInfo.macOsInfo;
      name = info.computerName;
    } else if (Platform.isLinux) {
      var info = await deviceInfo.linuxInfo;
      name = info.name;
    } else if (Platform.isWindows) {
      var info = await deviceInfo.windowsInfo;
      name = info.userName;
    }
    return name;
  }

  /// 初始化HTTP服务
  void initServer() async {
    try {
      var serverRouter = Router();
      serverRouter.get('/', _helloRequest);
      serverRouter.get('/info', _infoRequest);
      serverRouter.post('/sync/follow', _syncFollowUserReuqest);
      serverRouter.get('/sync/follow', _exportFollowUserRequest);
      serverRouter.get('/export/follow', _exportFollowUserRequest);
      serverRouter.post('/sync/history', _syncHistoryReuqest);
      serverRouter.get('/sync/history', _exportHistoryRequest);
      serverRouter.get('/export/history', _exportHistoryRequest);
      serverRouter.post('/sync/blocked_word', _syncBlockedWordReuqest);
      serverRouter.post('/sync/account/bilibili', _syncBiliAccountReuqest);
      serverRouter.post('/sync/account/douyin', _syncDouyinAccountReuqest);
      serverRouter.post('/sync/account/douyu', _syncDouyuAccountRequest);
      serverRouter.get('/parse', _serveParseHtmlRequest);
      serverRouter.post('/api/parse_play', _parsePlayApiRequest);

      var server = await shelf_io.serve(
        serverRouter,
        InternetAddress.anyIPv4,
        httpPort,
      );

      // Enable content compression
      server.autoCompress = true;

      httpRunning.value = true;

      var ip = await getLocalIP();
      ipAddress.value = ip;

      Log.d('Serving at http://$ip:${server.port}');
    } catch (e) {
      httpErrorMsg.value = e.toString();
      Log.logPrint(e);
    }
  }

  /// 测试服务能否正常访问
  shelf.Response _helloRequest(shelf.Request request) {
    return toJsonResponse({
      'status': true,
      'message': 'http server is running...',
      "version": 'Simple Live TV v${Utils.packageInfo.version}',
      "app": "Simple Live TV",
      "type": "tv",
      "platform": Platform.operatingSystem,
    });
  }

  /// 发送自己的信息
  Future<shelf.Response> _infoRequest(shelf.Request request) async {
    var name = await getDeviceName();
    return toJsonResponse({
      "id": deviceId,
      'type': 'tv',
      'name': name,
      'version': Utils.packageInfo.version,
      'address': ipAddress.value,
      'port': httpPort,
    });
  }

  /// 导出关注列表（供手机/电脑浏览器直接下载）
  shelf.Response _exportFollowUserRequest(shelf.Request request) {
    try {
      final users = DBService.instance.followBox.values.toList();
      final list = users.map((e) => e.toJson()).toList();
      return shelf.Response.ok(
        json.encode(list),
        headers: {
          'Content-Type': 'application/json; charset=utf-8',
          'Content-Disposition':
              'attachment; filename="simple_live_tv_follows.json"',
          'Access-Control-Allow-Origin': '*',
        },
        encoding: Encoding.getByName('utf-8'),
      );
    } catch (e) {
      return toJsonResponse({
        'status': false,
        'message': e.toString(),
      });
    }
  }

  /// 导出历史记录（供手机/电脑浏览器直接下载）
  shelf.Response _exportHistoryRequest(shelf.Request request) {
    try {
      final histories = DBService.instance.historyBox.values.toList();
      final list = histories.map((e) => e.toJson()).toList();
      return shelf.Response.ok(
        json.encode(list),
        headers: {
          'Content-Type': 'application/json; charset=utf-8',
          'Content-Disposition':
              'attachment; filename="simple_live_tv_history.json"',
          'Access-Control-Allow-Origin': '*',
        },
        encoding: Encoding.getByName('utf-8'),
      );
    } catch (e) {
      return toJsonResponse({
        'status': false,
        'message': e.toString(),
      });
    }
  }

  /// 同步关注用户列表
  Future<shelf.Response> _syncFollowUserReuqest(shelf.Request request) async {
    try {
      var overlay =
          int.parse(request.requestedUri.queryParameters['overlay'] ?? '0');

      var body = await request.readAsString();
      Log.d('_syncFollowUserReuqest: ${body.length} bytes');
      var jsonBody = json.decode(body);
      if (jsonBody is! List) {
        throw const FormatException("关注列表格式不是数组");
      }
      final users = <FollowUser>[];
      for (var item in jsonBody) {
        try {
          if (item is Map) {
            final user = FollowUser.fromJson(Map<String, dynamic>.from(item));
            if (user.id.isNotEmpty &&
                user.roomId.isNotEmpty &&
                user.siteId.isNotEmpty) {
              users.add(user);
            }
          }
        } catch (e) {
          Log.d("跳过异常关注项: $e");
        }
      }
      if (overlay == 1) {
        await DBService.instance.followBox.clear();
      }
      await DBService.instance.addFollows(users);

      SmartDialog.showToast('已同步关注用户列表（${users.length} 条）');
      EventBus.instance.emit(Constant.kUpdateFollow, 0);
      return toJsonResponse({
        'status': true,
        'message': 'success',
      });
    } catch (e) {
      return toJsonResponse({
        'status': false,
        'message': e.toString(),
      });
    }
  }

  /// 同步观看记录
  Future<shelf.Response> _syncHistoryReuqest(shelf.Request request) async {
    try {
      var overlay =
          int.parse(request.requestedUri.queryParameters['overlay'] ?? '0');
      var body = await request.readAsString();
      Log.d('_syncHistoryReuqest: ${body.length} bytes');
      var jsonBody = json.decode(body);
      if (jsonBody is! List) {
        throw const FormatException("历史记录格式不是数组");
      }
      final histories = <History>[];
      for (var item in jsonBody) {
        try {
          if (item is Map) {
            final history = History.fromJson(Map<String, dynamic>.from(item));
            if (history.id.isNotEmpty &&
                history.roomId.isNotEmpty &&
                history.siteId.isNotEmpty) {
              histories.add(history);
            }
          }
        } catch (e) {
          Log.d("跳过异常历史项: $e");
        }
      }
      if (overlay == 1) {
        await DBService.instance.historyBox.clear();
      }
      for (var history in histories) {
        if (DBService.instance.historyBox.containsKey(history.id)) {
          var old = DBService.instance.historyBox.get(history.id);
          //如果本地的更新时间比较新，就不更新
          if (old!.updateTime.isAfter(history.updateTime)) {
            continue;
          }
        }
        await DBService.instance.addOrUpdateHistory(history);
      }

      SmartDialog.showToast('已同步观看记录');
      EventBus.instance.emit(Constant.kUpdateHistory, 0);
      return toJsonResponse({
        'status': true,
        'message': 'success',
      });
    } catch (e) {
      return toJsonResponse({
        'status': false,
        'message': e.toString(),
      });
    }
  }

  /// 同步弹幕屏蔽词
  Future<shelf.Response> _syncBlockedWordReuqest(shelf.Request request) async {
    try {
      var overlay =
          int.parse(request.requestedUri.queryParameters['overlay'] ?? '0');
      var body = await request.readAsString();
      Log.d('_syncBlockedWordReuqest: $body');
      var jsonBody = json.decode(body);
      if (jsonBody is! List) {
        throw const FormatException("屏蔽词格式不是数组");
      }
      if (overlay == 1) {
        await AppSettingsController.instance.clearShieldList();
      }
      for (var keyword in jsonBody) {
        AppSettingsController.instance.importShieldValue(keyword.toString());
      }
      SmartDialog.showToast('已同步弹幕屏蔽词');
      return toJsonResponse({
        'status': true,
        'message': 'success',
      });
    } catch (e) {
      return toJsonResponse({
        'status': false,
        'message': e.toString(),
      });
    }
  }

  /// 同步哔哩哔哩账号
  Future<shelf.Response> _syncBiliAccountReuqest(shelf.Request request) async {
    try {
      var body = await request.readAsString();
      Log.d('_syncBiliAccountReuqest: $body');
      var jsonBody = json.decode(body);
      if (jsonBody is! Map) {
        throw const FormatException("账号数据格式不是对象");
      }
      var cookie = jsonBody['cookie']?.toString() ?? "";
      if (cookie.isEmpty) {
        throw const FormatException("账号 Cookie 为空");
      }
      BiliBiliAccountService.instance.setCookie(cookie);
      BiliBiliAccountService.instance.loadUserInfo();
      SmartDialog.showToast('已同步哔哩哔哩账号');
      return toJsonResponse({
        'status': true,
        'message': 'success',
      });
    } catch (e) {
      return toJsonResponse({
        'status': false,
        'message': e.toString(),
      });
    }
  }

  /// 同步抖音账号
  Future<shelf.Response> _syncDouyinAccountReuqest(
      shelf.Request request) async {
    try {
      var body = await request.readAsString();
      Log.d('_syncDouyinAccountReuqest');
      var jsonBody = json.decode(body);
      if (jsonBody is! Map) {
        throw const FormatException("账号数据格式不是对象");
      }
      var cookie = jsonBody['cookie']?.toString() ?? "";
      if (cookie.isEmpty) {
        throw const FormatException("账号 Cookie 为空");
      }
      DouyinAccountService.instance.setCookie(cookie);
      SmartDialog.showToast('已同步抖音账号');
      return toJsonResponse({
        'status': true,
        'message': 'success',
      });
    } catch (e) {
      return toJsonResponse({
        'status': false,
        'message': e.toString(),
      });
    }
  }

  /// 同步斗鱼账号
  Future<shelf.Response> _syncDouyuAccountRequest(
      shelf.Request request) async {
    try {
      var body = await request.readAsString();
      Log.d('_syncDouyuAccountRequest');
      var jsonBody = json.decode(body);
      if (jsonBody is! Map) {
        throw const FormatException("账号数据格式不是对象");
      }
      var cookie = jsonBody['cookie']?.toString() ?? "";
      if (cookie.isEmpty) {
        throw const FormatException("账号 Cookie 为空");
      }
      DouyuAccountService.instance.setCookie(cookie);
      DouyuAccountService.instance.loadUserInfo();
      SmartDialog.showToast('已同步斗鱼账号');
      return toJsonResponse({
        'status': true,
        'message': 'success',
      });
    } catch (e) {
      return toJsonResponse({
        'status': false,
        'message': e.toString(),
      });
    }
  }

  shelf.Response _serveParseHtmlRequest(shelf.Request request) {
    const html = '''<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
<title>SimpleLive TV - 投送到电视</title>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { background-color: #121212; color: #fff; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; padding: 20px; }
  .container { max-width: 500px; margin: 0 auto; }
  h2 { font-size: 22px; text-align: center; margin: 16px 0 6px 0; color: #ff6699; }
  p.tip { color: #888; font-size: 13px; text-align: center; margin-bottom: 20px; }
  textarea { width: 100%; height: 120px; background: #1e1e1e; border: 1px solid #333; border-radius: 8px; color: #fff; padding: 12px; font-size: 15px; resize: none; outline: none; }
  textarea:focus { border-color: #ff6699; }
  button { width: 100%; margin-top: 16px; padding: 14px; background: #ff6699; border: none; border-radius: 8px; color: #fff; font-size: 16px; font-weight: bold; cursor: pointer; }
  button:disabled { background: #555; }
  #status { margin-top: 20px; padding: 12px; border-radius: 6px; font-size: 14px; display: none; text-align: center; }
  .success { background: #1b3a24; color: #4ade80; border: 1px solid #22543d; }
  .error { background: #3a1b1b; color: #f87171; border: 1px solid #542222; }
  .formats { margin-top: 24px; padding: 14px; background: #1a1a1a; border-radius: 8px; font-size: 12px; color: #888; line-height: 1.8; }
</style>
</head>
<body>
<div class="container">
  <h2>📺 投送链接到电视</h2>
  <p class="tip">粘贴直播间分享链接，电视将自动跳转播放</p>
  <textarea id="urlInput" placeholder="在此粘贴哔哩哔哩、斗鱼、虎牙或抖音直播间分享链接..."></textarea>
  <button id="sendBtn" onclick="sendUrl()">投送到电视播放</button>
  <div id="status"></div>
  <div class="formats">
    支持平台及链接格式：<br>
    • 哔哩哔哩：live.bilibili.com / b23.tv 短链<br>
    • 斗鱼直播：douyu.com 房间与专题页面<br>
    • 虎牙直播：huya.com 房间链接<br>
    • 抖音直播：live.douyin.com / v.douyin.com 短链
  </div>
</div>
<script>
async function sendUrl() {
  const input = document.getElementById('urlInput');
  const btn = document.getElementById('sendBtn');
  const status = document.getElementById('status');
  const val = input.value.trim();
  if(!val) { alert('请先粘贴链接！'); return; }
  btn.disabled = true; btn.innerText = '正在投送中...';
  status.style.display = 'none';
  try {
    const resp = await fetch('/api/parse_play', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ url: val })
    });
    const res = await resp.json();
    status.style.display = 'block';
    if(res.success) {
      status.className = 'success';
      status.innerText = '🎉 ' + (res.message || '投送成功，电视正在播放！');
      input.value = '';
    } else {
      status.className = 'error';
      status.innerText = '❌ 投送失败：' + (res.message || '未知错误');
    }
  } catch(e) {
    status.style.display = 'block';
    status.className = 'error';
    status.innerText = '❌ 网络请求异常：' + e;
  } finally {
    btn.disabled = false; btn.innerText = '投送到电视播放';
  }
}
</script>
</body>
</html>''';
    return shelf.Response.ok(
      html,
      headers: {'content-type': 'text/html; charset=utf-8'},
    );
  }

  Future<shelf.Response> _parsePlayApiRequest(shelf.Request request) async {
    try {
      final body = await request.readAsString();
      dynamic data;
      try {
        data = json.decode(body);
      } catch (_) {
        data = null;
      }
      final rawUrl = (data is Map ? data["url"] : body)?.toString() ?? "";
      if (rawUrl.trim().isEmpty) {
        return toJsonResponse({'success': false, 'message': '链接不能为空'});
      }

      final parsed = await LiveUrlParser.parseFromText(rawUrl);
      if (parsed == null || parsed.roomId.isEmpty) {
        return toJsonResponse({'success': false, 'message': '无法识别该直播间链接'});
      }
      final site = Sites.allSites[parsed.siteId];
      if (site == null) {
        return toJsonResponse(
            {'success': false, 'message': '不支持的平台：${parsed.siteId}'});
      }

      // 验证房间是否有效，避免电视白屏
      try {
        final detail = await site.liveSite.getRoomDetail(roomId: parsed.roomId);
        if (detail.roomId.isEmpty) {
          throw '房间信息为空';
        }
      } catch (e) {
        return toJsonResponse({'success': false, 'message': '获取房间信息失败：$e'});
      }

      // 在主线程安全跳转
      Future.microtask(() {
        SmartDialog.showToast("已接收手机投送：${site.name} ${parsed.roomId}");
        AppNavigator.toLiveRoomDetail(site: site, roomId: parsed.roomId);
      });

      return toJsonResponse({
        'success': true,
        'message': '已投送到电视：${site.name} ${parsed.roomId}',
      });
    } catch (e) {
      return toJsonResponse({'success': false, 'message': e.toString()});
    }
  }

  shelf.Response toJsonResponse(Map<String, dynamic> data) {
    return shelf.Response.ok(
      json.encode(data),
      headers: {
        'Content-Type': 'application/json',
      },
      encoding: Encoding.getByName('utf-8'),
    );
  }

  @override
  void onClose() {
    Log.d('SyncService close');
    udp?.close();
    server?.close(force: true);
    super.onClose();
  }
}
