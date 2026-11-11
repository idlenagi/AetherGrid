import 'package:flutter_test/flutter_test.dart';
import 'package:math_game/engine.dart';
import 'package:math_game/hints.dart';

void main() {
  final hints = ProgressiveHints();
  final board = Board(
      4,
      List.generate(
          16, (i) => Cell([0, 1, 2, 3, 4, 7, 11, 15].contains(i) ? 3 : 1)),
      const [],
      3);
  test('hint stages remind, filter reachable choices, and reveal shortest step',
      () {
    expect(hints.evaluate(board, [0], 1).targets, isEmpty);
    // Tile 4 is a legal dead end, so it must not be suggested.
    expect(hints.evaluate(board, [0], 2).targets, [1]);
    expect(hints.evaluate(board, [0], 3).targets, [1]);
    expect(hints.evaluate(board, [0], 99).stage, 3);
  });
  test('dead ends suggest backtracking instead of another dead end', () {
    for (final stage in [2, 3]) {
      final result = hints.evaluate(board, [0, 4], stage);
      expect(result.targets, [0]);
      expect(result.message, contains('backtrack'));
    }
  });
  test('hints never suggest revisiting earlier path tiles', () {
    final result = hints.evaluate(board, [0, 1, 2], 2);
    expect(result.targets, [3]);
    expect(hints.evaluate(board, [15], 3).targets, isEmpty);
  });
}
