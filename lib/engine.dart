import 'dart:math';

class Cell {
  final int value;
  final bool start;
  final bool finish;
  const Cell(this.value, {this.start = false, this.finish = false});
}

class Board {
  final int size;
  final List<Cell> cells;
  final List<int> guaranteedPath;
  final int divisor;
  const Board(this.size, this.cells, this.guaranteedPath, this.divisor);
  int get goal => cells.length - 1;
  bool legal(int index) =>
      index >= 0 && index < cells.length && (cells[index].value % divisor == 0);
  bool adjacent(int a, int b) =>
      (a ~/ size == b ~/ size && (a - b).abs() == 1) ||
      (a % size == b % size && (a - b).abs() == size);
  List<int> neighbors(int index) => [
    index - size,
    index + size,
    if (index % size > 0) index - 1,
    if (index % size < size - 1) index + 1,
  ].where((n) => n >= 0 && n < cells.length).toList();
  int? shortestDistance({int from = 0, Set<int> blocked = const {}}) {
    final route = shortestPath(from: from, blocked: blocked);
    return route == null ? null : route.length - 1;
  }

  /// Breadth-first search returns a minimum-move route, including both ends.
  /// The current tile may be in [blocked]; all other blocked tiles are avoided.
  List<int>? shortestPath({int from = 0, Set<int> blocked = const {}}) {
    if (!legal(from)) return null;
    final q = <int>[from];
    final parents = <int, int?>{from: null};
    for (var head = 0; head < q.length; head++) {
      final current = q[head];
      if (current == goal) {
        final route = <int>[];
        int? cursor = current;
        while (cursor != null) {
          route.add(cursor);
          cursor = parents[cursor];
        }
        return route.reversed.toList();
      }
      for (final next in neighbors(current)) {
        if (!blocked.contains(next) &&
            legal(next) &&
            !parents.containsKey(next)) {
          parents[next] = current;
          q.add(next);
        }
      }
    }
    return null;
  }
}

/// Constructive CSP: first assign a guaranteed satisfying route, then assign
/// distractors and optional alternate satisfying cells. Validate with BFS.
class BoardGenerator {
  final Random random;
  BoardGenerator([Random? random]) : random = random ?? Random();
  Board generate({int size = 5, int divisor = 3}) {
    if (size < 4 || size > 6) {
      throw ArgumentError.value(size, 'size', 'Must be between 4 and 6');
    }
    if (divisor < 2 || divisor > 20) {
      throw ArgumentError.value(divisor, 'divisor', 'Must be between 2 and 20');
    }
    for (var attempt = 0; attempt < 100; attempt++) {
      final path = <int>[0];
      final visited = <int>{0};
      var cursor = 0;
      // A monotonic path always reaches the opposite corner without revisits.
      while (cursor != size * size - 1) {
        final row = cursor ~/ size, col = cursor % size;
        final choices = <int>[
          if (row < size - 1) cursor + size,
          if (col < size - 1) cursor + 1,
        ];
        cursor = choices[random.nextInt(choices.length)];
        visited.add(cursor);
        path.add(cursor);
      }
      // Reserve an off-route nonmultiple so distractors are guaranteed rather
      // than only probable. Remaining off-route domains may contain multiples.
      final offRoute = List<int>.generate(
        size * size,
        (i) => i,
      ).where((i) => !visited.contains(i)).toList()..shuffle(random);
      final distractor = offRoute.first;
      final cells = List<Cell>.generate(size * size, (i) {
        final valid =
            visited.contains(i) ||
            (i != distractor && random.nextDouble() < 0.27);
        final value = valid
            ? divisor * (1 + random.nextInt(9))
            : 1 + random.nextInt(30);
        final corrected = valid ? value : _nonMultiple(value, divisor);
        return Cell(corrected, start: i == 0, finish: i == size * size - 1);
      });
      final board = Board(size, cells, path, divisor);
      if (board.shortestDistance() != null) return board;
    }
    throw StateError('Could not generate a solvable board');
  }

  int _nonMultiple(int value, int divisor) =>
      value % divisor == 0 ? value + 1 : value;
}

/// Owns the mutable state and rule enforcement for one puzzle session.
/// Widgets can observe this object, but all path and score changes go through
/// its transition methods.
class GameSession {
  GameSession(this.board) : path = [0];

