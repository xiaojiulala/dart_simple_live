import 'dart:convert';

import 'package:simple_live_core/src/common/core_error.dart';
import 'package:simple_live_core/src/common/http_client.dart';
import 'package:simple_live_core/src/interface/live_danmaku.dart';
import 'package:simple_live_core/src/interface/live_site.dart';
import 'package:simple_live_core/src/model/live_category.dart';
import 'package:simple_live_core/src/model/live_category_result.dart';
import 'package:simple_live_core/src/model/live_play_quality.dart';
import 'package:simple_live_core/src/model/live_play_url.dart';
import 'package:simple_live_core/src/model/live_room_detail.dart';
import 'package:simple_live_core/src/model/live_room_item.dart';
import 'package:simple_live_core/src/model/live_search_result.dart';

class XiaohongshuSite extends LiveSite {
  static const String kDefaultUserAgent =
      'Mozilla/5.0 (Linux; Android 11) AppleWebKit/537.36 Chrome/87.0.4280.141 Mobile Safari/537.36';
  static const String kDefaultReferer = 'https://www.xiaohongshu.com/';

  static final RegExp _statePattern = RegExp(
    r'window\.__INITIAL_STATE__\s*=\s*(.+?)</script>',
    dotAll: true,
  );

  @override
  String id = "xiaohongshu";

  @override
  String name = "小红书";

  /// 小红书官方无开放 Web 弹幕协议，返回空实现的 LiveDanmaku
  @override
  LiveDanmaku getDanmaku() => LiveDanmaku();

  @override
  Future<List<LiveCategory>> getCategores() {
    return Future.value(<LiveCategory>[]);
  }

  @override
  Future<LiveCategoryResult> getCategoryRooms(
    LiveSubCategory category, {
    int page = 1,
  }) {
    return Future.value(
      LiveCategoryResult(hasMore: false, items: <LiveRoomItem>[]),
    );
  }

  @override
  Future<LiveCategoryResult> getRecommendRooms({int page = 1}) {
    return Future.value(
      LiveCategoryResult(hasMore: false, items: <LiveRoomItem>[]),
    );
  }

  @override
  Future<LiveRoomDetail> getRoomDetail({required String roomId}) async {
    final cleanId = _sanitizeRoomId(roomId);
    if (cleanId.isEmpty) {
      throw CoreError("无效的小红书房间号");
    }

    final url = "https://www.xiaohongshu.com/livestream/$cleanId";
    final html = await HttpClient.instance.getText(
      url,
      header: {
        'Referer': kDefaultReferer,
        'User-Agent': kDefaultUserAgent,
      },
    );

    final root = _extractState(html);
    final liveStream = root['liveStream'];
    if (liveStream is! Map) {
      throw CoreError("小红书直播数据缺失");
    }
    if (liveStream['pageStatus'] == 'error') {
      throw CoreError("该小红书直播间不存在或已关闭");
    }

    final roomData = liveStream['roomData'];
    if (roomData is! Map) {
      throw CoreError("小红书房间信息缺失");
    }
    final roomInfo = roomData['roomInfo'] is Map ? roomData['roomInfo'] as Map : {};
    final hostInfo = roomData['hostInfo'] is Map ? roomData['hostInfo'] as Map : {};

    final status = roomInfo['status'];
    final bool isLive = status == 2;
    final String title = roomInfo['roomTitle']?.toString() ?? '小红书直播';
    final String cover = roomInfo['roomCover']?.toString() ?? '';
    final String userName = hostInfo['nickName']?.toString() ?? '小红书主播';
    final String userAvatar = hostInfo['avatar']?.toString() ?? '';
    final int online =
        int.tryParse(roomInfo['displayViewerCount']?.toString() ?? '') ?? 0;
    final String pullConfig = roomInfo['pullConfig']?.toString() ?? '';

    return LiveRoomDetail(
      roomId: cleanId,
      title: title,
      cover: cover,
      userName: userName,
      userAvatar: userAvatar,
      online: online,
      status: isLive,
      url: url,
      data: pullConfig,
    );
  }

  @override
  Future<List<LivePlayQuality>> getPlayQualites({
    required LiveRoomDetail detail,
  }) async {
    if (!detail.status || detail.data == null || detail.data.toString().isEmpty) {
      return [];
    }

    dynamic config;
    try {
      config = json.decode(detail.data.toString());
    } catch (_) {
      return [];
    }

    if (config is! Map) {
      return [];
    }

    final qualities = <LivePlayQuality>[];
    for (final codec in ['h264', 'h265']) {
      final rows = config[codec];
      if (rows is! List) continue;
      for (final item in rows) {
        if (item is! Map) continue;
        final url = item['master_url']?.toString() ?? '';
        final qualityType = item['quality_type']?.toString() ?? '';
        final qualityName = item['quality_type_name']?.toString() ?? '';
        if (url.isEmpty || qualityName.isEmpty) continue;

        final label = '$qualityName (${codec.toUpperCase()})';
        var sort = _qualitySort(qualityType);
        if (codec.toLowerCase() == 'h264') {
          sort += 5; // 提高 H264 优先级以保证电视端播放兼容性
        }
        qualities.add(
          LivePlayQuality(
            quality: label,
            data: url,
            sort: sort,
          ),
        );
      }
    }

    qualities.sort((a, b) => b.sort.compareTo(a.sort));
    return qualities;
  }

