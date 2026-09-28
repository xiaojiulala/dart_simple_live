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
      serverRouter.get('/parse', _serveWebDashboardRequest);
      serverRouter.get('/parse/', _serveWebDashboardRequest);
      serverRouter.post('/api/parse_play', _parsePlayApiRequest);
      serverRouter.get('/api/export/follow', _downloadFollowJsonRequest);
      serverRouter.get('/api/export/history', _downloadHistoryJsonRequest);
      serverRouter.get('/api/follows', _getFollowListJsonRequest);

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

  shelf.Response _serveWebDashboardRequest(shelf.Request request) {
    const html = '''<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
<title>SimpleLive TV 控制台</title>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body {
    background-color: #121212;
    color: #e0e0e0;
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    padding: 16px;
    line-height: 1.5;
  }
  .container { max-width: 680px; margin: 0 auto; }
  header { text-align: center; margin-bottom: 20px; }
  h1 { font-size: 22px; color: #ff6699; margin-bottom: 4px; display: flex; align-items: center; justify-content: center; gap: 8px; }
  .badge-dev { font-size: 12px; color: #888; }

  /* Navigation Tabs */
  .tabs { display: flex; gap: 8px; margin-bottom: 18px; border-bottom: 1px solid #2a2a2a; padding-bottom: 8px; }
  .tab-btn {
    flex: 1;
    background: transparent;
    border: none;
    color: #888;
    font-size: 15px;
    font-weight: 600;
    padding: 10px 4px;
    cursor: pointer;
    border-radius: 6px;
    transition: all 0.2s;
  }
  .tab-btn.active { background: #1e1e1e; color: #ff6699; }

  /* Cards */
  .card {
    background: #1a1a1a;
    border: 1px solid #2c2c2c;
    border-radius: 10px;
    padding: 18px;
    margin-bottom: 16px;
  }
  .card-title { font-size: 16px; font-weight: bold; margin-bottom: 12px; color: #fff; display: flex; align-items: center; justify-content: space-between; }
  .btn {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    padding: 10px 16px;
    border-radius: 6px;
    font-size: 14px;
    font-weight: 600;
    cursor: pointer;
    text-decoration: none;
    border: none;
    transition: opacity 0.2s;
  }
  .btn:hover { opacity: 0.9; }
  .btn-primary { background: #ff6699; color: #fff; }
  .btn-secondary { background: #2a2a2a; color: #fff; border: 1px solid #444; }
  .btn-outline { background: transparent; color: #ff6699; border: 1px solid #ff6699; }
  .btn-block { width: 100%; }
  .btn-group { display: flex; gap: 10px; flex-wrap: wrap; margin-bottom: 14px; }
  .btn-sm { padding: 6px 12px; font-size: 12px; }

  textarea {
    width: 100%;
    height: 110px;
    background: #121212;
    border: 1px solid #333;
    border-radius: 6px;
    color: #fff;
    padding: 10px;
    font-size: 13px;
    font-family: monospace;
    resize: vertical;
    outline: none;
    margin-bottom: 12px;
  }
  textarea:focus { border-color: #ff6699; }

  /* Radio Group */
  .radio-group {
    background: #121212;
    border: 1px solid #282828;
    border-radius: 6px;
    padding: 10px;
    margin-bottom: 12px;
    font-size: 13px;
  }
  .radio-group label {
    display: flex;
    align-items: center;
    gap: 8px;
    cursor: pointer;
    margin-bottom: 6px;
  }
  .radio-group label:last-child { margin-bottom: 0; }
  .radio-group input[type="radio"] { accent-color: #ff6699; }

  .status-msg {
    margin-top: 10px;
    padding: 10px 14px;
    border-radius: 6px;
    font-size: 13px;
    display: none;
  }
  .status-success { background: #1b3a24; color: #4ade80; border: 1px solid #22543d; display: block; }
  .status-error { background: #3a1b1b; color: #f87171; border: 1px solid #542222; display: block; }

  /* Follow item list */
  .follow-list {
    max-height: 320px;
    overflow-y: auto;
    border: 1px solid #282828;
    border-radius: 6px;
    background: #121212;
  }
  .follow-item {
    display: flex;
    align-items: center;
    padding: 10px;
    border-bottom: 1px solid #1f1f1f;
    gap: 12px;
  }
  .follow-item:last-child { border-bottom: none; }
  .site-tag {
    font-size: 11px;
    padding: 2px 6px;
    border-radius: 4px;
    font-weight: bold;
  }
  .site-bilibili { background: #00aeec; color: #fff; }
  .site-douyu { background: #ff5d23; color: #fff; }
  .site-huya { background: #ffaa00; color: #000; }
  .site-douyin { background: #fe2c55; color: #fff; }
  .site-other { background: #555; color: #fff; }
  .follow-avatar { width: 36px; height: 36px; border-radius: 50%; object-fit: cover; background: #2a2a2a; }
  .follow-info { flex: 1; min-width: 0; }
  .follow-name { font-size: 14px; font-weight: bold; color: #fff; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .follow-sub { font-size: 12px; color: #777; }

  .tip-box {
    background: #141414;
    border-radius: 6px;
    padding: 12px;
    font-size: 12px;
    color: #888;
    line-height: 1.8;
  }
</style>
</head>
<body>
<div class="container">
  <header>
    <h1>📺 SimpleLive TV 控制台</h1>
    <div class="badge-dev" id="headerInfo">Simple Live TV 内网管理与投送平台</div>
  </header>

  <div class="tabs">
    <button class="tab-btn active" id="tabBtn-follow" onclick="switchTab('follow')">⭐️ 关注管理</button>
    <button class="tab-btn" id="tabBtn-push" onclick="switchTab('push')">🚀 投送直播</button>
    <button class="tab-btn" id="tabBtn-history" onclick="switchTab('history')">🕒 历史记录</button>
  </div>

  <!-- 关注管理页面 -->
  <div id="tab-follow">
    <div class="card">
      <div class="card-title">
        <span>📥 导出关注</span>
        <span style="font-size:13px;color:#ff6699;" id="followTotalBadge">关注数：--</span>
      </div>
      <p style="font-size:13px;color:#888;margin-bottom:12px;">直接下载或复制 JSON 格式关注备份文件：</p>
      <div class="btn-group">
        <a href="/api/export/follow" class="btn btn-primary" download="simple_live_tv_follows.json">⬇️ 下载关注 JSON</a>
        <button type="button" onclick="copyFollowJson()" class="btn btn-secondary">📋 复制全部 JSON</button>
        <button type="button" onclick="loadFollows()" class="btn btn-secondary">🔄 刷新列表</button>
      </div>
      <div id="exportCopyStatus" class="status-msg"></div>
    </div>

    <div class="card">
      <div class="card-title">
        <span>📤 导入关注到电视</span>
      </div>
      <div style="margin-bottom:12px;">
        <input type="file" id="followFileInput" accept=".json,application/json" onchange="handleFileSelect(event)" style="display:none">
        <button type="button" onclick="document.getElementById('followFileInput').click()" class="btn btn-outline btn-sm">📁 从手机/电脑选择 .json 文件</button>
        <span id="fileName" style="font-size:12px;color:#aaa;margin-left:8px;"></span>
      </div>
      <textarea id="followInput" placeholder="在此粘贴关注列表 JSON 数据，或点击上方直接选择 .json 文件..."></textarea>
      
      <div class="radio-group">
        <label>
          <input type="radio" name="importMode" value="0" checked>
          <span><b>增量合并（推荐）</b>：保留电视现有关注，仅添加新关注或更新</span>
        </label>
        <label>
          <input type="radio" name="importMode" value="1">
          <span><b>覆盖替换</b>：清空电视现有关注，完全替换为导入列表</span>
        </label>
      </div>

      <button id="importBtn" onclick="submitImportFollow()" class="btn btn-primary btn-block">确认导入到电视</button>
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

  <!-- 投送直播页面 -->
  <div id="tab-push" style="display:none;">
    <div class="card">
      <div class="card-title"><span>🚀 投送直播间到电视</span></div>
      <p style="font-size:13px;color:#888;margin-bottom:12px;">粘贴直播间链接或分享文本，电视端将自动解析并直接播放：</p>
      <textarea id="urlInput" placeholder="在此粘贴哔哩哔哩、斗鱼、虎牙或抖音直播间分享链接或口令..."></textarea>
      <button id="sendBtn" onclick="sendUrl()" class="btn btn-primary btn-block">立即投送并播放</button>
      <div id="pushStatus" class="status-msg"></div>
    </div>

    <div class="tip-box">
      <b>支持平台及链接说明：</b><br>
      • <b>哔哩哔哩</b>：live.bilibili.com / b23.tv 短链<br>
      • <b>斗鱼直播</b>：douyu.com 房间及专题页链接<br>
      • <b>虎牙直播</b>：huya.com 房间链接<br>
      • <b>抖音直播</b>：live.douyin.com / v.douyin.com 短链
    </div>
  </div>

  <!-- 历史记录页面 -->
  <div id="tab-history" style="display:none;">
    <div class="card">
      <div class="card-title"><span>🕒 观看历史导出</span></div>
      <p style="font-size:13px;color:#888;margin-bottom:14px;">下载电视端的观看历史记录 JSON 备份：</p>
      <a href="/api/export/history" class="btn btn-primary" download="simple_live_tv_history.json">⬇️ 下载观看历史 JSON</a>
    </div>
  </div>
</div>

<script>
function switchTab(name) {
  ['follow', 'push', 'history'].forEach(t => {
    const el = document.getElementById('tab-' + t);
    const btn = document.getElementById('tabBtn-' + t);
    if (el) el.style.display = (t === name) ? 'block' : 'none';
    if (btn) {
      if (t === name) btn.classList.add('active');
      else btn.classList.remove('active');
    }
  });
}

function getSiteBadge(siteId) {
  switch((siteId || '').toLowerCase()) {
    case 'bilibili': return '<span class="site-tag site-bilibili">B站</span>';
    case 'douyu': return '<span class="site-tag site-douyu">斗鱼</span>';
    case 'huya': return '<span class="site-tag site-huya">虎牙</span>';
    case 'douyin': return '<span class="site-tag site-douyin">抖音</span>';
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
        const avatar = pic ? '<img class="follow-avatar" src="' + pic + '" onerror="this.style.display=\\'none\\'" />' : '<div class="follow-avatar"></div>';
        html += '<div class="follow-item">' +
          avatar +
          '<div class="follow-info">' +
            '<div class="follow-name">' + (u.userName || '未知主播') + '</div>' +
            '<div class="follow-sub">' + (u.roomId || '') + '</div>' +
          '</div>' +
          getSiteBadge(u.siteId) +
        '</div>';
      }
      preview.innerHTML = html;
    } else {
      badge.innerText = '关注数：--';
      preview.innerHTML = '<div style="padding:20px;text-align:center;color:#f87171;font-size:13px;">加载失败：' + (res.message || '未知错误') + '</div>';
    }
  } catch(e) {
    badge.innerText = '关注数：--';
    preview.innerHTML = '<div style="padding:20px;text-align:center;color:#f87171;font-size:13px;">网络请求失败：' + e + '</div>';
  }
}

function handleFileSelect(evt) {
  const file = evt.target.files[0];
  if(!file) return;
  document.getElementById('fileName').innerText = file.name;
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
    if(navigator.clipboard && navigator.clipboard.writeText) {
      await navigator.clipboard.writeText(text);
    } else {
      const ta = document.createElement('textarea');
      ta.value = text;
      document.body.appendChild(ta);
      ta.select();
      document.execCommand('copy');
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
    if(res.success) {
      status.className = 'status-msg status-success';
      status.innerText = '🎉 ' + (res.message || '投送成功，电视正在播放！');
      input.value = '';
    } else {
      status.className = 'status-msg status-error';
      status.innerText = '❌ 投送失败：' + (res.message || '未知错误');
    }
  } catch(e) {
    status.className = 'status-msg status-error';
    status.innerText = '❌ 网络请求异常：' + e;
  } finally {
    btn.disabled = false;
    btn.innerText = '立即投送并播放';
  }
}

// 页面加载完成后拉取一次关注
document.addEventListener('DOMContentLoaded', () => {
  loadFollows();
});
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
