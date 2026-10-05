import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_tv_app/app/app_focus_node.dart';

class Sites {
  static final Map<String, Site> allSites = {
    "bilibili": Site(
      id: "bilibili",
      logo: "assets/images/bilibili_2.png",
      name: "哔哩哔哩",
      liveSite: BiliBiliSite(),
      index: 0,
    ),
    "douyu": Site(
      id: "douyu",
      logo: "assets/images/douyu.png",
      name: "斗鱼直播",
      liveSite: DouyuSite(),
      index: 1,
    ),
    "huya": Site(
      id: "huya",
      logo: "assets/images/huya.png",
      name: "虎牙直播",
      liveSite: HuyaSite(),
      index: 2,
    ),
    "douyin": Site(
      id: "douyin",
      logo: "assets/images/douyin.png",
      name: "抖音直播",
      liveSite: DouyinSite(),
      index: 3,
    ),
    "xiaohongshu": Site(
      id: "xiaohongshu",
      logo: "assets/images/xiaohongshu.png",
      name: "小红书",
      liveSite: XiaohongshuSite(),
      index: 4,
    ),
  };

  /// 供分类大厅与热门直播浏览的平台（排除无官方公共类目推荐的大厅平台）
  static List<Site> get supportSites {
    return allSites.values.where((s) => s.id != "xiaohongshu").toList();
  }
}

class Site {
  final String id;
  final String name;
  final String logo;
  final LiveSite liveSite;
  final int index;
  AppFocusNode appFocusNode = AppFocusNode();
  Site({
    required this.id,
    required this.liveSite,
    required this.logo,
    required this.name,
    required this.index,
  });
}
