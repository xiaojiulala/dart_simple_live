import 'package:dio/dio.dart';
import 'package:simple_live_tv_app/app/constant.dart';
import 'package:simple_live_tv_app/app/log.dart';

class LiveParsedResult {
  final String siteId;
  final String roomId;
  final String originalUrl;

  const LiveParsedResult({
    required this.siteId,
    required this.roomId,
    required this.originalUrl,
  });
}

class LiveUrlParser {
  static final RegExp _urlRegex = RegExp(r'https?://[^\s\u4e00-\u9fa5\r\n]+');
  static final RegExp _roomIdPattern = RegExp(r'^[A-Za-z0-9._-]+$');
  static final RegExp _numericPattern = RegExp(r'^\d+$');

  /// 从可能包含中文文案的分享文本中提取纯 URL
  static String extractUrl(String text) {
    final match = _urlRegex.firstMatch(text.trim());
    if (match != null) {
      return match.group(0) ?? text.trim();
    }
    return text.trim();
  }

  /// 解析输入文本（支持直接链接、短链展开、包含分享词的多余文案）
  static Future<LiveParsedResult?> parseFromText(String text) async {
    final rawUrl = extractUrl(text);
    if (rawUrl.isEmpty) {
      return null;
    }

    // 1. 尝试跟随短链接跳转
    String resolvedUrl = rawUrl;
    if (_isShortLink(rawUrl)) {
      resolvedUrl = await _resolveRedirect(rawUrl);
    }

    // 2. 解析最终目标 URL
    return _parseDirectUrl(resolvedUrl, original: text);
  }

  static bool _isShortLink(String url) {
    try {
      final uri = Uri.tryParse(url.startsWith("http") ? url : "https://$url");
      if (uri == null) return false;
      final host = uri.host.toLowerCase();
      return host == "b23.tv" || host == "v.douyin.com";
    } catch (_) {
      return false;
    }
  }

  static Future<String> _resolveRedirect(String url, {int maxHops = 3}) async {
    String currentUrl = url.startsWith("http") ? url : "https://$url";
    final dio = Dio(
      BaseOptions(
        followRedirects: false,
        validateStatus: (status) => status != null && status < 400,
        connectTimeout: const Duration(seconds: 5),
        receiveTimeout: const Duration(seconds: 5),
        headers: {
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        },
      ),
    );

    for (int i = 0; i < maxHops; i++) {
      try {
        final resp = await dio.get(currentUrl);
        if (resp.statusCode == 301 ||
            resp.statusCode == 302 ||
            resp.statusCode == 303 ||
            resp.statusCode == 307 ||
            resp.statusCode == 308) {
          final location = resp.headers.value("location");
          if (location != null && location.isNotEmpty) {
            if (location.startsWith("http")) {
              currentUrl = location;
            } else {
              currentUrl = Uri.parse(currentUrl).resolve(location).toString();
            }
            continue;
          }
        }
        break;
      } catch (e) {
        Log.d("短链重定向解析失败: $e");
        break;
      }
    }
    return currentUrl;
  }

  static LiveParsedResult? _parseDirectUrl(String url, {required String original}) {
    var text = url.trim();
    if (!text.startsWith("http://") && !text.startsWith("https://")) {
      text = "https://$text";
    }
    final uri = Uri.tryParse(text);
    if (uri == null || uri.host.isEmpty) {
      return null;
    }

    final host = uri.host.toLowerCase();
    final segments =
        uri.pathSegments.where((s) => s.isNotEmpty).toList();

    // 1. 哔哩哔哩 (live.bilibili.com / bilibili.com)
    if (host == "live.bilibili.com" || host.endsWith(".bilibili.com")) {
      if (host == "live.bilibili.com") {
        if (segments.isNotEmpty) {
          final first = segments.first;
          if (first == "blanc" && segments.length > 1) {
            return _buildResult(Constant.kBiliBili, segments[1], original);
          }
          if (_roomIdPattern.hasMatch(first)) {
            return _buildResult(Constant.kBiliBili, first, original);
          }
        }
      }
    }

    // 2. 斗鱼 (douyu.com)
    if (host == "douyu.com" || host.endsWith(".douyu.com")) {
      if (segments.isNotEmpty) {
        if (segments.first == "topic") {
          final rid = uri.queryParameters["rid"] ?? "";
          if (_numericPattern.hasMatch(rid)) {
            return _buildResult(Constant.kDouyu, rid, original);
          }
        }
        if (segments.first == "room" &&
            segments.length > 2 &&
            segments[1] == "share") {
          return _buildResult(Constant.kDouyu, segments[2], original);
        }
        final first = segments.first;
        if (_roomIdPattern.hasMatch(first)) {
          return _buildResult(Constant.kDouyu, first, original);
        }
      }
    }

    // 3. 虎牙 (huya.com)
    if (host == "huya.com" || host.endsWith(".huya.com")) {
      if (segments.isNotEmpty) {
        final first = segments.first;
        if (_roomIdPattern.hasMatch(first)) {
          return _buildResult(Constant.kHuya, first, original);
        }
      }
    }

    // 4. 抖音 (live.douyin.com / douyin.com / webcast.amemv.com)
    if (host == "live.douyin.com") {
      if (segments.isNotEmpty) {
        final first = segments.first;
        if (_roomIdPattern.hasMatch(first)) {
          return _buildResult(Constant.kDouyin, first, original);
        }
      }
    }

    if (host == "douyin.com" || host.endsWith(".douyin.com")) {
      if (segments.length >= 2 && segments[0] == "live") {
        return _buildResult(Constant.kDouyin, segments[1], original);
      }
      if (segments.length >= 3 &&
          segments[0] == "follow" &&
          segments[1] == "live") {
        return _buildResult(Constant.kDouyin, segments[2], original);
      }
    }

    if (host.endsWith(".amemv.com")) {
      final reflowIdx = segments.indexOf("reflow");
      if (reflowIdx >= 0 && reflowIdx + 1 < segments.length) {
        final roomId = segments[reflowIdx + 1];
        if (_numericPattern.hasMatch(roomId)) {
          return _buildResult(Constant.kDouyin, roomId, original);
        }
      }
    }

    return null;
  }

  static LiveParsedResult? _buildResult(
    String siteId,
    String roomId,
    String original,
  ) {
    final cleanId = roomId.trim();
    if (cleanId.isEmpty) return null;
    return LiveParsedResult(
      siteId: siteId,
      roomId: cleanId,
      originalUrl: original,
    );
  }
}
