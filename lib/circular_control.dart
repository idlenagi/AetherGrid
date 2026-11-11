import 'package:flutter/material.dart';

class CircularControl extends StatelessWidget {
  const CircularControl({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
    this.active = false,
    this.buttonWidth = 116,
    this.buttonHeight = 68,
  });
  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool active;
  final double buttonWidth;
  final double buttonHeight;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      style: TextButton.styleFrom(
        fixedSize: Size(buttonWidth, buttonHeight),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(
            color: active ? const Color(0xffd3d8a5) : const Color(0xff71816e),
          ),
        ),
        backgroundColor: active
            ? const Color(0xff657e5d)
            : const Color(0xff334336),
        foregroundColor: active
            ? const Color(0xfffff5df)
            : const Color(0xffe8dfc8),
        disabledBackgroundColor: const Color(0xff263228),
        disabledForegroundColor: const Color(0xff8d9885),
      ),
      onPressed: onPressed,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 20),
          const SizedBox(width: 7),
          Flexible(
            child: Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}
