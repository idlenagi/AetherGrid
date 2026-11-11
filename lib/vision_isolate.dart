import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:hand_detection/hand_detection.dart';

/// Hand-tracking data sent from the detector to the game UI.
class SpatialTelemetryPayload {
  final double normalizedX;
  final double normalizedY;
  final bool isPinching;
  final double pinchDistance;
  final int conversionTimeUs;
  final int inferenceTimeMs;
  final bool handDetected;
  final DateTime capturedAt;
  final DateTime updatedAt;

  const SpatialTelemetryPayload({
    required this.normalizedX,
    required this.normalizedY,
    required this.isPinching,
    required this.pinchDistance,
    required this.conversionTimeUs,
    required this.inferenceTimeMs,
    required this.handDetected,
    required this.capturedAt,
    required this.updatedAt,
  });
}

class VisionMetrics {
  static const requestedResolution = 'ResolutionPreset.low';
  static const targetInferenceFps = 20;
  int framesReceived = 0;
  int droppedFrames = 0;
  int rateLimitedFrames = 0;
  int noHandFrames = 0;
  int pinchEvents = 0;
  final List<DateTime> pinchEventTimes = [];
  double? lastInferenceMs;
  double? lastCameraToCursorMs;
  int? frameWidth;
  int? frameHeight;
  String? imageFormat;
  final List<double> _captureIntervalsMs = [];
  DateTime? _previousCapture;
  final List<double> _recentInferenceMs = [];

  void reset() {
    framesReceived = 0;
    droppedFrames = 0;
    rateLimitedFrames = 0;
    noHandFrames = 0;
    pinchEvents = 0;
    pinchEventTimes.clear();
    lastInferenceMs = null;
    lastCameraToCursorMs = null;
    frameWidth = null;
    frameHeight = null;
    imageFormat = null;
    _captureIntervalsMs.clear();
    _previousCapture = null;
    _recentInferenceMs.clear();
  }

  double? get averageInferenceMs => _average(_recentInferenceMs);
  double? get averageCameraFps {
    final interval = _average(_captureIntervalsMs);
    return interval == null || interval <= 0 ? null : 1000 / interval;
  }
  static double? _average(List<double> values) => values.isEmpty
      ? null
      : values.reduce((a, b) => a + b) / values.length;
  void _recordInference(double value) {
    lastInferenceMs = value;
    _recentInferenceMs.add(value);
    if (_recentInferenceMs.length > 120) _recentInferenceMs.removeAt(0);
  }

  void recordLatency(double value) {
    lastCameraToCursorMs = value;
  }

  void recordFrame(CameraImage image, DateTime capturedAt) {
    frameWidth = image.width;
    frameHeight = image.height;
    imageFormat = image.format.group.name;
    final previous = _previousCapture;
    if (previous != null) {
      _captureIntervalsMs.add(
        capturedAt.difference(previous).inMicroseconds / 1000,
      );
      if (_captureIntervalsMs.length > 120) _captureIntervalsMs.removeAt(0);
    }
    _previousCapture = capturedAt;
  }
}

class VisionFeatureSample {
  const VisionFeatureSample({
    required this.capturedAt,
    required this.x,
    required this.y,
    required this.pinchRatio,
  });
  final DateTime capturedAt;
  final double x;
  final double y;
  final double pinchRatio;

  Map<String, Object> toJson() => {
    't': capturedAt.toIso8601String(),
    'x': x,
    'y': y,
    'pinch': pinchRatio,
  };

  factory VisionFeatureSample.fromJson(Map<String, dynamic> json) =>
      VisionFeatureSample(
        capturedAt: DateTime.parse(json['t'] as String),
        x: (json['x'] as num).toDouble(),
        y: (json['y'] as num).toDouble(),
        pinchRatio: (json['pinch'] as num).toDouble(),
      );
}

class VisionReplayPoint {
  const VisionReplayPoint(this.x, this.y, this.pressing);
  final double x;
  final double y;
  final bool pressing;
}

/// Runs a hand-only landmark detector on camera frames.
///
/// Inference is performed in the hand_detection package's worker isolate.
class VisionIsolateController {
  final VisionMetrics metrics = VisionMetrics();
  final ValueNotifier<SpatialTelemetryPayload?> telemetryStream = ValueNotifier(
    null,
  );

  HandDetector? _detector;
  bool _isWorkerBusy = false;
  bool _disposed = false;
  bool _recordingFeatures = false;
  DateTime? _lastDispatchedAt;
  final List<VisionFeatureSample> featureRecording = [];
  bool _hasTrackedHand = false;
  bool _isCurrentlyPinching = false;
  int _missedFrames = 0;
  int _pinchFrames = 0;
  int _releaseFrames = 0;
  bool _hasCursorPosition = false;
  double _smoothedX = 0.5;
  double _smoothedY = 0.5;
  double _lastPinchDistance = 999.0;

  Future<void> spawnWorker() async {
    if (_disposed || _detector != null) return;
    _detector = await HandDetector.create(
      mode: HandMode.boxesAndLandmarks,
      maxDetections: 1,
      minLandmarkScore: 0.5,
      enableTracking: true,
    );
  }

