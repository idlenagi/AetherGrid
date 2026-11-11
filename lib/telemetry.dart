import 'dart:io';
import 'dart:ui';

import 'vision_isolate.dart';

/// In-memory device and interaction telemetry. File I/O only happens on export.
class GameTelemetry {
  GameTelemetry({
    this.participantId = '',
    this.blockOrder = '',
    this.runLabelProvider,
    this.cameraActiveProvider,
  });

  static const _columns = <String>[
    'run_label',
    'participant_id',
    'mode',
    'block_order',
    'level_id',
    'trial_id',
    'attempt_number',
    'event',
    't_elapsed_us',
    'timestamp_utc',
    't_prompt_us',
    'target_prompted',
    'target_selected',
    'correct',
    'first_attempt_correct',
    'is_retry',
    'outcome',
    'selection_time_ms',
    'input_latency_ms',
    'latency_source',
    'trigger_type',
    'camera_active',
    'frame_ms',
    'build_ms',
    'raster_ms',
    'inference_ms',
    'camera_to_cursor_ms',
    'hand_detected',
    'pinching',
    'button',
    'button_rx_us',
    'button_handled_us',
    'button_proc_ms',
    'details',
  ];

  final String participantId;
  final String blockOrder;
  final String Function()? runLabelProvider;
  /// Fills camera_active on rows that don't set it explicitly (prompt,
  /// ui_frame, vision_frame, ...), so every row records the camera state.
  final bool Function()? cameraActiveProvider;
  final Stopwatch _clock = Stopwatch()..start();
  final List<Map<String, String>> _rows = [];
  final List<double> _build = [], _raster = [];
  final List<double> cameraToCursorLatencyMs = [];
  int inputEvents = 0, hoverFrames = 0, selectionEvents = 0;
  int droppedCameraFrames = 0, noHandFrames = 0;
  int _totalUiFrames = 0;
  int _trialId = 0;
  int _attemptNumber = 0;
  String _levelId = '';
  int? _promptUs;
  String _targetPrompted = '';
  String _mode = '';
  double? lastInputLatencyMs;

  int get nowUs => _clock.elapsedMicroseconds;
  int get trialId => _trialId;
  int? get promptUs => _promptUs;

  String get mode => _mode;
  void setMode(String mode) => _mode = mode;

  /// [levelId] describes the current puzzle rule, e.g. `multiples_of_3`.
  void setLevel(String levelId) => _levelId = levelId;

  /// Starts a new move prompt when the board becomes actionable or after a
  /// successful move. [targetPrompted] describes all currently valid choices.
  void beginPrompt(String targetPrompted) {
    _trialId++;
    _attemptNumber = 0;
    _promptUs = nowUs;
    _targetPrompted = targetPrompted;
    _append('prompt', fields: {
      'trial_id': '$_trialId',
      't_prompt_us': '$_promptUs',
      'target_prompted': _targetPrompted,
    });
  }

  void recordSelection({
    required int targetSelected,
    required bool correct,
    required String outcome,
    required String triggerType,
    required double? inputLatencyMs,
    bool? handDetected,
    bool? pinching,
    int? pointerDispatchUs,
    required String details,
    required bool cameraActive,
  }) {
    final promptUs = _promptUs;
    final selectionTimeMs = promptUs == null
        ? null
        : (nowUs - promptUs) / 1000;
    _attemptNumber++;
    final resolvedLatencyMs = triggerType == 'touch' && pointerDispatchUs != null
        ? (nowUs - pointerDispatchUs) / 1000
        : inputLatencyMs;
    final latencySource = triggerType == 'pinch'
        ? 'camera_capture_to_cursor'
        : pointerDispatchUs != null
        ? 'touch_pointerup_dispatch_to_game_handler'
        : 'unavailable_missing_pointerup_timestamp';
    final row = _makeRow('selection', fields: {
      'trial_id': '$_trialId',
      'attempt_number': '$_attemptNumber',
      't_prompt_us': promptUs?.toString() ?? '',
      'target_prompted': _targetPrompted,
      'target_selected': '$targetSelected',
      'correct': outcome == 'backtracked' ? '' : (correct ? '1' : '0'),
      'first_attempt_correct': _attemptNumber == 1 && outcome != 'backtracked'
          ? (correct ? '1' : '0')
          : '',
      'is_retry': _attemptNumber > 1 ? '1' : '0',
      'outcome': outcome,
      'selection_time_ms': selectionTimeMs?.toString() ?? '',
      'input_latency_ms': resolvedLatencyMs?.toString() ?? '',
      'latency_source': latencySource,
      'trigger_type': triggerType,
      'camera_active': cameraActive.toString(),
      'hand_detected': handDetected?.toString() ?? '',
      'pinching': pinching?.toString() ?? '',
      'camera_to_cursor_ms': triggerType == 'pinch'
          ? inputLatencyMs?.toString() ?? ''
          : '',
      'details': details,
    });
    _rows.add(row);
  }

