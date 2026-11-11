import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:math_game/engine.dart';

void main() {
  test(
      'generation guarantees a valid route and distractors for every difficulty',
      () {
    final generator = BoardGenerator(Random(73));
    for (final size in [4, 5, 6]) {
      for (var divisor = 2; divisor <= 6; divisor++) {
        for (var sample = 0; sample < 100; sample++) {
          final board = generator.generate(size: size, divisor: divisor);
          final route = board.shortestPath()!;
          expect(board.cells.length, size * size);
          expect(board.cells.where((cell) => cell.start).length, 1);
          expect(board.cells.where((cell) => cell.finish).length, 1);
          expect(board.cells.any((cell) => cell.value % divisor != 0), isTrue);
          expect(route.first, 0);
          expect(route.last, board.goal);
          expect(route.toSet().length, route.length);
          expect(route.length - 1, 2 * (size - 1));
          for (var step = 0; step < route.length; step++) {
            expect(board.legal(route[step]), isTrue);
            if (step > 0) {
              expect(board.adjacent(route[step - 1], route[step]), isTrue);
            }
          }
        }
      }
    }
  });
  test('shortest path handles detours, blocked tiles, and unreachable goals',
      () {
    // Only this winding corridor is legal; Manhattan distance would be wrong.
    const corridor = [0, 5, 10, 15, 16, 17, 12, 7, 8, 9, 14, 19, 24];
    final board = Board(
        5,
        List.generate(25, (i) => Cell(corridor.contains(i) ? 3 : 1)),
        corridor,
        3);
    expect(board.shortestPath(), corridor);
    expect(board.shortestDistance(), 12);
    expect(board.shortestPath(from: 15, blocked: {0, 5, 10, 15}),
        corridor.sublist(3));
    expect(board.shortestPath(blocked: {12}), isNull);
    expect(board.shortestPath(blocked: {24}), isNull);
    expect(board.shortestPath(from: 24), [24]);
    expect(board.shortestPath(from: -1), isNull);
    expect(board.shortestPath(from: 1), isNull);
  });
  test('invalid generator inputs fail clearly', () {
    final generator = BoardGenerator();
    expect(() => generator.generate(size: 3), throwsArgumentError);
    expect(() => generator.generate(size: 7), throwsArgumentError);
    expect(() => generator.generate(divisor: 1), throwsArgumentError);
    expect(() => generator.generate(divisor: 7), throwsArgumentError);
  });
  test('100 boards per size are solvable and valid', () {
    final generator = BoardGenerator(Random(42));
    for (final size in [4, 5, 6]) {
      for (var i = 0; i < 100; i++) {
        final board = generator.generate(size: size, divisor: 3);
        expect(board.shortestDistance(), isNotNull);
        expect(board.guaranteedPath.first, 0);
        expect(board.guaranteedPath.last, board.goal);
        for (var j = 1; j < board.guaranteedPath.length; j++) {
          expect(
              board.adjacent(
                  board.guaranteedPath[j - 1], board.guaranteedPath[j]),
              true);
          expect(board.legal(board.guaranteedPath[j]), true);
        }
      }
    }
  });
  test('stars are bounded and reward shortest paths', () {
    expect(starsFor(moves: 8, optimal: 8, errors: 0), 3);
    expect(starsFor(moves: 10, optimal: 8, errors: 1), 2);
    expect(starsFor(moves: 16, optimal: 8, errors: 2), 1);
  });
}
