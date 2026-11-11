import 'dart:math';

import 'package:flutter/material.dart';

class StarCelebration extends StatelessWidget {
  const StarCelebration({
    super.key,
    required this.stars,
    required this.animation,
  });
  final int stars;
  final Animation<double> animation;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: animation,
    builder: (context, _) => CustomPaint(
      painter: _Confetti(animation.value),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Column(
          children: [
            Text(
              'Puzzle complete!',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            // One semantic/text rating remains readable to assistive technology.
            Semantics(
              label: '$stars out of 3 stars',
              child: Text(
                '★' * stars + '☆' * (3 - stars),
                style: const TextStyle(fontSize: 36, color: Colors.amber),
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(3, (i) {
                final progress = ((animation.value - i * .16) / .5).clamp(
                  0.0,
                  1.0,
                );
                return Transform.scale(
                  scale: Curves.elasticOut.transform(progress),
                  child: Icon(
                    i < stars ? Icons.star_rounded : Icons.star_outline_rounded,
                    color: i < stars ? Colors.amber : Colors.grey,
                    size: 40,
                  ),
                );
              }),
            ),
          ],
        ),
      ),
    ),
  );
}

class _Confetti extends CustomPainter {
  _Confetti(this.progress);
  final double progress;
  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0 || progress >= 1) return;
    const colors = [
      Color(0xffd88973),
      Color(0xff8eaa78),
      Color(0xffe2c887),
      Color(0xffb7c99d),
    ];
    for (var i = 0; i < 24; i++) {
      final angle = i * 2 * pi / 24;
      final radius = progress * min(size.width * .45, 120);
      final point = Offset(
        size.width / 2 + cos(angle) * radius,
        size.height / 2 + sin(angle) * radius + 35 * progress * progress,
      );
      canvas.drawCircle(
        point,
        3 * (1 - progress),
        Paint()..color = colors[i % 4],
      );
    }
  }

  @override
  bool shouldRepaint(_Confetti oldDelegate) => progress != oldDelegate.progress;
}
