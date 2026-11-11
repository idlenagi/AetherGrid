import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:math_game/star_celebration.dart';

void main() {
  for (final stars in [1, 2, 3]) {
    testWidgets(
        '$stars star celebration animates and displays the earned rating',
        (tester) async {
      final controller = AnimationController(
          vsync: const TestVSync(),
          duration: const Duration(milliseconds: 900));
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: StarCelebration(stars: stars, animation: controller))));
      controller.forward();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(controller.value, greaterThan(0));
      expect(controller.value, lessThan(1));
      expect(find.byIcon(Icons.star_rounded), findsNWidgets(stars));
      expect(find.text('★' * stars + '☆' * (3 - stars)), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 900));
      expect(controller.isCompleted, isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    });
  }
}
