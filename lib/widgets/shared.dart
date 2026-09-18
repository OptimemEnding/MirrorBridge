import '../models/user_message.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

class ReferenceCard extends StatelessWidget {
  const ReferenceCard({super.key, required this.child, this.padding = 14});
  final Widget child;
  final double padding;
  @override
  Widget build(BuildContext context) => Container(
    padding: EdgeInsets.all(padding),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
      boxShadow: const [
        BoxShadow(
          color: Color(0x0617283a),
          blurRadius: 14,
          offset: Offset(0, 3),
        ),
      ],
    ),
    child: Material(type: MaterialType.transparency, child: child),
  );
}

class Panel extends StatelessWidget {
  const Panel({
    super.key,
    required this.child,
    this.dark = false,
    this.padding = 20,
  });
  final Widget child;
  final bool dark;
  final double padding;
  @override
  Widget build(BuildContext context) => Container(
    padding: EdgeInsets.all(padding),
    decoration: BoxDecoration(
      color: dark ? ink : cardColor,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(
        color: dark ? const Color(0xff253044) : const Color(0xffedf0f3),
      ),
      boxShadow: [
        BoxShadow(
          color: const Color(0xff172033).withValues(alpha: dark ? .14 : .055),
          blurRadius: dark ? 18 : 12,
          offset: const Offset(0, 4),
        ),
      ],
    ),
    child: Material(type: MaterialType.transparency, child: child),
  );
}

class Pill extends StatelessWidget {
  const Pill(
    this.label, {
    super.key,
    this.onPressed,
    this.light = false,
    this.destructive = false,
    this.subdued = false,
    this.icon,
  });
  final String label;
  final VoidCallback? onPressed;
  final bool light, destructive, subdued;
  final IconData? icon;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: double.infinity,
    height: 50,
    child: FilledButton(
      style: FilledButton.styleFrom(
        backgroundColor: subdued
            ? const Color(0xffe7e7eb)
            : destructive
            ? Colors.red.shade700
            : light
            ? const Color(0xfff1f4f6)
            : brandGreen,
        foregroundColor: subdued
            ? muted
            : destructive
            ? Colors.white
            : light
            ? ink
            : Colors.white,
        disabledBackgroundColor: const Color(0xffe7e7eb),
        disabledForegroundColor: muted,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ).copyWith(animationDuration: fastMotion),
      onPressed: onPressed,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (icon != null) ...[Icon(icon, size: 20), const SizedBox(width: 8)],
          Flexible(
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
            ),
          ),
        ],
      ),
    ),
  );
}

class StatusChip extends StatelessWidget {
  const StatusChip(
    this.label, {
    super.key,
    this.color = const Color(0xfff59e0b),
  });
  final String label;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .12),
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: color.withValues(alpha: .24)),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 7),
        Flexible(
          child: Text(
            label,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    ),
  );
}

Widget heading(String text, {Color? color, double size = 18}) => Text(
  text,
  style: TextStyle(
    fontSize: size,
    fontWeight: FontWeight.w800,
    color: color ?? ink,
  ),
);
Widget gap([double height = 16]) => SizedBox(height: height);
void notice(BuildContext context, String message) {
  message = userMessage(message);
  final messenger = ScaffoldMessenger.of(context);
  messenger.clearSnackBars();
  messenger.showSnackBar(
    SnackBar(
      duration: const Duration(seconds: 3),
      padding: EdgeInsets.zero,
      content: TimedNotice(
        message: message,
        dark: true,
        onExpired: () => messenger.hideCurrentSnackBar(),
      ),
    ),
  );
}

class TimedNotice extends StatefulWidget {
  const TimedNotice({
    super.key,
    required this.message,
    required this.onExpired,
    this.dark = false,
  });
  final String message;
  final VoidCallback onExpired;
  final bool dark;
  @override
  State<TimedNotice> createState() => _TimedNoticeState();
}

class _TimedNoticeState extends State<TimedNotice>
    with SingleTickerProviderStateMixin {
  late final AnimationController timer;
  late final Timer expiry;
  @override
  void initState() {
    super.initState();
    timer = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..forward();
    expiry = Timer(const Duration(seconds: 3), widget.onExpired);
  }

  @override
  void dispose() {
    timer.dispose();
    expiry.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Material(
    color: widget.dark ? const Color(0xff303030) : const Color(0xffeef4ff),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.message,
                  style: TextStyle(
                    color: widget.dark ? Colors.white : Colors.black,
                  ),
                ),
              ),
              IconButton(
                tooltip: '关闭通知',
                onPressed: widget.onExpired,
                icon: Icon(
                  Icons.close,
                  color: widget.dark ? Colors.white : Colors.black,
                ),
              ),
            ],
          ),
        ),
        AnimatedBuilder(
          animation: timer,
          builder: (_, child) => LinearProgressIndicator(
            value: 1 - timer.value,
            minHeight: 2,
            backgroundColor: Colors.transparent,
            color: const Color(0xff60a5fa),
          ),
        ),
      ],
    ),
  );
}

Future<bool> confirm(
  BuildContext context,
  String title,
  String body, {
  String action = '删除',
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: action.contains('删除')
                ? TextButton.styleFrom(foregroundColor: Colors.red.shade700)
                : null,
            child: Text(action),
          ),
        ],
      ),
    ) ??
    false;

/// null cancels; false removes records; true additionally deletes source files.
Future<bool?> confirmLocalDeletion(BuildContext context, int count) {
  var deleteSource = false;
  return showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('删除媒体'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('删除选中的 $count 个媒体的应用记录和同步记录。'),
            const SizedBox(height: 16),
            Semantics(
              checked: deleteSource,
              label: '同步删除照片文件',
              child: InkWell(
                onTap: () => setState(() => deleteSource = !deleteSource),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Row(
                    children: [
                      Container(
                        width: 22,
                        height: 22,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: deleteSource
                              ? Colors.red.shade700
                              : Colors.transparent,
                          border: Border.all(
                            color: deleteSource ? Colors.red.shade700 : muted,
                            width: 1.5,
                          ),
                        ),
                        child: deleteSource
                            ? const Icon(
                                Icons.check,
                                size: 16,
                                color: Colors.white,
                              )
                            : null,
                      ),
                      const SizedBox(width: 10),
                      const Expanded(child: Text('同步删除照片文件')),
                    ],
                  ),
                ),
              ),
            ),
            Text(
              deleteSource ? '照片或视频文件也将被删除，无法撤销。' : '照片和视频文件将保留。',
              style: TextStyle(
                fontSize: 12,
                color: deleteSource ? Colors.red.shade700 : muted,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, deleteSource),
            style: TextButton.styleFrom(foregroundColor: Colors.red.shade700),
            child: const Text('删除'),
          ),
        ],
      ),
    ),
  );
}
