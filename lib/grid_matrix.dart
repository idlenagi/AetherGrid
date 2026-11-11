enum CellState { empty, hovered, locked }

class GridCell {
  final int row;
  final int col;
  final int value;
  CellState state;

  GridCell({
    required this.row,
    required this.col,
    required this.value,
    this.state = CellState.empty,
  });
}

class SpatialGridEngine {
  final int rows = 3;
  final int cols = 3;
  int targetSum = 15;
  int currentSum = 0;
  late List<List<GridCell>> matrix;

  SpatialGridEngine() {
    resetGrid();
  }

  void resetGrid() {
    currentSum = 0;
    int counter = 1;
    matrix = List.generate(
      rows,
      (r) => List.generate(
        cols,
        (c) => GridCell(row: r, col: c, value: counter++),
      ),
    );
  }

  /// Toggles cell lock on a rising-edge pinch event
  void toggleCellOnPinch(int row, int col) {
    if (row < 0 || row >= rows || col < 0 || col >= cols) return;

    final cell = matrix[row][col];
    if (cell.state == CellState.locked) {
      cell.state = CellState.empty;
      currentSum -= cell.value;
    } else {
      cell.state = CellState.locked;
      currentSum += cell.value;
    }
  }
}