  /// Stops inference and releases the model isolate while preserving the
  /// telemetry notifier so spatial tracking can be resumed later.
  Future<void> pauseWorker() async {
    while (_isWorkerBusy && !_disposed) {
      await Future<void>.delayed(const Duration(milliseconds: 8));
    }
    final detector = _detector;
    _detector = null;
    _hasTrackedHand = false;
    _isCurrentlyPinching = false;
    _missedFrames = 0;
    _pinchFrames = 0;
    _releaseFrames = 0;
    _hasCursorPosition = false;
    _lastDispatchedAt = null;
    if (!_disposed) telemetryStream.value = null;
    if (detector != null) await detector.dispose();
  }

  /// Drops incoming frames while inference is in flight to avoid stale input.
  void dispatchFrame(
    CameraImage image,
    int sensorOrientation, {
    required bool isFrontCamera,
    required DeviceOrientation deviceOrientation,
    DateTime? capturedAt,
  }) {
    final frameCapturedAt = capturedAt ?? DateTime.now();
    metrics.recordFrame(image, frameCapturedAt);
    metrics.framesReceived++;
    final previousDispatch = _lastDispatchedAt;
    final minimumIntervalMs = 1000 / VisionMetrics.targetInferenceFps;
    if (previousDispatch != null &&
        frameCapturedAt.difference(previousDispatch).inMicroseconds / 1000 <
            minimumIntervalMs) {
      metrics.droppedFrames++;
      metrics.rateLimitedFrames++;
      return;
    }
    if (_isWorkerBusy || _disposed || _detector == null) {
      metrics.droppedFrames++;
      return;
    }
    _lastDispatchedAt = frameCapturedAt;
    _isWorkerBusy = true;
    unawaited(
      _processFrame(
        image,
        sensorOrientation,
        isFrontCamera: isFrontCamera,
        deviceOrientation: deviceOrientation,
        capturedAt: frameCapturedAt,
      ),
    );
  }

  Future<void> _processFrame(
    CameraImage image,
    int sensorOrientation, {
    required bool isFrontCamera,
    required DeviceOrientation deviceOrientation,
    required DateTime capturedAt,
  }) async {
    final stopwatch = Stopwatch()..start();
    try {
      final rotation = rotationForFrame(
        width: image.width,
        height: image.height,
        sensorOrientation: sensorOrientation,
        isFrontCamera: isFrontCamera,
        deviceOrientation: deviceOrientation,
      );
      final hands = await _detector!.detectFromCameraImage(
        image,
        rotation: rotation,
        maxDim: 640,
      );
      stopwatch.stop();
      metrics._recordInference(stopwatch.elapsedMicroseconds / 1000);
      if (_disposed) return;

      if (hands.isEmpty || !hands.first.hasLandmarks) {
        _publishMiss(stopwatch.elapsedMicroseconds / 1000, capturedAt);
        return;
      }

      final hand = hands.first;
      final indexTip = hand.getLandmark(HandLandmarkType.indexFingerTip);
      final thumbTip = hand.getLandmark(HandLandmarkType.thumbTip);
      if (indexTip == null || thumbTip == null) {
        _publishMiss(stopwatch.elapsedMicroseconds / 1000, capturedAt);
        return;
      }

      final imageWidth = hand.imageWidth.toDouble();
      final imageHeight = hand.imageHeight.toDouble();
      if (imageWidth <= 0 || imageHeight <= 0) {
        _publishMiss(stopwatch.elapsedMicroseconds / 1000, capturedAt);
        return;
      }

      final rawX = (1.0 - indexTip.x / imageWidth).clamp(0.0, 1.0);
      final rawY = (indexTip.y / imageHeight).clamp(0.0, 1.0);
      if (!_hasCursorPosition || !_hasTrackedHand && _missedFrames > 2) {
        _smoothedX = rawX;
        _smoothedY = rawY;
        _hasCursorPosition = true;
      } else {
        final deltaX = rawX - _smoothedX;
        final deltaY = rawY - _smoothedY;
        final movement = sqrt(deltaX * deltaX + deltaY * deltaY);
        // A short dead zone calms fingertip jitter; larger movements catch up
        // faster so the cursor does not trail behind the hand.
        if (movement > 0.004) {
          final alpha = movement > 0.12
              ? 0.5
              : movement > 0.035
              ? 0.32
              : 0.2;
          _smoothedX += alpha * deltaX;
          _smoothedY += alpha * deltaY;
        }
      }

      final dx = indexTip.x - thumbTip.x;
      final dy = indexTip.y - thumbTip.y;
      final distance = sqrt(dx * dx + dy * dy);
      final wrist = hand.getLandmark(HandLandmarkType.wrist);
      final middleMcp = hand.getLandmark(HandLandmarkType.middleFingerMCP);
      final handScale = wrist != null && middleMcp != null
          ? sqrt(pow(wrist.x - middleMcp.x, 2) + pow(wrist.y - middleMcp.y, 2))
          : sqrt(imageWidth * imageWidth + imageHeight * imageHeight) * 0.18;
      final normalizedDistance = distance / max(handScale, 1.0);
      if (_recordingFeatures) {
        featureRecording.add(
          VisionFeatureSample(
            capturedAt: capturedAt,
            x: rawX,
            y: rawY,
            pinchRatio: normalizedDistance,
          ),
        );
      }
      if (!_isCurrentlyPinching) {
        _releaseFrames = 0;
        _pinchFrames = normalizedDistance < 0.30 ? _pinchFrames + 1 : 0;
        if (_pinchFrames >= 2) {
          _isCurrentlyPinching = true;
          _pinchFrames = 0;
          metrics.pinchEvents++;
          metrics.pinchEventTimes.add(DateTime.now());
        }
      } else {
        _pinchFrames = 0;
        _releaseFrames = normalizedDistance > 0.42 ? _releaseFrames + 1 : 0;
        if (_releaseFrames >= 2) {
          _isCurrentlyPinching = false;
          _releaseFrames = 0;
        }
      }

      _missedFrames = 0;
      _hasTrackedHand = true;
      _lastPinchDistance = normalizedDistance;
      telemetryStream.value = SpatialTelemetryPayload(
        normalizedX: _smoothedX,
        normalizedY: _smoothedY,
        isPinching: _isCurrentlyPinching,
        pinchDistance: normalizedDistance,
        conversionTimeUs: 0,
        inferenceTimeMs: stopwatch.elapsedMicroseconds ~/ 1000,
        handDetected: true,
        capturedAt: capturedAt,
        updatedAt: DateTime.now(),
      );
      metrics.recordLatency(DateTime.now().difference(capturedAt).inMicroseconds / 1000);
    } catch (error, stackTrace) {
      debugPrint('Hand landmark detection failed: $error\n$stackTrace');
      stopwatch.stop();
      if (!_disposed) {
        if (stopwatch.isRunning) stopwatch.stop();
        metrics._recordInference(stopwatch.elapsedMicroseconds / 1000);
        _publishMiss(stopwatch.elapsedMicroseconds / 1000, capturedAt);
      }
    } finally {
      _isWorkerBusy = false;
    }
  }

