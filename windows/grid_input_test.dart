import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:math_game/main.dart';
import 'package:math_game/engine.dart';
import 'package:math_game/flowing_gradient.dart';

Finder tile(int index) => find.byKey(ValueKey('tile-$index'));

int legalFirstStep(WidgetTester tester) {
  return [1, 5].firstWhere((index) {
    final semantics = tester.widget<Semantics>(tile(index));
    final value = int.parse(semantics.properties.label!.split(' ').last);
    return value % 3 == 0;
  });
}

void main() {
  testWidgets('debug overlay does not block covered controls or page scrolling',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final provider = LocalInputProvider();
    await tester
        .pumpWidget(MaterialApp(home: GameScreen(inputProvider: provider)));
    await tester.tap(find.byTooltip('Developer telemetry'));
    await tester.pump();
    expect(find.byKey(const ValueKey('telemetry-overlay')), findsOneWidget);
    final overlay =
        tester.getRect(find.byKey(const ValueKey('telemetry-overlay')));
    expect(
        overlay.contains(tester.getCenter(find.text('Spatial demo'))), isTrue);
    await tester.tap(find.text('Spatial demo'));
    await tester.pump();
    provider.emit(const GameInputEvent(1, InputKind.hover));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.textContaining('Mode: spatial'), findsOneWidget);
    expect(find.textContaining('Hover: 1'), findsOneWidget);
    final pageScrollable = tester.state<ScrollableState>(find
        .descendant(
            of: find.byType(ListView), matching: find.byType(Scrollable))
        .first);
    final before = pageScrollable.position.pixels;
    await tester.dragFrom(overlay.center, const Offset(0, -200));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(pageScrollable.position.pixels, greaterThan(before));
    await tester.tap(find.byTooltip('Developer telemetry'));
    await tester.pump();
    expect(find.byKey(const ValueKey('telemetry-overlay')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    provider.dispose();
  });
  testWidgets(
      'stalled hints progress at 12, 24, 36 seconds and reset after a move',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var now = DateTime(2026, 10, 12);
    await tester.pumpWidget(MaterialApp(home: GameScreen(now: () => now)));
    for (var stage = 1; stage <= 3; stage++) {
      now = now.add(const Duration(seconds: 12));
      await tester.pump(const Duration(seconds: 1));
      expect(find.textContaining('Hint $stage/3:'), findsOneWidget);
    }
    await tester.ensureVisible(find.text('Hint'));
    await tester.pump();
    await tester.tap(find.text('Hint'));
    await tester.pump();
    expect(find.textContaining('Hint 3/3:'), findsOneWidget);
    await tester.tap(tile(legalFirstStep(tester)));
    await tester.pump();
    expect(find.text('Good move!'), findsOneWidget);
    now = now.add(const Duration(seconds: 12));
    await tester.pump(const Duration(seconds: 1));
    expect(find.textContaining('Hint 1/3:'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'invalid move flashes an X, clears, and appears in live telemetry overlay',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const MathGameApp());
    await tester.tap(tile(12));
    await tester.pump();
    expect(find.textContaining('Invalid move! Choose a tile directly'),
        findsOneWidget);
    expect(
        find.descendant(
            of: tile(12), matching: find.byIcon(Icons.close_rounded)),
        findsOneWidget);
    expect(tester.widget<Semantics>(tile(12)).properties.selected, isFalse);
    await tester.pump(const Duration(milliseconds: 700));
    expect(
        find.descendant(
            of: tile(12), matching: find.byIcon(Icons.close_rounded)),
        findsNothing);
    await tester.tap(find.byTooltip('Developer telemetry'));
    await tester.pump();
    expect(find.byKey(const ValueKey('telemetry-overlay')), findsOneWidget);
    expect(find.textContaining('Inputs: 1'), findsOneWidget);
    expect(find.textContaining('Errors: 1'), findsOneWidget);
    expect(find.textContaining('Build avg:'), findsOneWidget);
    await tester.tap(find.byTooltip('Developer telemetry'));
    await tester.pump();
    expect(find.byKey(const ValueKey('telemetry-overlay')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  test('neighboring tiles sample a single shared gradient coordinate space',
      () {
    const animation = AlwaysStoppedAnimation<double>(.25);
    final first = FlowingGradientPainter(animation, Colors.grey, true, 0, 5);
    final right = FlowingGradientPainter(animation, Colors.grey, true, 1, 5);
    final below = FlowingGradientPainter(animation, Colors.grey, true, 5, 5);
    const tileSize = Size(64, 64);
    expect(right.shaderBounds(tileSize).shift(const Offset(69, 0)),
        first.shaderBounds(tileSize));
    expect(below.shaderBounds(tileSize).shift(const Offset(0, 69)),
        first.shaderBounds(tileSize));
  });
  testWidgets('shared gradient animation continues after selecting a tile',
      (tester) async {
    await tester.pumpWidget(const MathGameApp());
    final next = legalFirstStep(tester);
    FlowingGradient gradient() =>
        tester.widget<FlowingGradient>(find.descendant(
          of: tile(next),
          matching: find.byType(FlowingGradient),
        ));
    final before = gradient().animation.value;
    await tester.pump(const Duration(milliseconds: 750));
    expect(gradient().animation.value, isNot(before));
    expect(gradient().selected, isFalse);
    await tester.tap(tile(next));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(gradient().selected, isTrue);
    final selectedPhase = gradient().animation.value;
    await tester.pump(const Duration(milliseconds: 750));
    expect(gradient().animation.value, isNot(selectedPhase));
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'tile press animates gradient and shadow, cancels cleanly, and sound can mute',
      (tester) async {
    await tester.pumpWidget(const MathGameApp());
    final next = legalFirstStep(tester);
    AnimatedContainer container() =>
        tester.widget<AnimatedContainer>(find.descendant(
          of: tile(next),
          matching: find.byType(AnimatedContainer),
        ));
    final original = container().decoration! as BoxDecoration;
    expect(original.gradient, isA<LinearGradient>());
    expect(original.boxShadow, isNotEmpty);
    final gesture = await tester.startGesture(tester.getCenter(tile(next)));
    await tester.pump(const Duration(milliseconds: 150));
    final down = container();
    expect(down.transform!.entry(0, 0), .93);
    expect(
        (down.decoration! as BoxDecoration).gradient, isNot(original.gradient));
    await gesture.cancel();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1000));
    expect(container().transform!.entry(0, 0), 1);
    expect(tester.widget<Semantics>(tile(next)).properties.selected, isFalse);
    await tester.tap(find.byTooltip('Mute tile sounds'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1000));
    expect(find.byTooltip('Enable tile sounds'), findsOneWidget);
    await tester.tap(tile(next));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1000));
    expect(tester.widget<Semantics>(tile(next)).properties.selected, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets(
      'external input frames track hover, clear it, and commit selection across mode switches',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final provider = LocalInputProvider();
    await tester
        .pumpWidget(MaterialApp(home: GameScreen(inputProvider: provider)));
    final next = legalFirstStep(tester);
    Color? color(int index) => (tester
            .widget<AnimatedContainer>(find.descendant(
              of: tile(index),
              matching: find.byType(AnimatedContainer),
            ))
            .decoration! as BoxDecoration)
        .color;
    provider.emit(GameInputEvent(next, InputKind.hover));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1000));
    expect(color(next), isNot(const Color(0xffb4e7df)));
    await tester.tap(find.text('Spatial demo'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1000));
    for (final index in [next, 12, next]) {
      provider.emit(GameInputEvent(index, InputKind.hover));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1000));
      expect(color(index), const Color(0xffb4e7df));
      expect(
          tester.widget<Semantics>(tile(index)).properties.selected, isFalse);
    }
    provider.emit(const GameInputEvent(-1, InputKind.hover));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1000));
    expect(color(next), isNot(const Color(0xffb4e7df)));
    provider.emit(GameInputEvent(next, InputKind.hover));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1000));
    await tester.tap(find.text('Touch'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1000));
    expect(color(next), isNot(const Color(0xffb4e7df)));
    await tester.tap(tile(next));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1000));
    expect(tester.widget<Semantics>(tile(next)).properties.selected, isTrue);
    await tester.tap(find.text('Spatial demo'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1000));
    expect(tester.widget<Semantics>(tile(next)).properties.selected, isTrue);
    provider.emit(const GameInputEvent(0, InputKind.select));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1000));
    expect(tester.widget<Semantics>(tile(next)).properties.selected, isFalse);
    expect(find.text('Moved back one block.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    provider.emit(GameInputEvent(next, InputKind.select));
    await tester.pump();
    expect(tester.takeException(), isNull);
    provider.dispose();
  });

  testWidgets(
      'completed puzzles update DDA and next board applies the new divisor',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final difficulty = DifficultyEngine();
    await tester.pumpWidget(
        MaterialApp(home: GameScreen(difficultyEngine: difficulty)));
    for (var round = 0; round < 2; round++) {
      final board = Board(
          5,
          List.generate(
              25,
              (i) => Cell(int.parse(
                    tester
                        .widget<Semantics>(tile(i))
                        .properties
                        .label!
                        .split(' ')
                        .last,
                  ))),
          const [],
          3);
      for (final index in board.shortestPath()!.skip(1)) {
        await tester.ensureVisible(tile(index));
        await tester.tap(tile(index));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 1000));
      }
      expect(difficulty.level, round == 0 ? 2 : 3);
      await tester.ensureVisible(find.text('Next puzzle'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Next puzzle'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1000));
    }
    expect(find.text('Select multiples of 4'), findsOneWidget);
    expect(find.textContaining('Difficulty level 3'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('mouse clicks and stylus taps can complete a puzzle',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    for (final kind in [PointerDeviceKind.mouse, PointerDeviceKind.stylus]) {
      await tester.pumpWidget(const MathGameApp());
      final board = Board(
          5,
          List.generate(
              25,
              (i) => Cell(int.parse(
                    tester
                        .widget<Semantics>(tile(i))
                        .properties
                        .label!
                        .split(' ')
                        .last,
                  ))),
          const [],
          3);
      for (final index in board.shortestPath()!.skip(1)) {
        await tester.tap(tile(index), kind: kind);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 1000));
        expect(
            tester.widget<Semantics>(tile(index)).properties.selected, isTrue);
      }
      expect(find.text('Puzzle complete!'), findsOneWidget);
      expect(find.text('★★★'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets('spatial hover and long press work without selecting on hover',
      (tester) async {
    await tester.pumpWidget(const MathGameApp());
    await tester.tap(find.text('Spatial demo'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1000));
    final next = legalFirstStep(tester);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(tile(next)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1000));
    final container = tester.widget<AnimatedContainer>(find.descendant(
      of: tile(next),
      matching: find.byType(AnimatedContainer),
    ));
    expect((container.decoration! as BoxDecoration).color,
        const Color(0xffb4e7df));
    expect(tester.widget<Semantics>(tile(next)).properties.selected, isFalse);
    await tester.longPress(tile(next));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1000));
    expect(tester.widget<Semantics>(tile(next)).properties.selected, isTrue);
    await mouse.removePointer();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('shortest path controls work on a narrow phone screen',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const MathGameApp());
    await tester.scrollUntilVisible(find.text('Show shortest path'), 100,
        scrollable: find
            .descendant(
                of: find.byType(ListView), matching: find.byType(Scrollable))
            .first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1000));
    await tester.ensureVisible(find.text('Show shortest path'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1000));
    await tester.tap(find.text('Show shortest path'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1000));
    expect(find.text('Hide shortest path'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('shortest solution can be shown, played, hidden, and reset',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const MathGameApp());
    final values = List.generate(
        25,
        (i) => Cell(int.parse(
              tester
                  .widget<Semantics>(tile(i))
                  .properties
                  .label!
                  .split(' ')
                  .last,
            )));
    final route = Board(5, values, const [], 3).shortestPath()!;
    await tester.ensureVisible(find.text('Show shortest path'));
    await tester.tap(find.text('Show shortest path'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1000));
    expect(find.textContaining('Shortest path: 8 moves'), findsOneWidget);
    expect(
        tester.widget<Semantics>(tile(route[1])).properties.selected, isFalse);
    await tester.ensureVisible(tile(route[1]));
    await tester.tap(tile(route[1]));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1000));
    expect(
        tester.widget<Semantics>(tile(route[1])).properties.selected, isTrue);
    await tester.ensureVisible(find.text('Hide shortest path'));
    await tester.tap(find.text('Hide shortest path'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1000));
    expect(find.byKey(const ValueKey('solution-description')), findsNothing);
    await tester.tap(find.text('Show shortest path'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1000));
    await tester.ensureVisible(find.text('Restart'));
    await tester.tap(find.text('Restart'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1000));
    expect(find.byKey(const ValueKey('solution-description')), findsNothing);
    expect(
        tester.widget<Semantics>(tile(route[1])).properties.selected, isFalse);
    await tester.tap(find.text('Show shortest path'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1000));
    await tester.ensureVisible(find.text('New puzzle'));
    await tester.tap(find.text('New puzzle'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1000));
    expect(find.byKey(const ValueKey('solution-description')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  for (final spatial in [false, true]) {
    testWidgets(
        'tap selects a legal neighbor in ${spatial ? 'spatial' : 'touch'} mode',
        (tester) async {
      await tester.pumpWidget(const MathGameApp());
      if (spatial) {
        await tester.tap(find.text('Spatial demo'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 1000));
      }
      final next = legalFirstStep(tester);
      await tester.tap(tile(next));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1000));
      expect(tester.widget<Semantics>(tile(next)).properties.selected, isTrue);
      expect(find.text('Good move!'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('nonadjacent clicks give feedback without selecting the tile',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const MathGameApp());
    await tester.tap(tile(12));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1000));
    expect(tester.widget<Semantics>(tile(12)).properties.selected, isFalse);
    expect(find.textContaining('Invalid move!'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
