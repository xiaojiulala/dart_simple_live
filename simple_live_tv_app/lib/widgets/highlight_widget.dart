import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:simple_live_tv_app/app/app_focus_node.dart';
import 'package:simple_live_tv_app/app/app_style.dart';

typedef FocusOnKeyDownCallback = KeyEventResult Function();

/// 高亮组件
class HighlightWidget extends StatelessWidget {
  final AppFocusNode focusNode;
  final Widget child;
  final FocusOnKeyDownCallback? onUpKey;
  final FocusOnKeyDownCallback? onDownKey;
  final FocusOnKeyDownCallback? onLeftKey;
  final FocusOnKeyDownCallback? onRightKey;
  final Function(bool)? onFocusChange;
  final Function()? onTap;
  final Color foucsedColor;
  final Color color;
  final bool autofocus;
  final BorderRadius? borderRadius;
  final double order;
  final bool selected;
  const HighlightWidget({
    required this.focusNode,
    required this.child,
    this.onUpKey,
    this.onDownKey,
    this.onLeftKey,
    this.onRightKey,
    this.onFocusChange,
    this.onTap,
    this.autofocus = false,
    this.selected = false,
    this.borderRadius,
    this.order = 0.0,
    this.color = Colors.transparent,
    this.foucsedColor = Colors.white,
    Key? key,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return FocusTraversalOrder(
      order: NumericFocusOrder(order),
      child: Focus(
        focusNode: focusNode,
        autofocus: autofocus,
        onFocusChange: (hasF) {
          if (focusNode.isFoucsed.value != hasF) {
            focusNode.isFoucsed.value = hasF;
          }
          onFocusChange?.call(hasF);
        },
        onKeyEvent: (node, e) {
          if (e is KeyDownEvent) {
            if (e.logicalKey == LogicalKeyboardKey.arrowRight) {
              return onRightKey?.call() ?? KeyEventResult.ignored;
            }
            if (e.logicalKey == LogicalKeyboardKey.arrowLeft) {
              return onLeftKey?.call() ?? KeyEventResult.ignored;
            }
            if (e.logicalKey == LogicalKeyboardKey.arrowUp) {
              return onUpKey?.call() ?? KeyEventResult.ignored;
            }
            if (e.logicalKey == LogicalKeyboardKey.arrowDown) {
              return onDownKey?.call() ?? KeyEventResult.ignored;
            }
            if (e.logicalKey == LogicalKeyboardKey.enter ||
                e.logicalKey == LogicalKeyboardKey.select ||
                e.logicalKey == LogicalKeyboardKey.space) {
              return onTap?.call() ?? KeyEventResult.ignored;
            }
          }

          return KeyEventResult.ignored;
        },
        child: GestureDetector(
          onTap: onTap,
          child: Obx(
            () {
              // 严格物理双重校验：只有在 isFoucsed 为 true 且系统底层 focusNode.hasFocus 确实为 true 时才渲染聚焦高亮
              final isTrulyFocused =
                  focusNode.isFoucsed.value && focusNode.hasFocus;
              return AnimatedScale(
                scale: isTrulyFocused ? 1.1 : 1,
                duration: const Duration(milliseconds: 200),
                child: GestureDetector(
                  onTap: onTap,
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: borderRadius,
                      boxShadow: isTrulyFocused
                          ? AppStyle.highlightShadow
                          : null,
                      color: (isTrulyFocused || selected)
                          ? foucsedColor
                          : color,
                    ),
                    child: child,
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
