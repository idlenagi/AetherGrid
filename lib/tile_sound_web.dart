import 'dart:js_interop';
import 'melody.dart';

@JS('AudioContext')
extension type _AudioContext._(JSObject _) implements JSObject {
  external factory _AudioContext();
  external double get currentTime;
  external JSObject get destination;
  external JSPromise<JSAny?> resume();
  external JSPromise<JSAny?> close();
  external _Oscillator createOscillator();
  external _Gain createGain();
}
extension type _Oscillator._(JSObject _) implements JSObject {
  external _AudioParam get frequency;
  external void connect(JSObject node);
  external void start(double time);
  external void stop(double time);
}
extension type _Gain._(JSObject _) implements JSObject {
  external _AudioParam get gain;
  external void connect(JSObject node);
}
extension type _AudioParam._(JSObject _) implements JSObject {
  external void setValueAtTime(double value, double time);
  external void exponentialRampToValueAtTime(double value, double time);
}

/// A short, softly fading click synthesized locally; no downloads required.
class TileSound {
  final melody = TileMelody();
  _AudioContext? _context;
  void play({bool invalid = false, bool celebration = false}) {
    try {
      final context = _context ??= _AudioContext();
      context.resume();
      final time = context.currentTime;
      final frequency = invalid
          ? 146.83
          : celebration
              ? 523.25
              : melody.next();
      // Stable pitch, quick attack, and decaying harmonics give a piano-like note.
      for (var harmonic = 1; harmonic <= 3; harmonic++) {
        final oscillator = context.createOscillator();
        final gain = context.createGain();
        oscillator.frequency.setValueAtTime(frequency * harmonic, time);
        if (invalid) {
          oscillator.frequency
              .exponentialRampToValueAtTime(98.0 * harmonic, time + .2);
        }
        gain.gain.setValueAtTime(.001, time);
        gain.gain.exponentialRampToValueAtTime(
            .12 / (harmonic * harmonic), time + .008);
        gain.gain.exponentialRampToValueAtTime(.001, time + .55 / harmonic);
        oscillator.connect(gain);
        gain.connect(context.destination);
        oscillator.start(time);
        oscillator.stop(time + .6);
      }
    } catch (_) {
      // Audio availability must not interrupt grid input.
    }
  }

  void dispose() {
    _context?.close();
    _context = null;
  }
}