  @override
  Future<LivePlayUrl> getPlayUrls({
    required LiveRoomDetail detail,
    required LivePlayQuality quality,
  }) async {
    final playUrl = quality.data?.toString() ?? '';
    if (playUrl.isEmpty) {
      throw CoreError("小红书播放地址为空");
    }
    return LivePlayUrl(
      urls: [playUrl],
      headers: {
        'Referer': kDefaultReferer,
        'User-Agent': kDefaultUserAgent,
      },
    );
  }

  @override
  Future<bool> getLiveStatus({required String roomId}) async {
    try {
      final detail = await getRoomDetail(roomId: roomId);
      return detail.status;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<LiveSearchRoomResult> searchRooms(
    String keyword, {
    int page = 1,
  }) async {
    if (page != 1) {
      return LiveSearchRoomResult(hasMore: false, items: []);
    }
    final cleanId = _sanitizeRoomId(keyword);
    if (cleanId.isEmpty) {
      return LiveSearchRoomResult(hasMore: false, items: []);
    }
    try {
      final detail = await getRoomDetail(roomId: cleanId);
      return LiveSearchRoomResult(
        hasMore: false,
        items: [
          LiveRoomItem(
            roomId: detail.roomId,
            title: detail.title,
            cover: detail.cover,
            userName: detail.userName,
            online: detail.online,
          ),
        ],
      );
    } catch (_) {
      return LiveSearchRoomResult(hasMore: false, items: []);
    }
  }

  static String _sanitizeRoomId(String input) {
    final trimmed = input.trim();
    if (RegExp(r'^[1-9][0-9]{0,19}$').hasMatch(trimmed)) {
      return trimmed;
    }
    // 匹配常规或 dynamic 链接中的数字房间号
    final match = RegExp(r'/livestream/(?:dynpath[A-Za-z0-9]+/)?([1-9][0-9]{0,19})').firstMatch(trimmed);
    if (match != null) {
      return match.group(1) ?? '';
    }
    final legacyMatch = RegExp(r'/hina/livestream/([1-9][0-9]{0,19})').firstMatch(trimmed);
    if (legacyMatch != null) {
      return legacyMatch.group(1) ?? '';
    }
    final deepMatch = RegExp(r'room_id=([1-9][0-9]{0,19})').firstMatch(trimmed);
    if (deepMatch != null) {
      return deepMatch.group(1) ?? '';
    }
    return '';
  }

  static Map<String, dynamic> _extractState(String html) {
    final match = _statePattern.firstMatch(html);
    if (match == null) {
      throw CoreError("未能解析小红书页面状态数据");
    }
    var source = match.group(1)?.trim() ?? '';
    if (source.endsWith(';')) {
      source = source.substring(0, source.length - 1).trim();
    }
    final cleanJson = _hydrationJson(source);
    try {
      final decoded = json.decode(cleanJson);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      throw CoreError("小红书页面数据格式不正确");
    } catch (e) {
      if (e is CoreError) rethrow;
      throw CoreError("小红书页面 JSON 解析失败: $e");
    }
  }

  /// 仅将不在引号字符串内的裸 undefined 替换为 null，避免破坏可能含有该词的标题/URL
  static String _hydrationJson(String source) {
    final result = StringBuffer();
    var quoted = false;
    var escaped = false;
    for (var i = 0; i < source.length; i++) {
      final char = source[i];
      if (quoted) {
        result.write(char);
        if (escaped) {
          escaped = false;
        } else if (char == r'\') {
          escaped = true;
        } else if (char == '"') {
          quoted = false;
        }
      } else if (char == '"') {
        quoted = true;
        result.write(char);
      } else if (source.startsWith('undefined', i)) {
        result.write('null');
        i += 'undefined'.length - 1;
      } else {
        result.write(char);
      }
    }
    return result.toString();
  }

  static int _qualitySort(String qualityType) {
    final q = qualityType.toLowerCase();
    if (q.contains("4k")) return 1000;
    if (q.contains("1080p") || q.contains("1080")) return 800;
    if (q.contains("720p") || q.contains("720")) return 600;
    if (q.contains("480p") || q.contains("480")) return 400;
    if (q.contains("360p") || q.contains("360")) return 200;
    return 100;
  }
}