  void startFeatureRecording() {
    featureRecording.clear();
    _recordingFeatures = true;
  }

  List<VisionFeatureSample> stopFeatureRecording() {
    _recordingFeatures = false;
    return List.unmodifiable(featureRecording);
  }

  String exportFeatureRecording() => jsonEncode(
    featureRecording.map((sample) => sample.toJson()).toList(),
  );

  static List<VisionFeatureSample> importFeatureRecording(String json) =>
      (jsonDecode(json) as List<dynamic>)
          .map(
            (sample) => VisionFeatureSample.fromJson(
              Map<String, dynamic>.from(sample as Map),
            ),
          )
          .toList(growable: false);

  static List<VisionReplayPoint> replayFeatureRecording(
    Iterable<VisionFeatureSample> samples, {
    double smoothingAlpha = 0.32,
    double pinchOn = 0.30,
    double pinchOff = 0.42,
    int debounceFrames = 2,
  }) {
    var x = 0.5, y = 0.5, pressing = false;
    var onFrames = 0, offFrames = 0, first = true;
    final replay = <VisionReplayPoint>[];
    for (final sample in samples) {
      if (first) {
        x = sample.x;
        y = sample.y;
        first = false;
      } else {
        x += smoothingAlpha.clamp(0.0, 1.0) * (sample.x - x);
        y += smoothingAlpha.clamp(0.0, 1.0) * (sample.y - y);
      }
      if (!pressing) {
        onFrames = sample.pinchRatio < pinchOn ? onFrames + 1 : 0;
        if (onFrames >= debounceFrames) {
          pressing = true;
          onFrames = 0;
        }
      } else {
        offFrames = sample.pinchRatio > pinchOff ? offFrames + 1 : 0;
        if (offFrames >= debounceFrames) {
          pressing = false;
          offFrames = 0;
        }
      }
      replay.add(VisionReplayPoint(x, y, pressing));
    }
    return replay;
  }

  void _publishMiss(double inferenceTimeMs, DateTime capturedAt) {
    if (_disposed) return;
    _missedFrames++;
    metrics.noHandFrames++;
    _pinchFrames = 0;
    _releaseFrames = 0;
    final stillTracking = _hasTrackedHand && _missedFrames <= 2;
    if (!stillTracking) {
      _hasTrackedHand = false;
      _isCurrentlyPinching = false;
    }
    telemetryStream.value = SpatialTelemetryPayload(
      normalizedX: _smoothedX,
      normalizedY: _smoothedY,
      isPinching: stillTracking && _isCurrentlyPinching,
      pinchDistance: stillTracking ? _lastPinchDistance : 999.0,
      conversionTimeUs: 0,
      inferenceTimeMs: inferenceTimeMs.round(),
      handDetected: stillTracking,
      capturedAt: capturedAt,
      updatedAt: DateTime.now(),
    );
  }

  void dispose() {
    _disposed = true;
    final detector = _detector;
    _detector = null;
    if (detector != null) unawaited(detector.dispose());
    telemetryStream.dispose();
  }
}
