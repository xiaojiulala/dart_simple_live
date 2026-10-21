import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_tv_app/modules/multi_room/multi_room_models.dart';
import 'package:simple_live_tv_app/modules/multi_room/multi_room_player_controller.dart';
import 'package:simple_live_tv_app/services/follow_user_service.dart';
import 'package:simple_live_tv_app/modules/home/home_controller.dart';

class MultiRoomController extends GetxController {
  final List<MultiRoomItem> initialRooms;

  MultiRoomController(this.initialRooms);

  final rooms = <MultiRoomItem>[].obs;

  @override
  void onInit() {
    FollowUserService.instance.isInLiveRoom = true;
    super.onInit();
    rooms.assignAll(_distinct(initialRooms));
  }

  List<MultiRoomItem> _distinct(Iterable<MultiRoomItem> items) {
    final result = <MultiRoomItem>[];
    final keys = <String>{};
    for (final item in items) {
      if (keys.add(item.key)) {
        result.add(item);
      }
    }
    return result;
  }

  String playerTag(MultiRoomItem item) => item.key;

  MultiRoomPlayerController playerFor(MultiRoomItem item) {
    final tag = playerTag(item);
    if (Get.isRegistered<MultiRoomPlayerController>(tag: tag)) {
      return Get.find<MultiRoomPlayerController>(tag: tag);
    }
    return Get.put(MultiRoomPlayerController(item), tag: tag);
  }

  void removeRoom(MultiRoomItem item) {
    rooms.removeWhere((room) => room.key == item.key);
    final tag = playerTag(item);
    if (Get.isRegistered<MultiRoomPlayerController>(tag: tag)) {
      Get.delete<MultiRoomPlayerController>(tag: tag);
    }
    if (rooms.isEmpty) {
      SmartDialog.showToast("已关闭全部同播直播间");
      Get.back();
    }
  }

  @override
  void onClose() {
    for (final item in rooms) {
      final tag = playerTag(item);
      if (Get.isRegistered<MultiRoomPlayerController>(tag: tag)) {
        Get.delete<MultiRoomPlayerController>(tag: tag);
      }
    }
    FollowUserService.instance.onExitLiveRoom();
    if (Get.isRegistered<HomeController>()) {
      Get.find<HomeController>().resetToTopAndFocusFirstRoom();
    }
    super.onClose();
  }
}
