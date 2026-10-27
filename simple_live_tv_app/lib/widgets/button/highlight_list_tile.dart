import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:get/get.dart';
import 'package:simple_live_tv_app/app/app_focus_node.dart';
import 'package:simple_live_tv_app/app/app_style.dart';
import 'package:simple_live_tv_app/widgets/highlight_widget.dart';

class HighlightListTile extends StatelessWidget {
  final Widget? leading;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final Function()? onTap;
  final bool autofocus;
  final AppFocusNode focusNode;
  const HighlightListTile({
    required this.title,
    this.subtitle,
    this.leading,
    this.onTap,
    required this.focusNode,
    this.autofocus = false,
    this.trailing,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return Obx(
      () {
        final isTrulyFocused = focusNode.isFoucsed.value && focusNode.hasFocus;
        return IconTheme(
          data: IconThemeData(
            color: isTrulyFocused ? Colors.black : Colors.white,
          ),
          child: HighlightWidget(
            onTap: onTap,
            autofocus: autofocus,
            focusNode: focusNode,
            borderRadius: AppStyle.radius16,
            child: Padding(
              padding: AppStyle.edgeInsetsA24,
              child: Row(
                children: [
                  if (leading != null) leading!,
                  if (leading != null) AppStyle.hGap32,
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          title,
                          style: isTrulyFocused
                              ? AppStyle.textStyleBlack
                              : AppStyle.textStyleWhite,
                        ),
                        if (subtitle != null)
                          Text(
                            subtitle!,
                            style: isTrulyFocused
                                ? AppStyle.textStyleBlack
                                    .copyWith(fontSize: 24.w)
                                : AppStyle.textStyleWhite
                                    .copyWith(fontSize: 24.w),
                          ),
                      ],
                    ),
                  ),
                  AppStyle.hGap12,
                  if (onTap != null && isTrulyFocused && trailing == null)
                    Icon(
                      Icons.chevron_right,
                      size: 40.w,
                      color: isTrulyFocused ? Colors.black : Colors.white,
                    ),
                  if (trailing != null) trailing!,
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
