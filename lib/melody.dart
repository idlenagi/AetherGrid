import 'dart:math';

/// C-major pentatonic notes blend well even when played in random order.
class TileMelody {
  TileMelody([Random? random]) : _random = random ?? Random();
  final Random _random;
  static const frequencies = [261.63, 293.66, 329.63, 392.00, 440.00, 523.25];
  int? _last;
  double next() {
    final choices = List.generate(frequencies.length, (i) => i)
        .where((i) => i != _last)
        .toList();
    _last = choices[_random.nextInt(choices.length)];
    return frequencies[_last!];
  }
}
