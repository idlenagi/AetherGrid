import 'package:flutter/material.dart';

/// A tiny forest companion drawn in Flutter so it stays crisp at every size.
class ForestBuddy extends StatelessWidget {
  const ForestBuddy({super.key, this.size = 64, this.happy = false});

  final double size;
  final bool happy;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: happy
          ? 'Pip the forest spirit is celebrating'
          : 'Pip the forest spirit',
      image: true,
      child: SizedBox.square(
        dimension: size,
        child: CustomPaint(painter: _ForestBuddyPainter(happy: happy)),
      ),
    );
  }
}

class _ForestBuddyPainter extends CustomPainter {
  const _ForestBuddyPainter({required this.happy});

  final bool happy;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.shortestSide / 64;
    canvas.save();
    canvas.scale(scale);

    final shadow = Paint()..color = const Color(0x300c1c13);
    canvas.drawOval(const Rect.fromLTWH(12, 53, 40, 7), shadow);

    // Leaf tips peek out above the round little body.
    final leafPaint = Paint()..color = const Color(0xff66885f);
    final leftLeaf = Path()
      ..moveTo(28, 20)
      ..cubicTo(17, 16, 17, 7, 18, 5)
      ..cubicTo(28, 6, 33, 11, 31, 20)
      ..close();
    final rightLeaf = Path()
      ..moveTo(34, 20)
      ..cubicTo(36, 9, 45, 7, 48, 8)
      ..cubicTo(47, 17, 41, 22, 34, 23)
      ..close();
    canvas.drawPath(leftLeaf, leafPaint);
    canvas.drawPath(rightLeaf, Paint()..color = const Color(0xff8ca975));

    final bodyPaint = Paint()
      ..color = const Color(0xffa9bf8b)
      ..style = PaintingStyle.fill;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(9, 18, 46, 39),
        const Radius.circular(21),
      ),
      bodyPaint,
    );

    final eyePaint = Paint()..color = const Color(0xff26392c);
    canvas.drawCircle(const Offset(24, 36), 2.1, eyePaint);
    canvas.drawCircle(const Offset(40, 36), 2.1, eyePaint);

    final blushPaint = Paint()
      ..color = const Color(0xffd88973).withValues(alpha: .72);
    canvas.drawOval(const Rect.fromLTWH(15, 39, 8, 4), blushPaint);
    canvas.drawOval(const Rect.fromLTWH(41, 39, 8, 4), blushPaint);

    final smilePaint = Paint()
      ..color = const Color(0xff684c3d)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round;
    final smile = Path()
      ..moveTo(27, 42)
      ..quadraticBezierTo(32, happy ? 49 : 47, 37, 42);
    canvas.drawPath(smile, smilePaint);

    // A tiny sprout mark gives the buddy a little extra personality.
    final sproutPaint = Paint()
      ..color = const Color(0xff56754f)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(const Offset(32, 19), const Offset(32, 13), sproutPaint);

    canvas.restore();
  }

  @override
  bool shouldRepaint(_ForestBuddyPainter oldDelegate) =>
      happy != oldDelegate.happy;
}
