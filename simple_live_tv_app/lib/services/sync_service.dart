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
import 'package:simple_live_core/simple_live_core.dart';
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
      serverRouter.get('/', _serveRootRequest);
      serverRouter.get('/index.html', _serveWebDashboardRequest);
      serverRouter.get('/dashboard', _serveWebDashboardRequest);
      serverRouter.get('/dashboard/', _serveWebDashboardRequest);
      serverRouter.get('/info', _infoRequest);
      serverRouter.get('/info/', _infoRequest);
      serverRouter.post('/sync/follow', _syncFollowUserReuqest);
      serverRouter.post('/sync/follow/', _syncFollowUserReuqest);
      serverRouter.get('/sync/follow', _exportFollowUserRequest);
      serverRouter.get('/sync/follow/', _exportFollowUserRequest);
      serverRouter.get('/export/follow', _exportFollowUserRequest);
      serverRouter.get('/export/follow/', _exportFollowUserRequest);
      serverRouter.post('/sync/history', _syncHistoryReuqest);
      serverRouter.post('/sync/history/', _syncHistoryReuqest);
      serverRouter.get('/sync/history', _exportHistoryRequest);
      serverRouter.get('/sync/history/', _exportHistoryRequest);
      serverRouter.get('/export/history', _exportHistoryRequest);
      serverRouter.get('/export/history/', _exportHistoryRequest);
      serverRouter.post('/sync/blocked_word', _syncBlockedWordReuqest);
      serverRouter.post('/sync/account/bilibili', _syncBiliAccountReuqest);
      serverRouter.post('/sync/account/douyin', _syncDouyinAccountReuqest);
      serverRouter.post('/sync/account/douyu', _syncDouyuAccountRequest);
      serverRouter.get('/api/account/status', _getAccountStatusRequest);
      serverRouter.post('/api/account/douyu/logout', _logoutDouyuAccountRequest);
      serverRouter.post('/api/account/bilibili/logout', _logoutBiliAccountRequest);
      serverRouter.get('/parse', _serveWebDashboardRequest);
      serverRouter.get('/parse/', _serveWebDashboardRequest);
      serverRouter.post('/api/parse_play', _parsePlayApiRequest);
      serverRouter.get('/api/export/follow', _downloadFollowJsonRequest);
      serverRouter.get('/api/export/history', _downloadHistoryJsonRequest);
      serverRouter.get('/api/follows', _getFollowListJsonRequest);
      serverRouter.post('/api/follow/delete', _deleteFollowJsonRequest);

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

  /// 根路径处理：浏览器直接访问展示 Web 控制台，API 客户端返回运行信息
  shelf.Response _serveRootRequest(shelf.Request request) {
    final accept = request.headers['accept'] ?? '';
    if (accept.contains('text/html')) {
      return _serveWebDashboardRequest(request);
    }
    return _helloRequest(request);
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

  /// 导出关注列表（如果是浏览器请求则直接展示控制台，否则触发下载）
  shelf.Response _exportFollowUserRequest(shelf.Request request) {
    final accept = request.headers['accept'] ?? '';
    if (accept.contains('text/html')) {
      return _serveWebDashboardRequest(request);
    }
    return _downloadFollowJsonRequest(request);
  }

  /// 导出历史记录（如果是浏览器请求则直接展示控制台，否则触发下载）
  shelf.Response _exportHistoryRequest(shelf.Request request) {
    final accept = request.headers['accept'] ?? '';
    if (accept.contains('text/html')) {
      return _serveWebDashboardRequest(request);
    }
    return _downloadHistoryJsonRequest(request);
  }

  /// 获取关注主播的简要列表 JSON（供 Web 端展示预览）
  shelf.Response _getFollowListJsonRequest(shelf.Request request) {
    try {
      final users = DBService.instance.followBox.values.toList();
      final list = users.map((e) => {
        'id': e.id,
        'roomId': e.roomId,
        'siteId': e.siteId,
        'userName': e.userName,
        'face': e.face,
        'avatar': e.face,
      }).toList();
      return toJsonResponse({
        'status': true,
        'total': list.length,
        'data': list,
      });
    } catch (e) {
      return toJsonResponse({
        'status': false,
        'message': e.toString(),
      });
    }
  }

  /// 删除单个关注
  Future<shelf.Response> _deleteFollowJsonRequest(shelf.Request request) async {
    try {
      final body = await request.readAsString();
      final data = json.decode(body);
      final id = data['id']?.toString() ?? '';
      if (id.isEmpty) {
        return toJsonResponse({'status': false, 'message': 'ID不能为空'});
      }
      await DBService.instance.deleteFollow(id);
      EventBus.instance.emit(Constant.kUpdateFollow, id);
      return toJsonResponse({'status': true, 'message': '删除成功'});
    } catch (e) {
      return toJsonResponse({'status': false, 'message': e.toString()});
    }
  }

  /// 下载关注列表 JSON 文件
  shelf.Response _downloadFollowJsonRequest(shelf.Request request) {
    try {
      final users = DBService.instance.followBox.values.toList();
      final list = users.map((e) => e.toJson()).toList();
      return shelf.Response.ok(
        const JsonEncoder.withIndent('  ').convert(list),
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

  /// 下载历史记录 JSON 文件
  shelf.Response _downloadHistoryJsonRequest(shelf.Request request) {
    try {
      final histories = DBService.instance.historyBox.values.toList();
      final list = histories.map((e) => e.toJson()).toList();
      return shelf.Response.ok(
        const JsonEncoder.withIndent('  ').convert(list),
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

  /// 同步关注用户列表（支持增量合并或覆盖替换）
  Future<shelf.Response> _syncFollowUserReuqest(shelf.Request request) async {
    try {
      var overlay =
          int.parse(request.requestedUri.queryParameters['overlay'] ?? '0');

      var body = await request.readAsString();
      Log.d('_syncFollowUserReuqest: ${body.length} bytes');
      var jsonBody = json.decode(body);
      List listItems;
      if (jsonBody is List) {
        listItems = jsonBody;
      } else if (jsonBody is Map && jsonBody['data'] is List) {
        listItems = jsonBody['data'] as List;
      } else if (jsonBody is Map && jsonBody['follows'] is List) {
        listItems = jsonBody['follows'] as List;
      } else {
        throw const FormatException("关注列表格式不正确（需为 JSON 数组或包含 data 字段）");
      }
      final users = <FollowUser>[];
      for (var item in listItems) {
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
        'message': '成功导入 ${users.length} 条关注记录',
        'count': users.length,
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

  Future<shelf.Response> _getAccountStatusRequest(
      shelf.Request request) async {
    return toJsonResponse({
      'bilibili': {
        'logined': BiliBiliAccountService.instance.logined.value,
        'name': BiliBiliAccountService.instance.name.value,
      },
      'douyu': {
        'logined': DouyuAccountService.instance.logined.value,
        'name': DouyuAccountService.instance.name.value,
        'uid': DouyuAccountService.instance.uid,
      },
    });
  }

  Future<shelf.Response> _logoutDouyuAccountRequest(
      shelf.Request request) async {
    DouyuAccountService.instance.logout();
    SmartDialog.showToast('已退出斗鱼账号');
    return toJsonResponse({'status': true, 'message': 'success'});
  }

  Future<shelf.Response> _logoutBiliAccountRequest(
      shelf.Request request) async {
    BiliBiliAccountService.instance.logout();
    SmartDialog.showToast('已退出B站账号');
    return toJsonResponse({'status': true, 'message': 'success'});
  }

  shelf.Response _serveWebDashboardRequest(shelf.Request request) {
    const html = '''<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no, viewport-fit=cover">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<meta name="theme-color" content="#121212">
<meta name="format-detection" content="telephone=no">
<title>SimpleLive TV 控制台</title>
<style>
  :root {
    --primary: #ff6699;
    --primary-hover: #ff4d88;
    --bg: #121212;
    --card: #1c1c1e;
    --card-border: #2c2c2e;
    --input-bg: #252528;
    --text: #f2f2f7;
    --text-sub: #8e8e93;
  }
  * {
    box-sizing: border-box;
    margin: 0;
    padding: 0;
    -webkit-tap-highlight-color: transparent;
  }
  body {
    background-color: var(--bg);
    color: var(--text);
    font-family: -apple-system, BlinkMacSystemFont, "PingFang SC", "Segoe UI", Roboto, "Helvetica Neue", sans-serif;
    padding: max(16px, env(safe-area-inset-top)) max(16px, env(safe-area-inset-right)) max(28px, env(safe-area-inset-bottom)) max(16px, env(safe-area-inset-left));
    line-height: 1.5;
    -webkit-font-smoothing: antialiased;
  }
  .container {
    max-width: 600px;
    margin: 0 auto;
    width: 100%;
  }
  header {
    text-align: center;
    margin-bottom: 16px;
  }
  h1 {
    font-size: 20px;
    color: var(--primary);
    margin-bottom: 4px;
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 8px;
    font-weight: 700;
  }
  .badge-dev {
    font-size: 12px;
    color: var(--text-sub);
  }

  /* iOS Segmented Tabs (Sticky) */
  .tabs {
    display: flex;
    background: #252528;
    border-radius: 12px;
    padding: 4px;
    gap: 4px;
    margin-bottom: 16px;
    position: sticky;
    top: max(8px, env(safe-area-inset-top));
    z-index: 100;
    backdrop-filter: blur(16px);
    -webkit-backdrop-filter: blur(16px);
  }
  .tab-btn {
    flex: 1;
    background: transparent;
    border: none;
    color: var(--text-sub);
    font-size: 14px;
    font-weight: 600;
    padding: 10px 4px;
    cursor: pointer;
    border-radius: 8px;
    transition: all 0.2s cubic-bezier(0.4, 0, 0.2, 1);
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 4px;
  }
  .tab-btn.active {
    background: var(--primary);
    color: #fff;
    box-shadow: 0 2px 8px rgba(255, 102, 153, 0.35);
  }

  /* Cards */
  .card {
    background: var(--card);
    border: 1px solid var(--card-border);
    border-radius: 14px;
    padding: 16px;
    margin-bottom: 14px;
  }
  .card-title {
    font-size: 15px;
    font-weight: 700;
    margin-bottom: 12px;
    color: #fff;
    display: flex;
    align-items: center;
    justify-content: space-between;
  }
  .card-desc {
    font-size: 13px;
    color: var(--text-sub);
    margin-bottom: 12px;
  }

  /* Form Elements (Prevent iOS Auto-Zoom with 16px) */
  input, textarea, select, button {
    font-size: 16px !important;
    font-family: inherit;
  }
  textarea {
    width: 100%;
    height: 100px;
    background: var(--input-bg);
    border: 1px solid var(--card-border);
    border-radius: 10px;
    color: #fff;
    padding: 12px;
    outline: none;
    margin-bottom: 10px;
    resize: none;
    -webkit-appearance: none;
    line-height: 1.4;
  }
  textarea:focus {
    border-color: var(--primary);
  }

  /* Buttons */
  .btn {
    min-height: 46px;
    padding: 10px 18px;
    border-radius: 10px;
    font-weight: 600;
    font-size: 15px !important;
    cursor: pointer;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    gap: 6px;
    text-decoration: none;
    border: none;
    transition: transform 0.1s, opacity 0.1s;
    user-select: none;
  }
  .btn:active {
    transform: scale(0.97);
    opacity: 0.85;
  }
  .btn-primary { background: var(--primary); color: #fff; }
  .btn-secondary { background: #2c2c2e; color: #fff; border: 1px solid #444; }
  .btn-outline { background: transparent; color: var(--primary); border: 1px solid var(--primary); }
  .btn-block { width: 100%; }
  .btn-sm { min-height: 36px; padding: 6px 12px; font-size: 13px !important; border-radius: 8px; }
  .btn-row { display: flex; gap: 8px; margin-bottom: 10px; flex-wrap: wrap; }
  .btn-group { display: flex; gap: 8px; flex-wrap: wrap; margin-bottom: 12px; }

  /* Radio Card */
  .radio-card {
    display: flex;
    align-items: flex-start;
    gap: 10px;
    padding: 12px;
    background: var(--input-bg);
    border-radius: 10px;
    border: 1px solid var(--card-border);
    margin-bottom: 8px;
    cursor: pointer;
    font-size: 14px;
    transition: border-color 0.2s;
  }
  .radio-card input {
    margin-top: 2px;
    accent-color: var(--primary);
    width: 18px;
    height: 18px;
    flex-shrink: 0;
  }

  /* Status message */
  .status-msg {
    margin-top: 12px;
    padding: 12px 14px;
    border-radius: 10px;
    font-size: 14px;
    display: none;
    word-break: break-word;
  }
  .status-success { background: #1b3a24; color: #4ade80; border: 1px solid #22543d; display: block; }
  .status-error { background: #3a1b1b; color: #f87171; border: 1px solid #542222; display: block; }

  /* Follow item list */
  .follow-list {
    max-height: 380px;
    overflow-y: auto;
    border: 1px solid var(--card-border);
    border-radius: 10px;
    background: var(--input-bg);
    -webkit-overflow-scrolling: touch;
  }
  .follow-item {
    display: flex;
    align-items: center;
    padding: 12px;
    border-bottom: 1px solid #222225;
    gap: 12px;
  }
  .follow-item:last-child { border-bottom: none; }
  .site-tag {
    font-size: 11px;
    padding: 2px 6px;
    border-radius: 4px;
    font-weight: bold;
    flex-shrink: 0;
  }
  .site-bilibili { background: #00aeec; color: #fff; }
  .site-douyu { background: #ff5d23; color: #fff; }
  .site-huya { background: #ffaa00; color: #000; }
  .site-douyin { background: #fe2c55; color: #fff; }
  .site-xiaohongshu { background: #ff2442; color: #fff; }
  .site-other { background: #555; color: #fff; }
  .follow-avatar { width: 40px; height: 40px; border-radius: 50%; object-fit: cover; background: #2c2c2e; flex-shrink: 0; }
  .follow-info { flex: 1; min-width: 0; }
  .follow-name { font-size: 14px; font-weight: 600; color: #fff; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .follow-sub { font-size: 12px; color: var(--text-sub); }

  .tip-box {
    background: #19191b;
    border-radius: 10px;
    padding: 12px;
    font-size: 12px;
    color: var(--text-sub);
    line-height: 1.8;
    margin-top: 10px;
  }
</style>
</head>
<body>
<div class="container">
  <header>
    <h1>📺 SimpleLive TV 控制台</h1>
    <div class="badge-dev" id="headerInfo">电视端管理与投送平台</div>
  </header>

  <!-- 顶部导航切换标签：手机扫码默认首先展示“投送直播” -->
  <div class="tabs">
    <button class="tab-btn active" id="tabBtn-push" onclick="switchTab('push')">🚀 投送直播</button>
    <button class="tab-btn" id="tabBtn-follow" onclick="switchTab('follow')">⭐️ 关注管理</button>
    <button class="tab-btn" id="tabBtn-account" onclick="switchTab('account')">👤 账号管理</button>
    <button class="tab-btn" id="tabBtn-history" onclick="switchTab('history')">🕒 历史记录</button>
  </div>

  <!-- 1. 投送直播页面（移动端核心功能，默认打开） -->
  <div id="tab-push">
    <div class="card">
      <div class="card-title">
        <span>🚀 投送直播间到电视</span>
      </div>
      <div class="card-desc">粘贴直播分享链接或口令，电视将立即自动切换开播：</div>
      <div class="btn-row">
        <button type="button" onclick="pasteTo('urlInput')" class="btn btn-secondary btn-sm">📋 粘贴剪贴板</button>
        <button type="button" onclick="clearInput('urlInput')" class="btn btn-secondary btn-sm">清空</button>
      </div>
      <textarea id="urlInput" placeholder="在此粘贴哔哩哔哩、斗鱼、虎牙、抖音或小红书直播间分享链接或口令..."></textarea>
      <button id="sendBtn" onclick="sendUrl()" class="btn btn-primary btn-block">立即投送并播放</button>
      <div id="pushStatus" class="status-msg"></div>
    </div>

    <div class="tip-box">
      <b>💡 支持平台及链接说明：</b><br>
      • <b>哔哩哔哩</b>：live.bilibili.com / b23.tv 短链<br>
      • <b>斗鱼直播</b>：douyu.com 房间及专题页链接<br>
      • <b>虎牙直播</b>：huya.com 房间链接<br>
      • <b>抖音直播</b>：live.douyin.com / v.douyin.com 短链<br>
      • <b>小红书直播</b>：xhslink.com 短链 / xiaohongshu.com 直播链接（注：小红书为单场次直播机制，主播每次开播均生成新场次号；投送新链接时系统会自动将已关注主播更新至最新场次）<br>
      • 手机分享时附带的中文文案系统会自动智能识别过滤。
    </div>
  </div>

  <!-- 2. 关注管理页面 -->
  <div id="tab-follow" style="display:none;">
    <div class="tip-box" style="margin-bottom:16px;">
      <b>💡 小红书关注机制说明：</b><br>
      • 小红书采用单场次直播机制（Session ID），主播每次开播均生成新的 18 位场次号，历史场次下播后即关闭。<br>
      • 若主播重新开播，直接在“投送播放”页面投送其最新直播链接，电视会自动同步并将关注迁移至最新场次。<br>
      • 如需清理已失效的旧场次记录，可直接点击下方列表中的“删除”按钮。
    </div>

    <div class="card">
      <div class="card-title">
        <span>📥 导出关注</span>
        <span style="font-size:13px;color:var(--primary);" id="followTotalBadge">关注数：--</span>
      </div>
      <div class="card-desc">下载或一键复制 JSON 格式关注备份：</div>
      <div class="btn-group">
        <a href="/api/export/follow" class="btn btn-primary btn-sm" download="simple_live_tv_follows.json">⬇️ 下载关注 JSON</a>
        <button type="button" onclick="copyFollowJson()" class="btn btn-secondary btn-sm">📋 复制全部 JSON</button>
        <button type="button" onclick="loadFollows()" class="btn btn-secondary btn-sm">🔄 刷新列表</button>
      </div>
      <div id="exportCopyStatus" class="status-msg"></div>
    </div>

    <div class="card">
      <div class="card-title">
        <span>📤 导入关注到电视</span>
      </div>
      <div class="btn-row">
        <input type="file" id="followFileInput" accept=".json,application/json,text/plain,*/*" onchange="handleFileSelect(event)" style="display:none">
        <button type="button" onclick="document.getElementById('followFileInput').click()" class="btn btn-outline btn-sm">📁 选择 .json 备份文件</button>
        <button type="button" onclick="pasteTo('followInput')" class="btn btn-secondary btn-sm">📋 粘贴剪贴板</button>
        <button type="button" onclick="clearInput('followInput')" class="btn btn-secondary btn-sm">清空</button>
      </div>
      <div id="fileName" style="font-size:12px;color:var(--text-sub);margin-bottom:8px;"></div>
      <textarea id="followInput" placeholder="在此粘贴关注列表 JSON 数据，或选择上方 .json 备份文件..."></textarea>
      
      <div class="radio-card" onclick="document.getElementById('mode0').checked=true">
        <input type="radio" name="importMode" id="mode0" value="0" checked>
        <div>
          <b>增量合并（推荐）</b><br>
          <span style="font-size:12px;color:var(--text-sub);">保留电视现有关注，仅添加新关注主播或更新信息</span>
        </div>
      </div>
      <div class="radio-card" onclick="document.getElementById('mode1').checked=true">
        <input type="radio" name="importMode" id="mode1" value="1">
        <div>
          <b>覆盖替换</b><br>
          <span style="font-size:12px;color:var(--text-sub);">清空电视现有关注，完全替换为导入的关注列表</span>
        </div>
      </div>

      <button id="importBtn" onclick="submitImportFollow()" class="btn btn-primary btn-block" style="margin-top:8px;">确认导入到电视</button>
      <div id="importStatus" class="status-msg"></div>
    </div>

    <div class="card">
      <div class="card-title">
        <span>📋 当前关注列表预览</span>
      </div>
      <div class="follow-list" id="followListPreview">
        <div style="padding:20px;text-align:center;color:#666;font-size:13px;">正在加载关注列表...</div>
      </div>
    </div>
  </div>

  <!-- 3. 账号管理页面 -->
  <div id="tab-account" style="display:none;">
    <div class="card">
      <div class="card-title">
        <span>🐟 斗鱼账号与 Cookie</span>
        <span id="douyuBadge" class="badge-dev" style="font-size:12px;">查询中...</span>
      </div>
      <div class="card-desc" id="douyuStatusDesc" style="margin-bottom:8px;">提示：未登录时最高画质由于斗鱼防盗链限制会在几分钟后掐流断连；登录后可享永久不断流租约。</div>
      <div class="btn-row">
        <button type="button" onclick="pasteTo('douyuCookieInput')" class="btn btn-secondary btn-sm">📋 粘贴剪贴板</button>
        <button type="button" onclick="clearInput('douyuCookieInput')" class="btn btn-secondary btn-sm">清空</button>
        <button type="button" id="douyuLogoutBtn" onclick="logoutAccount('douyu')" class="btn btn-outline btn-sm" style="display:none;color:#ff5252;">退出登录</button>
      </div>
      <textarea id="douyuCookieInput" placeholder="在此粘贴斗鱼登录 Cookie（包含 dy_auth、acf_auth、acf_uid 等）..."></textarea>
      <button id="saveDouyuBtn" onclick="saveDouyuCookie()" class="btn btn-primary btn-block">保存并同步斗鱼 Cookie 到电视</button>
      <div id="douyuStatusMsg" class="status-msg"></div>
    </div>

    <div class="card">
      <div class="card-title">
        <span>📺 哔哩哔哩账号与 Cookie</span>
        <span id="biliBadge" class="badge-dev" style="font-size:12px;">查询中...</span>
      </div>
      <div class="card-desc" id="biliStatusDesc" style="margin-bottom:8px;">提示：登录后可同步原画/高码率清晰度播放权限。</div>
      <div class="btn-row">
        <button type="button" onclick="pasteTo('biliCookieInput')" class="btn btn-secondary btn-sm">📋 粘贴剪贴板</button>
        <button type="button" onclick="clearInput('biliCookieInput')" class="btn btn-secondary btn-sm">清空</button>
        <button type="button" id="biliLogoutBtn" onclick="logoutAccount('bilibili')" class="btn btn-outline btn-sm" style="display:none;color:#ff5252;">退出登录</button>
      </div>
      <textarea id="biliCookieInput" placeholder="在此粘贴哔哩哔哩登录 Cookie（包含 SESSDATA 等）..."></textarea>
      <button id="saveBiliBtn" onclick="saveBiliCookie()" class="btn btn-primary btn-block">保存并同步 B站 Cookie 到电视</button>
      <div id="biliStatusMsg" class="status-msg"></div>
    </div>
  </div>

  <!-- 4. 历史记录页面 -->
  <div id="tab-history" style="display:none;">
    <div class="card">
      <div class="card-title"><span>🕒 观看历史导出</span></div>
      <div class="card-desc">下载电视端的观看历史记录 JSON 备份文件：</div>
      <a href="/api/export/history" class="btn btn-primary btn-block" download="simple_live_tv_history.json">⬇️ 下载观看历史 JSON</a>
    </div>
  </div>
</div>

<script>
function switchTab(name) {
  ['push', 'follow', 'account', 'history'].forEach(t => {
    const el = document.getElementById('tab-' + t);
    const btn = document.getElementById('tabBtn-' + t);
    if (el) el.style.display = (t === name) ? 'block' : 'none';
    if (btn) {
      if (t === name) btn.classList.add('active');
      else btn.classList.remove('active');
    }
  });
  if (name === 'follow') {
    loadFollows();
  } else if (name === 'account') {
    loadAccountStatus();
  }
}

function clearInput(id) {
  document.getElementById(id).value = '';
}

async function pasteTo(id) {
  const input = document.getElementById(id);
  try {
    if (navigator.clipboard && navigator.clipboard.readText) {
      const text = await navigator.clipboard.readText();
      if (text && text.trim()) {
        input.value = text.trim();
        return;
      }
    }
    alert('请长按输入框选择“粘贴”');
  } catch (_) {
    alert('请长按输入框直接粘贴');
  }
}

function getSiteBadge(siteId) {
  switch((siteId || '').toLowerCase()) {
    case 'bilibili': return '<span class="site-tag site-bilibili">B站</span>';
    case 'douyu': return '<span class="site-tag site-douyu">斗鱼</span>';
    case 'huya': return '<span class="site-tag site-huya">虎牙</span>';
    case 'douyin': return '<span class="site-tag site-douyin">抖音</span>';
    case 'xiaohongshu': return '<span class="site-tag site-xiaohongshu">小红书</span>';
    default: return '<span class="site-tag site-other">' + (siteId || '未知') + '</span>';
  }
}

async function loadFollows() {
  const badge = document.getElementById('followTotalBadge');
  const preview = document.getElementById('followListPreview');
  try {
    const resp = await fetch('/api/follows');
    const res = await resp.json();
    if(res.status && Array.isArray(res.data)) {
      badge.innerText = '关注数：' + res.total + ' 位';
      if(res.data.length === 0) {
        preview.innerHTML = '<div style="padding:20px;text-align:center;color:#666;font-size:13px;">暂无关注主播</div>';
        return;
      }
      let html = '';
      for(const u of res.data) {
        const pic = u.face || u.avatar || '';
        const avatar = pic ? '<img class="follow-avatar" src="' + pic + '" onerror="this.remove()" />' : '<div class="follow-avatar"></div>';
        html += '<div class="follow-item">' +
          avatar +
          '<div class="follow-info">' +
            '<div class="follow-name">' + (u.userName || '未知主播') + '</div>' +
            '<div class="follow-sub">' + (u.roomId || '') + '</div>' +
          '</div>' +
          getSiteBadge(u.siteId) +
          '<button class="btn btn-outline btn-sm btn-del-follow" style="margin-left:8px;color:#ff5252;border-color:rgba(255,82,82,0.35);padding:4px 8px;" data-id="' + encodeURIComponent(u.id || '') + '" data-name="' + encodeURIComponent(u.userName || u.id || '') + '">删除</button>' +
        '</div>';
      }
      preview.innerHTML = html;
      preview.onclick = function(e) {
        const btn = e.target.closest('.btn-del-follow');
        if(btn) {
          const id = decodeURIComponent(btn.getAttribute('data-id') || '');
          const name = decodeURIComponent(btn.getAttribute('data-name') || '');
          deleteFollowItem(id, name);
        }
      };
    } else {
      badge.innerText = '关注数：--';
      preview.innerHTML = '<div style="padding:20px;text-align:center;color:#f87171;font-size:13px;">加载失败：' + (res.message || '未知错误') + '</div>';
    }
  } catch(e) {
    badge.innerText = '关注数：--';
    preview.innerHTML = '<div style="padding:20px;text-align:center;color:#f87171;font-size:13px;">网络请求失败：' + e + '</div>';
  }
}

async function deleteFollowItem(id, name) {
  if(!confirm('确定要从电视关注列表中删除【' + (name || id) + '】吗？')) return;
  try {
    const resp = await fetch('/api/follow/delete', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ id: id })
    });
    const res = await resp.json();
    if(res.status) {
      loadFollows();
    } else {
      alert('删除失败：' + (res.message || '未知错误'));
    }
  } catch(e) {
    alert('请求失败：' + e);
  }
}

function handleFileSelect(evt) {
  const file = evt.target.files[0];
  if(!file) return;
  document.getElementById('fileName').innerText = '已选择：' + file.name;
  const reader = new FileReader();
  reader.onload = function(e) {
    document.getElementById('followInput').value = e.target.result;
  };
  reader.readAsText(file);
}

async function copyFollowJson() {
  const status = document.getElementById('exportCopyStatus');
  try {
    const resp = await fetch('/api/export/follow');
    const text = await resp.text();
    let copied = false;
    if(navigator.clipboard && window.isSecureContext) {
      try {
        await navigator.clipboard.writeText(text);
        copied = true;
      } catch(_) {}
    }
    if(!copied) {
      const ta = document.createElement('textarea');
      ta.value = text;
      ta.style.position = 'fixed';
      ta.style.left = '-9999px';
      ta.style.top = '0';
      ta.setAttribute('readonly', '');
      document.body.appendChild(ta);
      ta.focus();
      ta.select();
      ta.setSelectionRange(0, 99999);
      copied = document.execCommand('copy');
      document.body.removeChild(ta);
    }
    status.className = 'status-msg status-success';
    status.innerText = '✅ 已成功复制关注 JSON 到剪贴板！';
    setTimeout(() => { status.style.display = 'none'; }, 4000);
  } catch(e) {
    status.className = 'status-msg status-error';
    status.innerText = '❌ 复制失败：' + e;
  }
}

async function submitImportFollow() {
  const input = document.getElementById('followInput');
  const btn = document.getElementById('importBtn');
  const status = document.getElementById('importStatus');
  const text = input.value.trim();
  if(!text) {
    alert('请先输入或选择要导入的关注数据！');
    return;
  }
  try {
    JSON.parse(text);
  } catch(e) {
    status.className = 'status-msg status-error';
    status.innerText = '❌ JSON 格式不合法，请检查内容是否完整！';
    return;
  }
  const mode = document.querySelector('input[name="importMode"]:checked').value;
  btn.disabled = true;
  btn.innerText = '正在导入中...';
  status.style.display = 'none';
  try {
    const resp = await fetch('/sync/follow?overlay=' + mode, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: text
    });
    const res = await resp.json();
    status.style.display = 'block';
    if(res.status) {
      status.className = 'status-msg status-success';
      status.innerText = '🎉 ' + (res.message || '关注导入成功！');
      input.value = '';
      document.getElementById('fileName').innerText = '';
      loadFollows();
    } else {
      status.className = 'status-msg status-error';
      status.innerText = '❌ 导入失败：' + (res.message || '未知错误');
    }
  } catch(e) {
    status.style.display = 'block';
    status.className = 'status-msg status-error';
    status.innerText = '❌ 请求异常：' + e;
  } finally {
    btn.disabled = false;
    btn.innerText = '确认导入到电视';
  }
}

async function sendUrl() {
  const input = document.getElementById('urlInput');
  const btn = document.getElementById('sendBtn');
  const status = document.getElementById('pushStatus');
  const val = input.value.trim();
  if(!val) { alert('请先粘贴链接！'); return; }
  btn.disabled = true;
  btn.innerText = '正在投送中...';
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
      status.className = 'status-msg status-success';
      status.innerText = '🎉 ' + (res.message || '投送成功，电视正在播放！');
      input.value = '';
    } else {
      status.className = 'status-msg status-error';
      status.innerText = '❌ 投送失败：' + (res.message || '未知错误');
    }
  } catch(e) {
    status.style.display = 'block';
    status.className = 'status-msg status-error';
    status.innerText = '❌ 网络请求异常：' + e;
  } finally {
    btn.disabled = false;
    btn.innerText = '立即投送并播放';
  }
}

async function loadAccountStatus() {
  try {
    const resp = await fetch('/api/account/status');
    const data = await resp.json();
    if (data.douyu) {
      const b = document.getElementById('douyuBadge');
      const d = document.getElementById('douyuStatusDesc');
      const btn = document.getElementById('douyuLogoutBtn');
      if (data.douyu.logined) {
        b.innerText = '✅ 已登录: ' + (data.douyu.name || '斗鱼用户');
        b.style.background = '#4caf50';
        d.innerText = '已成功绑定斗鱼账号，可享受高清/原画永久免断流播放。UID: ' + (data.douyu.uid || '--');
        btn.style.display = 'inline-block';
      } else {
        b.innerText = '⚠️ 未登录';
        b.style.background = '#ff9800';
        d.innerText = '提示：未登录时由于斗鱼防盗链限制最高画质可能几分钟断流重连；登录后可享永久不断流租约。';
        btn.style.display = 'none';
      }
    }
    if (data.bilibili) {
      const b = document.getElementById('biliBadge');
      const d = document.getElementById('biliStatusDesc');
      const btn = document.getElementById('biliLogoutBtn');
      if (data.bilibili.logined) {
        b.innerText = '✅ 已登录: ' + (data.bilibili.name || 'B站用户');
        b.style.background = '#4caf50';
        d.innerText = '已成功绑定哔哩哔哩账号，支持高画质解码。';
        btn.style.display = 'inline-block';
      } else {
        b.innerText = '⚠️ 未登录';
        b.style.background = '#ff9800';
        d.innerText = '提示：未登录时最高仅能观看基础画质，登录后可同步原画/高码率权限。';
        btn.style.display = 'none';
      }
    }
  } catch (_) {}
}

async function saveDouyuCookie() {
  const input = document.getElementById('douyuCookieInput');
  const btn = document.getElementById('saveDouyuBtn');
  const status = document.getElementById('douyuStatusMsg');
  const val = input.value.trim();
  if(!val) { alert('请先粘贴斗鱼 Cookie！'); return; }
  btn.disabled = true;
  btn.innerText = '正在同步中...';
  status.style.display = 'none';
  try {
    const resp = await fetch('/sync/account/douyu', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ cookie: val })
    });
    const res = await resp.json();
    status.style.display = 'block';
    if(res.status) {
      status.className = 'status-msg status-success';
      status.innerText = '🎉 斗鱼账号已成功同步并登录！';
      input.value = '';
      loadAccountStatus();
    } else {
      status.className = 'status-msg status-error';
      status.innerText = '❌ 同步失败：' + (res.message || '未知错误');
    }
  } catch(e) {
    status.style.display = 'block';
    status.className = 'status-msg status-error';
    status.innerText = '❌ 请求异常：' + e;
  } finally {
    btn.disabled = false;
    btn.innerText = '保存并同步斗鱼 Cookie 到电视';
  }
}

async function saveBiliCookie() {
  const input = document.getElementById('biliCookieInput');
  const btn = document.getElementById('saveBiliBtn');
  const status = document.getElementById('biliStatusMsg');
  const val = input.value.trim();
  if(!val) { alert('请先粘贴 B站 Cookie！'); return; }
  btn.disabled = true;
  btn.innerText = '正在同步中...';
  status.style.display = 'none';
  try {
    const resp = await fetch('/sync/account/bilibili', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ cookie: val })
    });
    const res = await resp.json();
    status.style.display = 'block';
    if(res.status) {
      status.className = 'status-msg status-success';
      status.innerText = '🎉 哔哩哔哩账号已成功同步！';
      input.value = '';
      loadAccountStatus();
    } else {
      status.className = 'status-msg status-error';
      status.innerText = '❌ 同步失败：' + (res.message || '未知错误');
    }
  } catch(e) {
    status.style.display = 'block';
    status.className = 'status-msg status-error';
    status.innerText = '❌ 请求异常：' + e;
  } finally {
    btn.disabled = false;
    btn.innerText = '保存并同步 B站 Cookie 到电视';
  }
}

async function logoutAccount(type) {
  if(!confirm('确定要退出该账号登录状态吗？')) return;
  try {
    await fetch('/api/account/' + type + '/logout', { method: 'POST' });
    loadAccountStatus();
  } catch (_) {}
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
      final LiveRoomDetail detail;
      try {
        detail = await site.liveSite.getRoomDetail(roomId: parsed.roomId);
        if (detail.roomId.isEmpty) {
          throw '房间信息为空';
        }
      } catch (e) {
        return toJsonResponse({'success': false, 'message': '获取房间信息失败：$e'});
      }

      // 小红书平台单场次特性：关播后场次失效，不支持常驻关注；若有历史残留关注则自动清理
      if (parsed.siteId == Constant.kXiaohongshu && detail.userName.isNotEmpty) {
        _cleanXiaohongshuOldFollows(detail);
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

  bool _isSameXiaohongshuAnchor(String a, String b) {
    final cleanA = a.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
    final cleanB = b.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
    return cleanA.isNotEmpty && cleanA != "小红书主播" && cleanA == cleanB;
  }

  void _cleanXiaohongshuOldFollows(LiveRoomDetail detail) {
    try {
      final name = detail.userName.trim();
      if (name.isEmpty || name == "小红书主播") return;

      final allFollows = DBService.instance.getFollowList();
      final oldFollows = allFollows.where((f) =>
          f.siteId == Constant.kXiaohongshu &&
          _isSameXiaohongshuAnchor(f.userName, name)).toList();

      for (final old in oldFollows) {
        DBService.instance.deleteFollow(old.id);
      }
    } catch (e, stackTrace) {
      Log.e("小红书SyncService关注清理异常: $e", stackTrace);
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
