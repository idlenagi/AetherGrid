import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:math_game/melody.dart';

void main() {
  test('random piano melody stays in scale without repeating consecutive notes',
      () {
    final melody = TileMelody(Random(42));
    double? previous;
    final heard = <double>{};
    for (var i = 0; i < 100; i++) {
      final note = melody.next();
      expect(TileMelody.frequencies, contains(note));
      expect(note, isNot(previous));
      heard.add(note);
      previous = note;
    }
    expect(heard.length, TileMelody.frequencies.length);
  });
}
