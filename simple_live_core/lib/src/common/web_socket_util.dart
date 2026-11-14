import 'dart:async';

import 'package:web_socket_channel/io.dart';

enum SocketStatus { connected, failed, closed }

class WebScoketUtils {
  SocketStatus status = SocketStatus.closed;

  /// 链接
  final String url;

  /// 备用链接
  final String? backupUrl;

  /// 备用链接列表
  final List<String> backupUrls;

  /// 心跳时间
  final int heartBeatTime;

  /// 接收到信息
  final Function(dynamic)? onMessage;

  /// 连接关闭
  final Function(String msg)? onClose;

  /// 尝试重连
  final Function()? onReconnect;

  /// 准备就绪
  final Function()? onReady;

  /// 心跳
  final Function()? onHeartBeat;

  /// 请求头
  Map<String, dynamic>? headers;
  WebScoketUtils({
    required this.url,
    required this.heartBeatTime,
    this.onMessage,
    this.onClose,
    this.onReconnect,
    this.onReady,
    this.onHeartBeat,
    this.headers,
    this.backupUrl,
    this.backupUrls = const [],
  });
  IOWebSocketChannel? webSocket;
  Timer? heartBeatTimer;

  /// 重连次数
  int reconnectTime = 0;
  Timer? reconnectTimer;

  /// 最大重连次数
  int maxReconnectTime = 5;
  bool _manualClosed = false;
  bool _isConnecting = false;

  StreamSubscription<dynamic>? streamSubscription;

  List<String> get _connectUrls {
    final urls = <String>[url];
    if (backupUrl != null && backupUrl!.isNotEmpty) {
      urls.add(backupUrl!);
    }
    urls.addAll(backupUrls.where((url) => url.isNotEmpty));
    return urls.toSet().toList();
  }

  void _cleanupConnection() {
    streamSubscription?.cancel();
    streamSubscription = null;

    try {
      webSocket?.sink.close();
    } catch (_) {}
    webSocket = null;

    heartBeatTimer?.cancel();
    heartBeatTimer = null;
  }

  void connect({bool retry = false}) {
    _manualClosed = false;
    _connectInternal(retry: retry);
  }

  Future<void> _connectInternal({bool retry = false}) async {
    if (_manualClosed || _isConnecting) {
      return;
    }
    _isConnecting = true;
    status = SocketStatus.closed;
    _cleanupConnection();

    final urls = (retry && _connectUrls.length > 1)
        ? _connectUrls.skip(1).toList()
        : _connectUrls;
    Object? lastError;
    StackTrace? lastStackTrace;
    try {
      for (final wsurl in urls) {
        if (_manualClosed) {
          return;
        }
        IOWebSocketChannel? channel;
        try {
          channel = IOWebSocketChannel.connect(
            wsurl,
            connectTimeout: Duration(seconds: 10),
            headers: headers,
          );

          await channel.ready;
          if (_manualClosed) {
            try {
              await channel.sink.close();
            } catch (_) {}
            return;
          }
          webSocket = channel;
          _isConnecting = false;
          ready();
          return;
        } catch (e, s) {
          lastError = e;
          lastStackTrace = s;
          try {
            await channel?.sink.close();
          } catch (_) {}
          webSocket = null;
        }
      }
    } finally {
      _isConnecting = false;
    }

    if (_manualClosed) {
      return;
    }
    onError(lastError ?? "WebSocket connection failed", lastStackTrace);
    reconnect();
  }

  /// 连接完成
  void ready() {
    if (_manualClosed) {
      _cleanupConnection();
      return;
    }
    reconnectTimer?.cancel();
    reconnectTimer = null;
    status = SocketStatus.connected;

    streamSubscription = webSocket?.stream.listen(
      (data) => receiveMessage(data),
      onError: (e, s) => onError(e, s),
      onDone: onDone,
    );

    onReady?.call();
    initHeartBeat();
  }

  void initHeartBeat() {
    heartBeatTimer?.cancel();
    heartBeatTimer = Timer.periodic(Duration(milliseconds: heartBeatTime), (
      timer,
    ) {
      onHeartBeat?.call();
    });
  }

  void receiveMessage(dynamic data) {
    //接受到一条信息才算重连成功
    reconnectTime = 0;
    onMessage?.call(data);
  }

  void onError(e, s) {
    if (_manualClosed) {
      return;
    }
    status = SocketStatus.failed;
    onClose?.call(e.toString());
  }

  void onDone() {
    if (_manualClosed || status == SocketStatus.closed) {
      return;
    }
    onReconnect?.call();
    reconnect();
  }

  void sendMessage(dynamic message) {
    if (status == SocketStatus.connected) {
      try {
        webSocket?.sink.add(message);
      } catch (_) {}
    }
  }

  void close() {
    _manualClosed = true;
    status = SocketStatus.closed;
    reconnectTime = 0;

    reconnectTimer?.cancel();
    reconnectTimer = null;

    _cleanupConnection();
  }

  void reconnect() {
    if (_manualClosed) {
      return;
    }
    if (reconnectTimer?.isActive ?? false) {
      return;
    }
    status = SocketStatus.closed;
    if (reconnectTime < maxReconnectTime) {
      reconnectTime++;
      reconnectTimer = Timer(Duration(seconds: 5), () {
        reconnectTimer = null;
        if (!_manualClosed) {
          _connectInternal();
        }
      });
    } else {
      onClose?.call("重连超过最大次数，与服务器断开连接");
      close();
      return;
    }
  }
}