  void recordPipelineEvent(String event, {required bool cameraActive}) {
    _append(event, fields: {
      'camera_active': cameraActive.toString(),
    });
  }

  void recordFrames(List<FrameTiming> frames) {
    for (final frame in frames) {
      _totalUiFrames++;
      final buildMs = frame.buildDuration.inMicroseconds / 1000;
      final rasterMs = frame.rasterDuration.inMicroseconds / 1000;
      final totalMs = frame.totalSpan.inMicroseconds / 1000;
      _build.add(buildMs);
      _raster.add(rasterMs);
      _append('ui_frame', fields: {
        'frame_ms': '$totalMs',
        'build_ms': '$buildMs',
        'raster_ms': '$rasterMs',
        'details': totalMs > 16.67 ? 'over_60fps_budget' : '',
      });
    }
    if (_build.length > 60) _build.removeRange(0, _build.length - 60);
    if (_raster.length > 60) _raster.removeRange(0, _raster.length - 60);
  }

  double? get buildMs =>
      _build.isEmpty ? null : _build.reduce((a, b) => a + b) / _build.length;
  double? get rasterMs =>
      _raster.isEmpty ? null : _raster.reduce((a, b) => a + b) / _raster.length;
  double? get averageCameraToCursorMs => cameraToCursorLatencyMs.isEmpty
      ? null
      : cameraToCursorLatencyMs.reduce((a, b) => a + b) /
            cameraToCursorLatencyMs.length;

  void recordVision(SpatialTelemetryPayload sample, double latencyMs) {
    cameraToCursorLatencyMs.add(latencyMs);
    if (cameraToCursorLatencyMs.length > 120) {
      cameraToCursorLatencyMs.removeAt(0);
    }
    _append('vision_frame', fields: {
      'inference_ms': '${sample.inferenceTimeMs}',
      'camera_to_cursor_ms': '$latencyMs',
      'hand_detected': '${sample.handDetected}',
      'pinching': '${sample.isPinching}',
      'timestamp_utc': sample.capturedAt.toUtc().toIso8601String(),
      'details': 'capture_to_ui_callback',
    });
  }

  /// This is app processing time from MQTT callback to the game handler, not
  /// the ESP32 button's one-way network latency or the player's reaction time.
  void recordButton({
    required String button,
    required int receivedAtUs,
    required int handledAtUs,
  }) {
    _append('esp32_button', fields: {
      'button': button,
      'button_rx_us': '$receivedAtUs',
      'button_handled_us': '$handledAtUs',
      'button_proc_ms': '${(handledAtUs - receivedAtUs) / 1000}',
      'details': 'tablet_mqtt_receive_to_game_handler',
    });
  }

  Future<File> saveDeviceLog(
    String path, {
    required String runLabel,
    required VisionMetrics vision,
  }) async {
    final allRows = <Map<String, String>>[
      ..._rows,
      _makeRow('summary', fields: {
        'details':
            'camera_frames=${vision.framesReceived};camera_dropped=${vision.droppedFrames};rate_limited=${vision.rateLimitedFrames};no_hand=${vision.noHandFrames};pinch_events=${vision.pinchEvents};ui_frames=$_totalUiFrames;ui_frames_over_16_67ms=${_rows.where((row) => row['details'] == 'over_60fps_budget').length}',
      }),
    ];
    final lines = <String>[
      _columns.join(','),
      for (final row in allRows)
        _csvRow(_columns.map((column) {
          if (column == 'run_label') {
            final rowLabel = row[column];
            return rowLabel == null || rowLabel.isEmpty ? runLabel : rowLabel;
          }
          return row[column] ?? '';
        }).toList()),
    ];
    return File(path).writeAsString(lines.join('\n'));
  }

  void _append(String event, {Map<String, String> fields = const {}, int? elapsedUs}) {
    _rows.add(_makeRow(event, fields: fields, elapsedUs: elapsedUs));
  }

  Map<String, String> _makeRow(
    String event, {
    Map<String, String> fields = const {},
    int? elapsedUs,
  }) => {
    'run_label': runLabelProvider?.call() ?? '',
    'participant_id': participantId,
    'mode': _mode,
    'block_order': blockOrder,
    'level_id': _levelId,
    'trial_id': '$_trialId',
    'event': event,
    't_elapsed_us': '${elapsedUs ?? nowUs}',
    'timestamp_utc': DateTime.now().toUtc().toIso8601String(),
    if (cameraActiveProvider != null)
      'camera_active': cameraActiveProvider!().toString(),
    ...fields,
  };

  static String _csvRow(List<String> fields) => fields.map((value) {
    if (value.contains(',') || value.contains('"') || value.contains('\n')) {
      return '"${value.replaceAll('"', '""')}"';
    }
    return value;
  }).join(',');
}