  Board board;
  final List<int> path;
  int errors = 0;
  int stars = 0;

  bool get isComplete => stars > 0;

  GameMoveResult select(int index) {
    if (isComplete || index < 0 || index >= board.cells.length) {
      return GameMoveResult.ignored;
    }
    final current = path.last;
    if (path.length > 1 && index == path[path.length - 2]) {
      path.removeLast();
      return GameMoveResult.backtracked;
    }
    if (!board.adjacent(current, index)) {
      errors++;
      return GameMoveResult.notAdjacent;
    }
    if (!board.legal(index)) {
      errors++;
      return GameMoveResult.illegalValue;
    }
    if (path.contains(index)) {
      errors++;
      return GameMoveResult.alreadyVisited;
    }
    path.add(index);
    if (index == board.goal) {
      stars = starsFor(
        moves: path.length - 1,
        optimal: board.shortestDistance() ?? path.length - 1,
        errors: errors,
      );
      return GameMoveResult.completed;
    }
    return GameMoveResult.selected;
  }

  void reset({Board? nextBoard}) {
    if (nextBoard != null) board = nextBoard;
    path
      ..clear()
      ..add(0);
    errors = 0;
    stars = 0;
  }
}

enum GameMoveResult {
  ignored,
  backtracked,
  notAdjacent,
  illegalValue,
  alreadyVisited,
  selected,
  completed,
}

class DifficultyEngine {
  static const maxLevel = 19;

  DifficultyEngine({int initialLevel = 2}) : level = initialLevel {
    if (initialLevel < 1 || initialLevel > maxLevel) {
      throw ArgumentError.value(
        initialLevel,
        'initialLevel',
        'Must be between 1 and $maxLevel',
      );
    }
  }
  int level;
  final List<int> _recentPerformance = [];

  int get size => level == 1
      ? 4
      : level <= 4
      ? 5
      : 6;
  /// Levels 1–19 progressively cover multiples 2–20.
  int get divisor => level + 1;

  /// Inverse of [divisor]: the level whose puzzles use multiples of [multiple].
  static int levelForMultiple(int multiple) => multiple - 1;

  /// Fixed multiples for the first puzzles of a block, from the block order:
  /// touch first -> 3, 4, 5; gesture first -> 5, 4, 3. Adaptive difficulty
  /// takes over afterwards. Unrecognised orders get no fixed opening.
  static List<int> openingMultiplesFor(String blockOrder) {
    final order = blockOrder.trim().toLowerCase();
    if (order.startsWith('touch')) return const [3, 4, 5];
    if (order.startsWith('gesture') || order.startsWith('spatial')) {
      return const [5, 4, 3];
    }
    return const [];
  }
  void record({
    required int errors,
    required int moves,
    required int optimal,
    required double seconds,
    int hintsUsed = 0,
  }) {
    final errorRate = errors / max(1, moves + errors);
    final efficiency = optimal / max(1, moves);
    final secondsPerOptimalMove = seconds / max(1, optimal);

    // Adjust only after a consistent pattern, so one unusually easy or hard
    // round does not make the next puzzle jump in difficulty.
    final strongRound =
        errorRate <= .12 &&
        efficiency >= .9 &&
        secondsPerOptimalMove <= 12 &&
        hintsUsed <= 1;
    final strugglingRound =
        errorRate >= .35 ||
        efficiency <= .65 ||
        hintsUsed >= 4 ||
        (secondsPerOptimalMove >= 20 && hintsUsed >= 2);

    _recentPerformance.add(strongRound ? 1 : strugglingRound ? -1 : 0);
    if (_recentPerformance.length > 5) _recentPerformance.removeAt(0);
    final strongCount = _recentPerformance.where((result) => result == 1).length;
    final strugglingCount = _recentPerformance.where((result) => result == -1).length;

    if (strongCount >= 3 && level < maxLevel) {
      level++;
      _recentPerformance.clear();
    } else if (strugglingCount >= 3 && level > 1) {
      level--;
      _recentPerformance.clear();
    }
  }
}

int starsFor({required int moves, required int optimal, required int errors}) {
  final ratio = moves / max(1, optimal);
  if (ratio <= 1.001 && errors == 0) return 3;
  if (ratio <= 1.5) return 2;
  return 1;
}
