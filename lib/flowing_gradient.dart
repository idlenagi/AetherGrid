import 'dart:math';

import 'package:flutter/material.dart';

class FlowingGradient extends StatelessWidget {
  const FlowingGradient({
    super.key,
    required this.animation,
    required this.color,
    required this.selected,
    required this.index,
    required this.gridSize,
    required this.child,
  });
  final Animation<double> animation;
  final Color color;
  final bool selected;
  final int index;
  final int gridSize;
  final Widget child;

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: FlowingGradientPainter(
      animation,
      color,
      selected,
      index,
      gridSize,
    ),
    child: child,
  );
}

class FlowingGradientPainter extends CustomPainter {
  FlowingGradientPainter(
    this.animation,
    this.color,
    this.selected,
    this.index,
    this.gridSize,
  ) : super(repaint: selected ? animation : null);
  final Animation<double> animation;
  final Color color;
  final bool selected;
  final int index;
  final int gridSize;

  /// Every tile samples the same board-wide gradient, translated into its
  /// local coordinates. Adjacent tiles therefore share one moving color field.
  Rect shaderBounds(Size size) => Rect.fromLTWH(
    -(index % gridSize) * (size.width + 5),
    -(index ~/ gridSize) * (size.height + 5),
    size.width * gridSize + 5 * (gridSize - 1),
    size.height * gridSize + 5 * (gridSize - 1),
  );

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    if (selected) {
      final shift = animation.value * 2;
      final gradient = LinearGradient(
        begin: Alignment(-1 + shift, -1 + shift),
        end: Alignment(1 + shift, 1 + shift),
        tileMode: TileMode.repeated,
        colors: const [
          Color(0xffd09b68),
          Color(0xff708f68),
          Color(0xff9b9270),
          Color(0xffd09b68),
        ],
      );
      paint.shader = gradient.createShader(shaderBounds(size));
    }
    canvas.drawCircle(
      size.center(Offset.zero),
      min(size.width, size.height) / 2,
      paint,
    );
  }

  @override
  bool shouldRepaint(FlowingGradientPainter oldDelegate) =>
      color != oldDelegate.color ||
      selected != oldDelegate.selected ||
      index != oldDelegate.index ||
      gridSize != oldDelegate.gridSize ||
      animation != oldDelegate.animation;
}
