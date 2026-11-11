import 'engine.dart';

class HintResult {
  const HintResult(this.stage, this.message, this.targets);
  final int stage;
  final String message;
  final List<int> targets;
}

class ProgressiveHints {
  HintResult evaluate(Board board, List<int> path, int requestedStage) {
    final stage = requestedStage.clamp(1, 3);
    if (stage == 1) {
      return HintResult(
          stage,
          'Hint 1/3: choose a multiple of ${board.divisor} directly above, below, left, or right. You can tap the previous tile to backtrack.',
          const []);
    }
    final route = board.shortestPath(from: path.last, blocked: path.toSet());
    if (route == null) {
      final previous = path.length > 1 ? path[path.length - 2] : null;
      return HintResult(
          stage,
          'Hint $stage/3: this branch cannot reach FINISH without revisiting tiles. Tap the highlighted previous tile to backtrack.',
          [?previous]);
    }
    if (route.length < 2) {
      return HintResult(stage, 'You have reached FINISH!', const []);
    }
    if (stage == 2) {
      final viable = board
          .neighbors(path.last)
          .where((i) =>
              !path.contains(i) &&
              board.legal(i) &&
              board.shortestPath(from: i, blocked: path.toSet()) != null)
          .toList();
      return HintResult(
          stage,
          'Hint 2/3: the glowing tiles can still lead to FINISH. Choose one.',
          viable);
    }
    final next = route[1];
    return HintResult(
        stage,
        'Hint 3/3: move to row ${next ~/ board.size + 1}, column ${next % board.size + 1} (${board.cells[next].value}). This is a shortest remaining step.',
        [next]);
  }
}
