import 'package:flutter/material.dart';

class AppleBuddy extends StatelessWidget {
  const AppleBuddy({super.key, this.size = 160});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Apple, a little lost on the way home',
      image: true,
      child: SizedBox.square(
        dimension: size,
        child: const CustomPaint(painter: _AppleBuddyPainter()),
      ),
    );
  }
}

class _AppleBuddyPainter extends CustomPainter {
  const _AppleBuddyPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.shortestSide / 128;
    canvas.save();
    canvas.scale(scale);

    canvas.drawOval(
      const Rect.fromLTWH(24, 116, 80, 9),
      Paint()..color = const Color(0x330d1b12),
    );

    final leaf = Path()
      ..moveTo(68, 22)
      ..cubicTo(73, 7, 91, 6, 99, 10)
      ..cubicTo(95, 24, 82, 30, 68, 25)
      ..close();
    canvas.drawPath(leaf, Paint()..color = const Color(0xff8dab69));
    canvas.drawLine(
      const Offset(71, 23),
      const Offset(92, 12),
      Paint()
        ..color = const Color(0xff55724d)
        ..strokeWidth = 1.5
        ..strokeCap = StrokeCap.round,
    );

    final stem = Paint()
      ..color = const Color(0xff75543d)
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(const Offset(64, 30), const Offset(64, 17), stem);

    final body = Path()
      ..moveTo(64, 39)
      ..cubicTo(50, 26, 31, 31, 22, 45)
      ..cubicTo(7, 67, 22, 105, 42, 113)
      ..cubicTo(51, 117, 58, 111, 64, 110)
      ..cubicTo(71, 111, 78, 117, 87, 113)
      ..cubicTo(107, 105, 121, 67, 106, 45)
      ..cubicTo(97, 31, 78, 26, 64, 39)
      ..close();
    canvas.drawShadow(body, const Color(0x550c1d13), 8, true);
    canvas.drawPath(body, Paint()..color = const Color(0xffdc7867));

    final shine = Paint()..color = const Color(0x33fff3d7);
    canvas.drawOval(const Rect.fromLTWH(24, 50, 13, 30), shine);

    final armPaint = Paint()
      ..color = const Color(0xff9f5b4d)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    final leftArm = Path()
      ..moveTo(22, 77)
      ..quadraticBezierTo(12, 83, 15, 92);
    final rightArm = Path()
      ..moveTo(106, 77)
      ..quadraticBezierTo(116, 83, 113, 92);
    canvas.drawPath(leftArm, armPaint);
    canvas.drawPath(rightArm, armPaint);

    final face = Paint()..color = const Color(0xff49352e);
    canvas.drawCircle(const Offset(47, 70), 3, face);
    canvas.drawCircle(const Offset(81, 70), 3, face);
    final blush = Paint()
      ..color = const Color(0xfff2ad91).withValues(alpha: .8);
    canvas.drawOval(const Rect.fromLTWH(32, 77, 13, 7), blush);
    canvas.drawOval(const Rect.fromLTWH(83, 77, 13, 7), blush);

    final smile = Path()
      ..moveTo(55, 80)
      ..quadraticBezierTo(64, 90, 73, 80);
    canvas.drawPath(
      smile,
      Paint()
        ..color = const Color(0xff684237)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round,
    );

    final shoe = Paint()
      ..color = const Color(0xff75543d)
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(const Offset(52, 109), const Offset(48, 117), shoe);
    canvas.drawLine(const Offset(76, 109), const Offset(80, 117), shoe);
    canvas.drawOval(
      const Rect.fromLTWH(39, 114, 13, 6),
      Paint()..color = const Color(0xff75543d),
    );
    canvas.drawOval(
      const Rect.fromLTWH(77, 114, 13, 6),
      Paint()..color = const Color(0xff75543d),
    );

    canvas.restore();
  }

  @override
  bool shouldRepaint(_AppleBuddyPainter oldDelegate) => false;
}
