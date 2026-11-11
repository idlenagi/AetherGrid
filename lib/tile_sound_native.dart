import 'package:flutter/services.dart';

class TileSound {
  void play({bool invalid = false, bool celebration = false}) {
    SystemSound.play(invalid ? SystemSoundType.alert : SystemSoundType.click);
    if (invalid) {
      HapticFeedback.mediumImpact();
    } else {
      HapticFeedback.selectionClick();
    }
  }

  void dispose() {}
}
