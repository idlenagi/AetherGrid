import 'dart:async';

class BlockSelectionEvent {
  final int row;
  final int column;
  final bool isPinch;

  BlockSelectionEvent({
    required this.row,
    required this.column,
    required this.isPinch,
  });
}

abstract class InputProvider {
  Stream<BlockSelectionEvent> get onBlockSelected;
  void startTracking();
  void stopTracking();
  void dispose();
}