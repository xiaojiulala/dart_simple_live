import 'package:flutter/material.dart';
import 'package:get/get.dart';

/// 拓展FoucsNode
class AppFocusNode extends FocusNode {
  var isFoucsed = false.obs;
  AppFocusNode() {
    isFoucsed.value = hasFocus;
    addListener(updateFoucs);
  }

  void updateFoucs() {
    if (isFoucsed.value != hasFocus) {
      isFoucsed.value = hasFocus;
    }
  }

  /// 强制清空失焦状态，避免列表项卸载后残存假焦点
  void forceUnfocus() {
    if (hasFocus) {
      unfocus();
    }
    isFoucsed.value = false;
  }

  @override
  void dispose() {
    removeListener(updateFoucs);
    super.dispose();
  }
}
