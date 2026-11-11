import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:mqtt_client/mqtt_client.dart' show MqttQos;

// Your Vision & Backend Imports
import 'vision_isolate.dart';

// Irma's Game Engine Imports
import 'engine.dart';
import 'tile_sound.dart';
import 'flowing_gradient.dart';
import 'circular_control.dart';
import 'telemetry.dart';
import 'mqtt_service.dart';
import 'forest_mascot.dart';
import 'welcome_screen.dart';

List<CameraDescription> _cameras = const [];
const MethodChannel _exportChannel = MethodChannel('aether_grid/export');
/// Fixed run_label for game sessions. Benchmarks keep their `q<qos>_r<n>` labels.
const String _studyRunLabel = 'study';

const String _windowsBenchmarkDirectory =
    r'C:\Users\Theresia\Documents\Benchmark Data';

Future<String> _exportMqttLog(
  MqttService mqtt, {
  String? outputDirectory,
  String fileTag = '',
}) async {
  final runLabel = mqtt.runLabel;
  await Future<void>.delayed(const Duration(seconds: 2));
  final directory = outputDirectory ??
      await _exportChannel.invokeMethod<String>('getExportDirectory');
  if (directory == null || directory.isEmpty) {
    throw StateError('Could not locate the app export folder.');
  }
  await Directory(directory).create(recursive: true);
  final safeLabel = runLabel.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
  final file = await mqtt.saveLog(
    '$directory/mqtt_run_$safeLabel$fileTag.csv',
    runLabel: runLabel,
  );
  return file.path;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    _cameras = await availableCameras();
  } catch (error) {
    debugPrint('Camera enumeration failed: $error');
  }
  runApp(const AetherGridApp());
}

// ============================================================================
// 1. INPUT CONTRACT & SPATIAL ADAPTER
// ============================================================================
enum InputMode { touch, spatial }

enum InputKind { hover, select }

const int _spatialRestart = -3;
const int _spatialNext = -4;
const int _spatialStart = -5;

class GameInputEvent {
  final int index;
  final InputKind kind;
  final DateTime? emittedAt;
  final bool isSpatial;
  final int? pointerDispatchUs;
  final double? inputLatencyMs;
  const GameInputEvent(
    this.index,
    this.kind, {
    this.emittedAt,
    this.isSpatial = false,
    this.pointerDispatchUs,
    this.inputLatencyMs,
  });
}

class InputModeLogEntry {
  const InputModeLogEntry(this.mode, this.changedAt);
  final InputMode mode;
  final DateTime changedAt;

  Map<String, String> toJson() => {
    'mode': mode.name,
    'timestamp': changedAt.toIso8601String(),
  };
}

abstract class InputProvider {
  Stream<GameInputEvent> get events;
  void dispose();
}

/// Irma's Local Touch Provider
class LocalInputProvider implements InputProvider {
  final _controller = StreamController<GameInputEvent>.broadcast();
  @override
  Stream<GameInputEvent> get events => _controller.stream;
  void emit(GameInputEvent event) {
    if (!_controller.isClosed) {
      _controller.add(
        GameInputEvent(
          event.index,
          event.kind,
          emittedAt: event.emittedAt ?? DateTime.now(),
          pointerDispatchUs: event.pointerDispatchUs,
          inputLatencyMs: event.inputLatencyMs,
        ),
      );
    }
  }

  @override
  void dispose() => _controller.close();
}

/// The Bridge: Converts your Isolate coordinates to Irma's GameInputEvents
class SpatialInputProvider implements InputProvider {
  final _controller = StreamController<GameInputEvent>.broadcast();
  int currentGridSize = 3; // Dynamically updated by GameScreen
  Rect? gridRect;
  final Map<int, Rect> actionRects = {};
  bool modalActionsOnly = false;
  int? _lastHoverIndex;

  int? indexAt(Offset position) {
    for (final entry in actionRects.entries) {
      if (entry.value.contains(position)) return entry.key;
    }
    if (modalActionsOnly) return null;
    final rect = gridRect;
    if (rect == null || !rect.contains(position) || currentGridSize <= 0) {
      return null;
    }
    final cellWidth = rect.width / currentGridSize;
    final cellHeight = rect.height / currentGridSize;
    final last = _lastHoverIndex;
    if (last != null && last >= 0 && last < currentGridSize * currentGridSize) {
      final lastRect = Rect.fromLTWH(
        rect.left + (last % currentGridSize) * cellWidth,
        rect.top + (last ~/ currentGridSize) * cellHeight,
        cellWidth,
        cellHeight,
      ).inflate(min(cellWidth, cellHeight) * 0.08);
      if (lastRect.contains(position)) return last;
    }
    final col = ((position.dx - rect.left) / rect.width * currentGridSize)
        .floor()
        .clamp(0, currentGridSize - 1)
        .toInt();
    final row = ((position.dy - rect.top) / rect.height * currentGridSize)
        .floor()
        .clamp(0, currentGridSize - 1)
        .toInt();
    _lastHoverIndex = row * currentGridSize + col;
    return _lastHoverIndex;
  }

  @override
  Stream<GameInputEvent> get events => _controller.stream;

  void emitHover(int index) {
    if (!_controller.isClosed) {
      _controller.add(
        GameInputEvent(
          index,
          InputKind.hover,
          emittedAt: DateTime.now(),
          isSpatial: true,
        ),
      );
    }
  }

  void emitSelect(int index, {double? inputLatencyMs}) {
    if (!_controller.isClosed) {
      _controller.add(
        GameInputEvent(
          index,
          InputKind.select,
          emittedAt: DateTime.now(),
          isSpatial: true,
          inputLatencyMs: inputLatencyMs,
        ),
      );
    }
  }

  @override
  void dispose() => _controller.close();
}

// ============================================================================
// 2. ROOT APP & CAMERA PIPELINE LAYER
// ============================================================================
class AetherGridApp extends StatelessWidget {
  const AetherGridApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Aether Grid',
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xff78956d),
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xff172019),
      ),
      home: const CameraPipelineStack(),
    );
  }
}

class CameraPipelineStack extends StatefulWidget {
  const CameraPipelineStack({super.key});

  @override
  State<CameraPipelineStack> createState() => _CameraPipelineStackState();
}

class _CameraPipelineStackState extends State<CameraPipelineStack>
    with WidgetsBindingObserver {
  static const _mqttHost = String.fromEnvironment('MQTT_HOST');
  final GlobalKey _trackingSurfaceKey = GlobalKey();
  CameraController? _controller;
  final VisionIsolateController _isolateController = VisionIsolateController();
  final SpatialInputProvider _spatialProvider = SpatialInputProvider();
  MqttService? _mqttService;
  final ValueNotifier<InputMode> _inputMode = ValueNotifier(InputMode.touch);
  final List<InputModeLogEntry> _inputModeLog = [];
  Future<void> _pipelineTransitions = Future<void>.value();

  bool _isCameraInitialized = false;
  bool _hasStarted = false;
  bool _preparingRun = false;
  GameTelemetry? _activeTelemetry;
  String _participantId = '';
  String _blockOrder = '';
  bool _benchmarkRunning = false;
  bool _cameraUnavailable = false;
  bool _startingCamera = false;
  bool _workerStarted = false;
  bool _appPaused = false;
  String? _cameraMessage;
  int _lastEmittedIndex = -1;
  bool _lastEmittedPinch = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _inputMode.addListener(_onInputModeChanged);
    _inputModeLog.add(InputModeLogEntry(_inputMode.value, DateTime.now()));
    if (_mqttHost.isNotEmpty) {
      _mqttService = MqttService(host: _mqttHost);
      unawaited(() async {
        final connected = await _mqttService!.connect();
        if (!connected) debugPrint('MQTT unavailable; continuing offline.');
      }());
    }
  }

  Future<void> startTracking() async {
    if (_inputMode.value != InputMode.spatial ||
        _appPaused ||
        _startingCamera ||
        _controller?.value.isStreamingImages == true) {
      return;
    }
    _startingCamera = true;
    if (_cameras.isEmpty) {
      _setCameraUnavailable('Camera unavailable. You can still play with touch.');
      _startingCamera = false;
      return;
    }

    CameraController? controller;
    try {
      if (!_workerStarted) {
        await _isolateController.spawnWorker();
        _workerStarted = true;
        _activeTelemetry?.recordPipelineEvent(
          'detector_ready',
          cameraActive: _controller?.value.isStreamingImages == true,
        );
      }
      final frontCamera = _cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.front,
        orElse: () => _cameras.first,
      );

      controller = CameraController(
        frontCamera,
        ResolutionPreset.low,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );
      _controller = controller;
      await controller.initialize();
      if (_appPaused || !mounted) {
        await controller.dispose();
        if (identical(_controller, controller)) _controller = null;
        return;
      }
      final int sensorOrientation = frontCamera.sensorOrientation;
      await controller.startImageStream((CameraImage image) {
        _isolateController.dispatchFrame(
          image,
          sensorOrientation,
          isFrontCamera: frontCamera.lensDirection == CameraLensDirection.front,
          deviceOrientation: controller!.value.deviceOrientation,
          capturedAt: DateTime.now(),
        );
      });
      _activeTelemetry?.recordPipelineEvent('camera_start', cameraActive: true);

      _isolateController.telemetryStream.removeListener(_onTelemetryUpdate);
      _isolateController.telemetryStream.addListener(_onTelemetryUpdate);
      if (mounted) {
        setState(() {
          _isCameraInitialized = true;
          _cameraUnavailable = false;
          _cameraMessage = null;
        });
      }
    } catch (error) {
      debugPrint('Camera initialization error: $error');
      await _releaseCamera();
      await _isolateController.pauseWorker();
      _workerStarted = false;
      _setCameraUnavailable(
        'Camera unavailable or permission denied. You can still play with touch.',
      );
    } finally {
      _startingCamera = false;
    }
  }

  void _setCameraUnavailable(String message) {
    if (!mounted) return;
    setState(() {
      _isCameraInitialized = false;
      _cameraUnavailable = true;
      _cameraMessage = message;
    });
  }

  void _onInputModeChanged() {
    _inputModeLog.add(InputModeLogEntry(_inputMode.value, DateTime.now()));
    if (_hasStarted) {
      _mqttService?.sendEvent(
        'input_mode',
        extra: {'mode': _inputMode.value.name},
      );
    }
    _queuePipelineSync();
  }

  void _queuePipelineSync() {
    _pipelineTransitions = _pipelineTransitions.then((_) async {
      if (!mounted) return;
      try {
        if (_appPaused || _inputMode.value != InputMode.spatial) {
          await _stopVisionPipeline();
        } else {
          await startTracking();
        }
      } catch (error, stackTrace) {
        debugPrint('Vision mode transition failed: $error\n$stackTrace');
      }
    });
  }

  Future<void> _stopVisionPipeline() async {
    _isolateController.telemetryStream.removeListener(_onTelemetryUpdate);
    final hadCamera = _controller?.value.isStreamingImages == true;
    final hadDetector = _workerStarted;
    await _releaseCamera();
    if (hadCamera) {
      _activeTelemetry?.recordPipelineEvent('camera_stop', cameraActive: false);
    }
    await _isolateController.pauseWorker();
    if (hadDetector) {
      _activeTelemetry?.recordPipelineEvent('detector_paused', cameraActive: false);
    }
    _workerStarted = false;
    _lastEmittedIndex = -1;
    _lastEmittedPinch = false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _appPaused = true;
      _queuePipelineSync();
    } else if (state == AppLifecycleState.resumed) {
      _appPaused = false;
      _queuePipelineSync();
    }
  }

  Future<void> _releaseCamera() async {
    final controller = _controller;
    _controller = null;
    _isCameraInitialized = false;
    if (controller == null) return;
    try {
      if (controller.value.isStreamingImages) await controller.stopImageStream();
      await controller.dispose();
    } catch (error) {
      debugPrint('Camera release error: $error');
    }
  }

  void _onTelemetryUpdate() {
    final data = _isolateController.telemetryStream.value;
    if (data == null) return;
    if (_inputMode.value != InputMode.spatial || !_isCameraInitialized) return;
    _isolateController.metrics.recordLatency(
      DateTime.now().difference(data.capturedAt).inMicroseconds / 1000,
    );
    if (!data.handDetected) {
      if (_lastEmittedIndex != -1) _spatialProvider.emitHover(-1);
      _lastEmittedIndex = -1;
      _lastEmittedPinch = false;
      return;
    }

    final surfaceContext = _trackingSurfaceKey.currentContext;
    final surfaceObject = surfaceContext?.findRenderObject();
    if (surfaceObject is! RenderBox || !surfaceObject.hasSize) return;
    final cursorPosition = Offset(
      data.normalizedX * surfaceObject.size.width,
      data.normalizedY * surfaceObject.size.height,
    );
    final cameraToCursorMs =
        DateTime.now().difference(data.capturedAt).inMicroseconds / 1000;
    final index = _spatialProvider.indexAt(cursorPosition);

    // Rising Edge Pinch Detection (Click)
    if (index != null && data.isPinching && !_lastEmittedPinch) {
      _spatialProvider.emitSelect(index, inputLatencyMs: cameraToCursorMs);
    }
    // State-change filter for Hover to avoid stream flooding
    else if (index != _lastEmittedIndex && !data.isPinching) {
      _spatialProvider.emitHover(index ?? -1);
    }

    _lastEmittedIndex = index ?? -1;
    _lastEmittedPinch = data.isPinching;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _inputMode.removeListener(_onInputModeChanged);
    _inputMode.dispose();
    _isolateController.telemetryStream.removeListener(_onTelemetryUpdate);
    _isolateController.dispose();
    final controller = _controller;
    if (controller != null) unawaited(controller.dispose());
    _spatialProvider.dispose();
    final mqttService = _mqttService;
    if (mqttService != null) unawaited(mqttService.dispose());
    super.dispose();
  }

  Future<void> _runIdleBenchmark(int qos) async {
    final mqtt = _mqttService;
    if (_benchmarkRunning) return;
    if (mqtt == null || !mqtt.isConnected) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Connect to the MQTT broker before the benchmark.')),
      );
      return;
    }
    setState(() => _benchmarkRunning = true);
    _inputMode.value = InputMode.touch;
    await _pipelineTransitions;
    await _stopVisionPipeline();
    try {
      // runLatencyTest starts the run, so the label (q<qos>_r<n>), the CSV qos
      // column and the ESP32 echo QoS all come from this one setting.
      mqtt.setQos(
        qos == 1 ? MqttQos.atLeastOnce : MqttQos.atMostOnce,
        startNewRun: false,
      );
      final result = await mqtt.runLatencyTest(
        count: 500,
        rateHz: 10,
      );
      final csvPath = await _exportMqttLog(
        mqtt,
        outputDirectory: Platform.isWindows
            ? _windowsBenchmarkDirectory
            : null,
      );
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Idle MQTT benchmark complete'),
          content: Text(
            'Sent ${result.sent} of 500 at 10 events/second. Received ${result.received}; lost ${result.lost}.\\n'
            'RTT p50 ${result.p50?.toStringAsFixed(2) ?? '—'} ms · '
            'p95 ${result.p95?.toStringAsFixed(2) ?? '—'} ms · '
            'p99 ${result.p99?.toStringAsFixed(2) ?? '—'} ms · '
            'max ${result.max?.toStringAsFixed(2) ?? '—'} ms.\\n\\n'
            'No game screen or hand tracking was active. CSV saved to: $csvPath',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Done'),
            ),
          ],
        ),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Idle benchmark failed: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _benchmarkRunning = false);
    }
  }

  Widget _buildTrackingSurface() {
    return LayoutBuilder(
      builder: (context, constraints) {
        return Stack(
          key: _trackingSurfaceKey,
          fit: StackFit.expand,
          children: [
            GameScreen(
              inputProvider: _spatialProvider,
              inputMode: _inputMode,
              inputModeLog: _inputModeLog,
              spatialSurfaceKey: _trackingSurfaceKey,
              visionController: _isolateController,
              mqttService: _mqttService,
              participantId: _participantId,
              blockOrder: _blockOrder,
              telemetry: _activeTelemetry!,
              cameraActive: () => _controller?.value.isStreamingImages == true,
              spatialAvailable: !_cameraUnavailable,
              onGridSizeChanged: (newSize) {
                _spatialProvider.currentGridSize = newSize;
              },
            ),
            if (_cameraUnavailable)
              Positioned(
                left: 16,
                right: 16,
                top: MediaQuery.paddingOf(context).top + 8,
                child: Material(
                  color: const Color(0xff5b3b2e),
                  borderRadius: BorderRadius.circular(12),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(_cameraMessage ?? 'Camera unavailable. Touch controls are ready.'),
                  ),
                ),
              ),
            ValueListenableBuilder<InputMode>(
              valueListenable: _inputMode,
              builder: (context, inputMode, _) {
                if (inputMode != InputMode.spatial ||
                    _cameraUnavailable ||
                    !_isCameraInitialized) {
                  return const SizedBox.shrink();
                }
                return ValueListenableBuilder<SpatialTelemetryPayload?>(
                  valueListenable: _isolateController.telemetryStream,
                  builder: (context, telemetry, _) {
                    if (telemetry == null || !telemetry.handDetected) {
                      return const SizedBox.shrink();
                    }
                    final cursorX = telemetry.normalizedX * constraints.maxWidth;
                    final cursorY = telemetry.normalizedY * constraints.maxHeight;
                    return Positioned(
                      left: cursorX - 18,
                      top: cursorY - 18,
                      child: IgnorePointer(
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 45),
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: telemetry.isPinching
                                ? const Color(0xffe2c887).withValues(alpha: 0.9)
                                : const Color(0xffa8ceae).withValues(alpha: 0.62),
                            border: Border.all(color: Colors.white, width: 2.5),
                            boxShadow: const [
                              BoxShadow(color: Colors.black45, blurRadius: 8),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_hasStarted) {
      return WelcomeScreen(
        initialParticipantId: const String.fromEnvironment('PARTICIPANT_ID'),
        initialBlockOrder: const String.fromEnvironment('BLOCK_ORDER'),
        benchmarkRunning: _benchmarkRunning,
        spatialAvailable: !_cameraUnavailable,
        preparing: _preparingRun,
        onBenchmark: _runIdleBenchmark,
        onPlay: (participantId, blockOrder, mode) async {
          if (_preparingRun) return;
          setState(() => _preparingRun = true);
          _participantId = participantId;
          _blockOrder = blockOrder;
          final selectedMode = mode == 'touch' ? InputMode.touch : InputMode.spatial;
          _isolateController.metrics.reset();
          // Label the session before anything is logged: changing the input
          // mode below starts the camera and writes detector_ready /
          // camera_start, which must carry the same label as the rest.
          _mqttService?.startRun(label: _studyRunLabel);
          _activeTelemetry = GameTelemetry(
            participantId: participantId,
            blockOrder: blockOrder,
            runLabelProvider: () => _studyRunLabel,
            cameraActiveProvider: () =>
                _controller?.value.isStreamingImages == true,
          )..setMode(selectedMode == InputMode.spatial ? 'gesture' : 'touch');
          _inputMode.value = selectedMode;
          await _pipelineTransitions;
          if (!mounted) return;
          final ready = selectedMode == InputMode.touch ||
              (_isCameraInitialized && _workerStarted &&
                  _controller?.value.isStreamingImages == true);
          if (!ready) {
            _activeTelemetry = null;
            setState(() => _preparingRun = false);
            return;
          }
          setState(() {
            _hasStarted = true;
            _preparingRun = false;
          });
        },
      );
    }

    return _buildTrackingSurface();
  }
}

// ============================================================================
// 3. IRMA'S GAME UI ENGINE (Modified for Transparency & Grid Sync)
// ============================================================================
class GameScreen extends StatefulWidget {
  const GameScreen({
    super.key,
    this.inputProvider,
    this.difficultyEngine,
    this.now,
    this.onGridSizeChanged,
    this.spatialSurfaceKey,
    this.inputMode,
    this.inputModeLog = const [],
    this.spatialAvailable = true,
    this.visionController,
    this.mqttService,
    this.participantId = '',
    this.blockOrder = '',
    required this.telemetry,
    required this.cameraActive,
  });

  final DateTime Function()? now;
  final InputProvider? inputProvider;
  final DifficultyEngine? difficultyEngine;
  final Function(int)? onGridSizeChanged;
  final GlobalKey? spatialSurfaceKey;
  final ValueNotifier<InputMode>? inputMode;
  final List<InputModeLogEntry> inputModeLog;
  final bool spatialAvailable;
  final VisionIsolateController? visionController;
  final MqttService? mqttService;
  final String participantId;
  final String blockOrder;
  final GameTelemetry telemetry;
  final bool Function() cameraActive;

  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen> with TickerProviderStateMixin {
  final GlobalKey _boardAreaKey = GlobalKey();
  final GlobalKey _restartActionKey = GlobalKey();
  final GlobalKey _nextActionKey = GlobalKey();
  final GlobalKey _startAdventureActionKey = GlobalKey();
  final generator = BoardGenerator();
  late final DifficultyEngine difficulty;
  late final InputProvider input;
  final localInput = LocalInputProvider();
  final tileSound = TileSound();
  late final telemetry = widget.telemetry;
  late final ValueNotifier<InputMode> _modeController;
  bool _ownsModeController = false;
  InputMode get mode => _modeController.value;

  int? invalidTile;
  Timer? invalidTimer;
  DateTime _now() => widget.now?.call() ?? DateTime.now();
  int? pressed;
  bool soundEnabled = true;
  bool _isExportingMqttCsv = false;
  late GameSession session;
  Board get board => session.board;
  List<int> get path => session.path;
  int get errors => session.errors;
  int get stars => session.stars;
  late StreamSubscription<GameInputEvent> subscription;
  StreamSubscription<GameInputEvent>? localSubscription;
  StreamSubscription<MqttButtonEvent>? mqttButtonSubscription;
  late int boardLevel;
  late final List<int> _openingMultiples;
  int _openingIndex = 0;
  late AnimationController gradientFlow;
  int? hovered;
  int? hoveredAction;
  final Set<int> _visitedLevels = {};
  final Map<int, int> _bestStarsByLevel = {};
  bool _levelIntroOpen = false;
  bool _introPlayHovered = false;
  bool debug = false;
  bool recordingVisionTrace = false;
  String message = '';
  late DateTime started, lastInteraction;
  Timer? ticker;
  int elapsed = 0;
  int? _lastTouchPointerDispatchUs;

  @override
  void initState() {
    super.initState();
    difficulty = widget.difficultyEngine ?? DifficultyEngine();
    _openingMultiples = DifficultyEngine.openingMultiplesFor(widget.blockOrder);
    _applyOpeningLevel();
    input =widget.inputProvider ?? localInput;
    mqttButtonSubscription = widget.mqttService?.buttonEvents.listen(
      _handleMqttButtonEvent,
    );
    widget.visionController?.telemetryStream.addListener(_recordVisionTelemetry);
    if (widget.inputMode != null) {
      _modeController = widget.inputMode!;
    } else {
      _ownsModeController = true;
      _modeController = ValueNotifier(
        widget.spatialAvailable ? InputMode.spatial : InputMode.touch,
      );
    }
    _modeController.addListener(_onGameModeChanged);
    _onGameModeChanged();
    _initBoard(difficulty.size, difficulty.divisor);
    _showLevelIntro();

    gradientFlow = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 5),
    )..repeat();
    SchedulerBinding.instance.addTimingsCallback(telemetry.recordFrames);

    subscription = input.events.listen(_handleInput);
    if (input != localInput) {
      localSubscription = localInput.events.listen(_handleInput);
    }

    ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || stars > 0) return;
      final now = _now();
      setState(() {
        elapsed = now.difference(started).inSeconds;
      });
    });
  }

  /// Sets the level for the next scripted opening puzzle, if any remain.
  void _applyOpeningLevel() {
    if (_openingIndex >= _openingMultiples.length) return;
    difficulty.level =
        DifficultyEngine.levelForMultiple(_openingMultiples[_openingIndex]);
    _openingIndex++;
  }

  void _initBoard(int size, int divisor) {
    session = GameSession(generator.generate(size: size, divisor: divisor));
    boardLevel = difficulty.level;
    telemetry.setLevel('multiples_of_${board.divisor}');
    _visitedLevels.add(boardLevel);
    message = input is SpatialInputProvider
        ? 'Move the dot over a neighboring multiple of ${board.divisor}, then pinch to select.'
        : 'START is selected. Tap a multiple of ${board.divisor} directly above, below, left, or right.';
    started = lastInteraction = _now();
    widget.onGridSizeChanged?.call(board.size);
  }

  void _onGameModeChanged() {
    telemetry.setMode(mode == InputMode.spatial ? 'gesture' : 'touch');
  }

  List<int> _validNextTargets() {
    final current = path.last;
    final previous = path.length > 1 ? path[path.length - 2] : null;
    return board.neighbors(current).where((index) {
      if (!board.legal(index)) return false;
      return !path.contains(index) || index == previous;
    }).toList()..sort();
  }

  void _beginSelectionPrompt() {
    telemetry.beginPrompt(jsonEncode(_validNextTargets()));
  }

  void _handleInput(GameInputEvent event) {
    if (!mounted) return;
    if (_levelIntroOpen) {
      if (event.kind == InputKind.hover) {
        final isHoveringStart = event.index == _spatialStart;
        if (_introPlayHovered != isHoveringStart) {
          setState(() => _introPlayHovered = isHoveringStart);
        }
      } else if (event.isSpatial &&
          mode == InputMode.spatial &&
          event.index == _spatialStart) {
        _dismissLevelIntro();
      }
      return;
    }
    if (event.isSpatial && mode != InputMode.spatial) return;
    if (event.kind == InputKind.select &&
        event.isSpatial != (mode == InputMode.spatial)) {
      return;
    }
    telemetry.inputEvents++;
    final inputLatencyMs = event.inputLatencyMs;
    telemetry.lastInputLatencyMs = inputLatencyMs;

    if (event.kind == InputKind.hover) {
      telemetry.hoverFrames++;
      if (mode != InputMode.spatial) return;
      widget.mqttService?.sendEvent(
        'hover',
        extra: {
          'grid': '${board.size}x${board.size}',
          'block': event.index,
        },
      );
      if (event.index == _spatialRestart ||
          event.index == _spatialNext) {
        if (hoveredAction != event.index) {
          setState(() {
            hoveredAction = event.index;
            hovered = null;
          });
        }
        return;
      }
      final hadHoveredAction = hoveredAction != null;
      final next = event.index >= 0 && event.index < board.cells.length
          ? event.index
          : null;
      if (hovered != next || hadHoveredAction) {
        setState(() {
          hoveredAction = null;
          hovered = next;
        });
      }
      return;
    }

    if (event.index == _spatialRestart) {
      _restartCurrentBoard();
      return;
    }
    if (event.index == _spatialNext) {
      if (stars > 0) _newBoard();
      return;
    }
    if (stars > 0) return;

    if (event.index < 0 || event.index >= board.cells.length) return;
    telemetry.selectionEvents++;
    setState(() {
      final previousLevel = difficulty.level;
      final promptedTargets = jsonEncode(_validNextTargets());
      final result = session.select(event.index);
      final accepted = result == GameMoveResult.selected ||
          result == GameMoveResult.completed;
      final outcome = result == GameMoveResult.backtracked
          ? 'backtracked'
          : accepted
          ? 'hit'
          : result == GameMoveResult.notAdjacent ||
                result == GameMoveResult.illegalValue ||
                result == GameMoveResult.alreadyVisited
          ? 'wrong_target'
          : 'ignored';
      telemetry.recordSelection(
        targetSelected: event.index,
        correct: accepted,
        outcome: outcome,
        triggerType: event.isSpatial ? 'pinch' : 'touch',
        inputLatencyMs: inputLatencyMs,
        handDetected: event.isSpatial ? true : null,
        pinching: event.isSpatial ? true : null,
        pointerDispatchUs: event.pointerDispatchUs,
        details: 'prompted_targets=$promptedTargets;result=${result.name}',
        cameraActive: widget.cameraActive(),
      );
      widget.mqttService?.sendEvent(
        'select',
        extra: {
          'grid': '${board.size}x${board.size}',
          'tier': boardLevel,
          'block': [event.index ~/ board.size, event.index % board.size],
          'accepted': result == GameMoveResult.selected ||
              result == GameMoveResult.completed ||
              result == GameMoveResult.backtracked,
          'result': result.name,
        },
      );
      if (result == GameMoveResult.backtracked) {
        _resetInteractionFeedback();
        _beginSelectionPrompt();
        if (soundEnabled) tileSound.play();
        message = 'Moved back one block.';
        return;
      }
      if (result == GameMoveResult.notAdjacent ||
          result == GameMoveResult.illegalValue ||
          result == GameMoveResult.alreadyVisited) {
        message = result == GameMoveResult.notAdjacent
            ? 'Invalid move! Choose a tile directly above, below, left, or right.'
            : result == GameMoveResult.illegalValue
            ? 'Invalid move! ${board.cells[event.index].value} is not a multiple of ${board.divisor}.'
            : 'Invalid move! This tile is already visited. Tap the previous tile to backtrack.';
        invalidTile = event.index;
        invalidTimer?.cancel();
        invalidTimer = Timer(const Duration(milliseconds: 650), () {
          if (mounted) setState(() => invalidTile = null);
        });
        if (soundEnabled) tileSound.play(invalid: true);
        return;
      }
      _resetInteractionFeedback();
      if (result != GameMoveResult.selected &&
          result != GameMoveResult.completed) {
        return;
      }
      message = 'Good move!';
      if (result != GameMoveResult.completed) _beginSelectionPrompt();
      if (soundEnabled) tileSound.play(celebration: event.index == board.goal);
      if (result == GameMoveResult.completed) {
        widget.mqttService?.sendEvent(
          'win',
          extra: {
            'grid': '${board.size}x${board.size}',
            'tier': boardLevel,
            'stars': stars,
            'moves': path.length - 1,
            'errors': errors,
          },
        );
        elapsed = _now().difference(started).inSeconds;
        final optimal = board.shortestDistance() ?? path.length - 1;
        if (input is SpatialInputProvider) {
          final provider = input as SpatialInputProvider;
          provider
            ..modalActionsOnly = true
            ..actionRects.clear();
        }
        difficulty.record(
          errors: errors,
          moves: path.length - 1,
          optimal: optimal,
          seconds: elapsed.toDouble(),
          hintsUsed: 0,
        );
        _bestStarsByLevel[boardLevel] = max(
          _bestStarsByLevel[boardLevel] ?? 0,
          stars,
        );
        final adjustment = difficulty.level > previousLevel
            ? ' Next puzzle will be harder.'
            : difficulty.level < previousLevel
            ? ' Next puzzle will be easier.'
            : '';
        message =
            'Puzzle solved! $stars star${stars == 1 ? '' : 's'} earned.$adjustment';
      }
    });
  }

  void _resetInteractionFeedback() {
    lastInteraction = _now();
    invalidTimer?.cancel();
    invalidTile = null;
  }

  /// [manual] is true when the player picked a level from the menu; that
  /// choice is respected and does not use up a scripted opening puzzle.
  void _newBoard({bool manual = false}) {
    if (!manual) _applyOpeningLevel();
    widget.mqttService?.sendEvent(
      'new_board',
      extra: {'grid': '${difficulty.size}x${difficulty.size}', 'tier': difficulty.level},
    );
    setState(() {
      _initBoard(difficulty.size, difficulty.divisor);
      _showLevelIntro();
      elapsed = 0;
      hovered = hoveredAction = null;
      if (input is SpatialInputProvider) {
        final provider = input as SpatialInputProvider;
        provider
          ..modalActionsOnly = false
          ..actionRects.clear();
      }
      _resetInteractionFeedback();
    });
  }

  void _showLevelIntro() {
    _levelIntroOpen = true;
  }

  void _dismissLevelIntro() {
    if (!_levelIntroOpen) return;
    setState(() {
      _levelIntroOpen = false;
      _introPlayHovered = false;
      _beginSelectionPrompt();
    });
  }

  Future<void> _showLevelMenu() async {
    final selectedLevel = await showDialog<int>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xff29372d),
        title: const Text(
          'Your levels',
          style: TextStyle(color: Color(0xfff4e9d0)),
        ),
        content: SizedBox(
          width: 380,
          child: SingleChildScrollView(
            child: Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final level in (_visitedLevels.toList()..sort()))
                  ChoiceChip(
                    label: Text(
                      'Multiples of ${level + 1}  ${'★' * (_bestStarsByLevel[level] ?? 0)}',
                    ),
                    selected: level == boardLevel,
                    onSelected: (_) => Navigator.of(dialogContext).pop(level),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
    if (!mounted || selectedLevel == null || selectedLevel == boardLevel) {
      return;
    }
    setState(() => difficulty.level = selectedLevel);
    _newBoard(manual: true);
  }

  void _restartCurrentBoard() {
    widget.mqttService?.sendEvent(
      'restart',
      extra: {'grid': '${board.size}x${board.size}', 'tier': boardLevel},
    );
    setState(() {
      session.reset();
      elapsed = 0;
      hovered = hoveredAction = null;
      if (input is SpatialInputProvider) {
        final provider = input as SpatialInputProvider;
        provider
          ..modalActionsOnly = false
          ..actionRects.clear();
      }
      _resetInteractionFeedback();
      started = lastInteraction = _now();
      message = 'Try again!';
      _beginSelectionPrompt();
    });
  }

  void _handleMqttButton(String button) {
    if (!mounted) return;
    switch (button) {
      case 'hint':
        return;
      case 'restart':
        _restartCurrentBoard();
        return;
      case 'next':
        if (stars > 0) _newBoard();
        return;
    }
  }

  void _handleMqttButtonEvent(MqttButtonEvent event) {
    if (!mounted) return;
    _handleMqttButton(event.button);
    final handledAtUs = widget.mqttService?.monotonicMicroseconds;
    if (handledAtUs != null) {
      telemetry.recordButton(
        button: event.button,
        receivedAtUs: event.receivedAtUs,
        handledAtUs: handledAtUs,
      );
    }
  }

  void _recordVisionTelemetry() {
    final sample = widget.visionController?.telemetryStream.value;
    if (sample == null) return;
    // No vision rows outside an active spatial block (e.g. a late isolate
    // result arriving after the camera was stopped for a touch block).
    if (widget.inputMode?.value != InputMode.spatial || !widget.cameraActive()) {
      return;
    }
    final captureToCallbackMs = DateTime.now()
        .difference(sample.capturedAt)
        .inMicroseconds / 1000;
    telemetry.recordVision(sample, captureToCallbackMs);
  }

  Future<void> _saveMqttCsv() async {
    final mqtt = widget.mqttService;
    if (mqtt == null || _isExportingMqttCsv) return;

    setState(() => _isExportingMqttCsv = true);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text('Waiting 2 seconds for late echoes, then exporting…'),
          duration: Duration(seconds: 3),
        ),
      );

    try {
      // The label is fixed ('study'), so participant and mode go in the file
      // name to keep one block's export from overwriting another's.
      final fileTag = '_${widget.participantId}_${telemetry.mode}'
          .replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
      final mqttPath = await _exportMqttLog(mqtt, fileTag: fileTag);
      if (!mounted) return;
      final directory = mqttPath.substring(0, mqttPath.lastIndexOf('/'));
      final deviceFile = await telemetry.saveDeviceLog(
        '$directory/device_metrics_$_studyRunLabel$fileTag.csv',
        runLabel: _studyRunLabel,
        vision: widget.visionController?.metrics ?? VisionMetrics(),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text('CSVs saved: $mqttPath and ${deviceFile.path}'),
            duration: const Duration(seconds: 8),
          ),
        );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('CSV export failed: $error')));
    } finally {
      if (mounted) setState(() => _isExportingMqttCsv = false);
    }
  }

  Rect _rectForKey(GlobalKey key, RenderBox surface) {
    final object = key.currentContext?.findRenderObject();
    if (object is! RenderBox || !object.hasSize) return Rect.zero;
    final topLeft = surface.globalToLocal(object.localToGlobal(Offset.zero));
    return topLeft & object.size;
  }

  void _selectTile(int index, {int? pointerDispatchUs}) {
    if (stars > 0) return;
    localInput.emit(GameInputEvent(
      index,
      InputKind.select,
      pointerDispatchUs: pointerDispatchUs,
    ));
  }

  @override
  void dispose() {
    ticker?.cancel();
    invalidTimer?.cancel();
    SchedulerBinding.instance.removeTimingsCallback(telemetry.recordFrames);
    subscription.cancel();
    localSubscription?.cancel();
    mqttButtonSubscription?.cancel();
    widget.visionController?.telemetryStream.removeListener(_recordVisionTelemetry);
    _modeController.removeListener(_onGameModeChanged);
    localInput.dispose();
    tileSound.dispose();
    gradientFlow.dispose();
    if (_ownsModeController) _modeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final boardObject = _boardAreaKey.currentContext?.findRenderObject();
      final surfaceObject = widget.spatialSurfaceKey?.currentContext
          ?.findRenderObject();
      if (input is SpatialInputProvider &&
          boardObject is RenderBox &&
          surfaceObject is RenderBox) {
        final boardOrigin = boardObject.localToGlobal(Offset.zero);
        final surfaceOrigin = surfaceObject.localToGlobal(Offset.zero);
        (input as SpatialInputProvider).gridRect = Rect.fromLTWH(
          boardOrigin.dx - surfaceOrigin.dx,
          boardOrigin.dy - surfaceOrigin.dy,
          boardObject.size.width,
          boardObject.size.height,
        );
        final provider = input as SpatialInputProvider;
        provider.modalActionsOnly = stars > 0 || _levelIntroOpen;
        final actionRects = <int, Rect>{};
        final actionKeys = <int, GlobalKey>{
          _spatialRestart: _restartActionKey,
          _spatialNext: _nextActionKey,
        };
        if (_levelIntroOpen) {
          actionKeys[_spatialStart] = _startAdventureActionKey;
        }
        for (final entry in actionKeys.entries) {
          final rect = _rectForKey(entry.value, surfaceObject);
          if (rect != Rect.zero) actionRects[entry.key] = rect;
        }
        provider.actionRects
          ..clear()
          ..addAll(actionRects);
      }
    });
    return Scaffold(
      backgroundColor: const Color(0xff172019),
      appBar: AppBar(
        title: const Text('Aether Grid'),
        backgroundColor: const Color(0xff202b21),
        actions: [
          IconButton(
            tooltip: 'Save MQTT CSV',
            onPressed: widget.mqttService == null || _isExportingMqttCsv
                ? null
                : _saveMqttCsv,
            icon: _isExportingMqttCsv
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.download_rounded),
          ),
          IconButton(
            tooltip: soundEnabled ? 'Mute tile sounds' : 'Enable tile sounds',
            onPressed: () => setState(() => soundEnabled = !soundEnabled),
            icon: Icon(
              soundEnabled
                  ? Icons.volume_up_outlined
                  : Icons.volume_off_outlined,
            ),
          ),
          IconButton(
            tooltip: 'Developer telemetry',
            onPressed: () => setState(() => debug = !debug),
            icon: const Icon(Icons.bug_report_outlined),
          ),
          IconButton(
            tooltip: 'Levels you have reached',
            onPressed: _showLevelMenu,
            icon: const Icon(Icons.menu_book_rounded),
          ),
        ],
      ),
      body: Stack(
        children: [
          const Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Color(0xff26372c),
                    Color(0xff18231c),
                    Color(0xff302b22),
                  ],
                ),
              ),
            ),
          ),
          LayoutBuilder(
            builder: (context, viewport) {
              final width = viewport.maxWidth;
              final boardMax = min(min(width - 24, 760), viewport.maxHeight * .76);
              final actionButtonWidth = min(116.0, (width - 48) / 3);
              return SafeArea(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1100),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                        if (debug && widget.visionController != null)
                          _buildVisionDiagnostics(widget.visionController!),
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: const Color(0xff29372d)
                                .withValues(alpha: 0.88),
                            borderRadius: BorderRadius.circular(24),
                            border: Border.all(
                              color: const Color(0xffc6c99e)
                                  .withValues(alpha: 0.16),
                            ),
                          ),
                          child: Wrap(
                            alignment: WrapAlignment.spaceBetween,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            spacing: 12,
                            runSpacing: 8,
                            children: [
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  ForestBuddy(size: 42, happy: stars > 0),
                                  const SizedBox(width: 8),
                                  Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Let’s find a path!',
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleLarge
                                            ?.copyWith(
                                              color: const Color(0xfff4e9d0),
                                              fontWeight: FontWeight.w800,
                                            ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                              Chip(
                                avatar: Icon(
                                  mode == InputMode.spatial
                                      ? Icons.pan_tool_alt
                                      : Icons.touch_app,
                                  size: 17,
                                ),
                                label: Text(
                                  'Block mode locked: ${mode == InputMode.spatial ? 'Gesture' : 'Touch'}',
                                ),
                                backgroundColor: const Color(0xff40513e),
                                labelStyle: const TextStyle(color: Color(0xfff0e8d3)),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 8),
                        if (message.startsWith('Hint '))
                          Semantics(
                            liveRegion: true,
                            child: Container(
                              constraints: const BoxConstraints(maxHeight: 68),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xff3a3524)
                                    .withValues(alpha: 0.96),
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(
                                  color: const Color(0xffe2c887)
                                      .withValues(alpha: 0.35),
                                ),
                              ),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Icon(
                                    Icons.lightbulb_rounded,
                                    color: Color(0xffe2c887),
                                    size: 22,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      message,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 14,
                                        height: 1.25,
                                        fontWeight: FontWeight.w600,
                                        color: Color(0xfff4e9d0),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          )
                        else
                          Container(
                            width: double.infinity,
                            constraints: const BoxConstraints(maxHeight: 68),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xff29372d)
                                  .withValues(alpha: 0.9),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: const Color(0xffd7d2b7)
                                    .withValues(alpha: 0.12),
                              ),
                            ),
                            child: Row(
                              children: [
                                ForestBuddy(size: 30, happy: stars > 0),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    message,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: message.startsWith('Invalid')
                                          ? const Color(0xffed9b83)
                                          : const Color(0xfff0e7d2),
                                      height: 1.35,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        const SizedBox(height: 6),

                        // MATH GRID
                        Expanded(
                          child: Center(
                            child: ConstrainedBox(
                              constraints: BoxConstraints(
                                maxWidth: boardMax.toDouble(),
                              ),
                              child: AspectRatio(
                              key: _boardAreaKey,
                              aspectRatio: 1,
                              child: GridView.builder(
                                physics: const NeverScrollableScrollPhysics(),
                                gridDelegate:
                                    SliverGridDelegateWithFixedCrossAxisCount(
                                      crossAxisCount: board.size,
                                      crossAxisSpacing: 8,
                                      mainAxisSpacing: 8,
                                    ),
                                itemCount: board.cells.length,
                                itemBuilder: (context, i) {
                                  final cell = board.cells[i];
                                  final selected = path.contains(i);
                                  final color = invalidTile == i
                                      ? const Color(0xffd57e67)
                                            .withValues(alpha: 0.8)
                                      : selected
                                      ? const Color(0xff668b68)
                                            .withValues(alpha: 0.8)
                                      : hovered == i
                                      ? const Color(0xffb6c99c)
                                            .withValues(alpha: 0.6)
                                      : const Color(0xff2b382e)
                                            .withValues(alpha: 0.94);
                                  return MouseRegion(
                                    onHover: (_) {
                                      if (mode == InputMode.spatial) {
                                        localInput.emit(
                                          GameInputEvent(i, InputKind.hover),
                                        );
                                      }
                                    },
                                    onExit: (_) {
                                      if (mode == InputMode.spatial) {
                                        localInput.emit(
                                          const GameInputEvent(
                                            -1,
                                            InputKind.hover,
                                          ),
                                        );
                                      }
                                    },
                                    onEnter: (_) {
                                      if (mode == InputMode.spatial) {
                                        localInput.emit(
                                          GameInputEvent(i, InputKind.hover),
                                        );
                                      }
                                    },
                                    child: Listener(
                                      onPointerDown: (_) {
                                        _lastTouchPointerDispatchUs = null;
                                      },
                                      onPointerUp: (event) {
                                        _lastTouchPointerDispatchUs = telemetry.nowUs;
                                      },
                                      child: GestureDetector(
                                        behavior: HitTestBehavior.opaque,
                                        onTapDown: (_) {
                                          if (stars == 0) {
                                            setState(() => pressed = i);
                                          }
                                        },
                                        onTapUp: (_) =>
                                            setState(() => pressed = null),
                                        onTapCancel: () =>
                                            setState(() => pressed = null),
                                        onTap: () => _selectTile(
                                          i,
                                          pointerDispatchUs:
                                              _lastTouchPointerDispatchUs,
                                        ),
                                        child: Semantics(
                                        key: ValueKey('tile-$i'),
                                        button: true,
                                        selected: selected,
                                        label:
                                            '${cell.start
                                                ? 'Start'
                                                : cell.finish
                                                ? 'Finish'
                                                : 'Number'} ${cell.value}',
                                        child: AnimatedContainer(
                                          duration: const Duration(
                                            milliseconds: 220,
                                          ),
                                          curve: Curves.easeOutCubic,
                                          transformAlignment: Alignment.center,
                                          transform: Matrix4.diagonal3Values(
                                            pressed == i ? .93 : 1,
                                            pressed == i ? .93 : 1,
                                            1,
                                          ),
                                          decoration: BoxDecoration(
                                            color: color,
                                            border: Border.all(
                                              color: hovered == i
                                                  ? const Color(0xffd1dba7)
                                                  : Colors.white.withValues(
                                                      alpha: 0.12,
                                                    ),
                                              width: hovered == i ? 2.5 : 1.0,
                                            ),
                                            boxShadow: [
                                              BoxShadow(
                                                color: color.withValues(
                                                  alpha: pressed == i
                                                      ? .5
                                                      : .24,
                                                ),
                                                blurRadius: pressed == i
                                                    ? 3
                                                    : 7,
                                                offset: Offset(
                                                  0,
                                                  pressed == i ? 1 : 4,
                                                ),
                                              ),
                                            ],
                                            shape: BoxShape.circle,
                                          ),
                                          child: FlowingGradient(
                                            animation: gradientFlow,
                                            color: color,
                                            selected:
                                                selected && invalidTile != i,
                                            index: i,
                                            gridSize: board.size,
                                            child: FittedBox(
                                              fit: BoxFit.scaleDown,
                                              child: Column(
                                                mainAxisSize: MainAxisSize.min,
                                                mainAxisAlignment:
                                                    MainAxisAlignment.center,
                                                children: [
                                                  if (cell.start || cell.finish)
                                                    Text(
                                                      cell.start
                                                          ? 'START'
                                                          : 'FINISH',
                                                      style: TextStyle(
                                                        fontSize:
                                                            board.size == 6
                                                            ? 9
                                                            : 11,
                                                        fontWeight:
                                                            FontWeight.bold,
                                                        color: selected
                                                            ? Colors.white
                                                            : null,
                                                      ),
                                                    ),
                                                  FittedBox(
                                                    child: Padding(
                                                      padding:
                                                          const EdgeInsets.symmetric(
                                                            horizontal: 3,
                                                          ),
                                                      child: Text(
                                                        '${cell.value}',
                                                        style: TextStyle(
                                                          fontSize:
                                                              board.size == 6
                                                              ? 19
                                                              : 24,
                                                          fontWeight:
                                                              FontWeight.bold,
                                                          color: selected
                                                              ? Colors.white
                                                              : Colors.white70,
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ),
                                        ),
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 6),
                        if (stars == 0)
                          Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          alignment: WrapAlignment.center,
                          children: [
                            CircularControl(
                              onPressed: _newBoard,
                              icon: Icons.refresh,
                              label: stars > 0 ? 'Next puzzle' : 'New puzzle',
                              buttonWidth: actionButtonWidth,
                            ),
                            CircularControl(
                              key: _restartActionKey,
                              active: hoveredAction == _spatialRestart,
                              onPressed: _restartCurrentBoard,
                              icon: Icons.replay,
                              label: 'Restart',
                              buttonWidth: actionButtonWidth,
                            ),
                          ],
                        ),
                      ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
          if (_levelIntroOpen)
            Positioned.fill(
              child: Stack(
                children: [
                  const ModalBarrier(
                    dismissible: false,
                    color: Color(0xcc101710),
                  ),
                  Center(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(20),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 420),
                        child: Card(
                          color: const Color(0xff29372d),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(28),
                            side: BorderSide(
                              color: const Color(0xffe2c887).withValues(alpha: .6),
                            ),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const ForestBuddy(size: 76, happy: false),
                                const SizedBox(height: 8),
                                const Text(
                                  'Apple is lost!',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: Color(0xfff4e9d0),
                                    fontSize: 26,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  'Help Apple find the way home. Start at START, follow adjacent tiles that are multiples of ${board.divisor}, and reach FINISH.',
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    color: Color(0xffd2d4b7),
                                    fontSize: 15,
                                    height: 1.45,
                                  ),
                                ),
                                const SizedBox(height: 10),
                                Text(
                                  'Your task: multiples of ${board.divisor}',
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    color: Color(0xffb2c39c),
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                if (mode == InputMode.spatial) ...[
                                  const SizedBox(height: 8),
                                  const Text(
                                    'Point at Start adventure and pinch to begin.',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: Color(0xffd2d4b7),
                                      fontSize: 13,
                                    ),
                                  ),
                                ],
                                const SizedBox(height: 18),
                                FilledButton.icon(
                                  key: _startAdventureActionKey,
                                  style: FilledButton.styleFrom(
                                    backgroundColor: _introPlayHovered
                                        ? const Color(0xff91a77e)
                                        : const Color(0xff718b63),
                                    foregroundColor: const Color(0xfffff5df),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 24,
                                      vertical: 12,
                                    ),
                                  ),
                                  onPressed: _dismissLevelIntro,
                                  icon: const Icon(Icons.play_arrow_rounded),
                                  label: const Text('Start adventure'),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          if (stars > 0)
            Positioned.fill(
              child: Stack(
                children: [
                  const ModalBarrier(
                    dismissible: false,
                    color: Color(0xcc101710),
                  ),
                  Center(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(20),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 440),
                        child: Card(
                          color: const Color(0xff29372d),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(28),
                            side: BorderSide(
                              color: const Color(0xffe2c887).withValues(alpha: .55),
                            ),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const ForestBuddy(size: 68, happy: true),
                                const SizedBox(height: 8),
                                const Text(
                                  'Apple found the way home!',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: Color(0xfff4e9d0),
                                    fontSize: 24,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                const SizedBox(height: 14),
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: List.generate(
                                    3,
                                    (index) => Icon(
                                      Icons.star_rounded,
                                      size: 46,
                                      color: index < stars
                                          ? const Color(0xffe2c887)
                                          : const Color(0xff687266),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  '$stars ${stars == 1 ? 'star' : 'stars'} earned',
                                  style: const TextStyle(
                                    color: Color(0xffe6ddc8),
                                    fontSize: 16,
                                  ),
                                ),
                                if (message.isNotEmpty) ...[
                                  const SizedBox(height: 8),
                                  Text(
                                    message,
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(
                                      color: Color(0xffc5cfb8),
                                    ),
                                  ),
                                ],
                                const SizedBox(height: 18),
                                Wrap(
                                  alignment: WrapAlignment.center,
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: [
                                    CircularControl(
                                      key: _nextActionKey,
                                      active: hoveredAction == _spatialNext,
                                      onPressed: _newBoard,
                                      icon: Icons.arrow_forward_rounded,
                                      label: 'Next',
                                    ),
                                    CircularControl(
                                      key: _restartActionKey,
                                      active: hoveredAction == _spatialRestart,
                                      onPressed: _restartCurrentBoard,
                                      icon: Icons.replay,
                                      label: 'Restart',
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildVisionDiagnostics(VisionIsolateController vision) {
    final metrics = vision.metrics;
    final inference = metrics.averageInferenceMs?.toStringAsFixed(1) ?? '—';
    final latency = metrics.lastCameraToCursorMs?.toStringAsFixed(1) ?? '—';
    final fps = metrics.averageCameraFps?.toStringAsFixed(1) ?? '—';
    return Card(
      color: const Color(0xff202b21),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Vision diagnostics · ${metrics.frameWidth ?? '—'}×${metrics.frameHeight ?? '—'} ${metrics.imageFormat ?? ''} · ${VisionMetrics.requestedResolution} · target ${VisionMetrics.targetInferenceFps} FPS',
            ),
            const SizedBox(height: 4),
            Text(
              'Inference avg $inference ms · camera→cursor $latency ms · capture $fps FPS',
            ),
            Text(
              'Frames ${metrics.framesReceived} · dropped ${metrics.droppedFrames} (rate limited ${metrics.rateLimitedFrames}) · no hand ${metrics.noHandFrames} · pinches ${metrics.pinchEvents}',
            ),
            Text(
              'Input mode: ${mode.name} · mode transitions: ${widget.inputModeLog.length}',
            ),
            Wrap(
              spacing: 8,
              children: [
                TextButton.icon(
                  onPressed: () => setState(() {
                    recordingVisionTrace = true;
                    vision.startFeatureRecording();
                  }),
                  icon: const Icon(Icons.fiber_manual_record),
                  label: const Text('Record feature trace'),
                ),
                TextButton.icon(
                  onPressed: recordingVisionTrace
                      ? () async {
                          vision.stopFeatureRecording();
                          recordingVisionTrace = false;
                          await Clipboard.setData(
                            ClipboardData(text: vision.exportFeatureRecording()),
                          );
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Feature trace copied as JSON.'),
                              ),
                            );
                            setState(() {});
                          }
                        }
                      : null,
                  icon: const Icon(Icons.stop_circle_outlined),
                  label: Text(
                    recordingVisionTrace
                        ? 'Stop (${vision.featureRecording.length})'
                        : 'Stop recording',
                  ),
                ),
                TextButton.icon(
                  onPressed: () async {
                    final json = jsonEncode(
                      widget.inputModeLog.map((entry) => entry.toJson()).toList(),
                    );
                    await Clipboard.setData(ClipboardData(text: json));
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Mode log copied as JSON.')),
                      );
                    }
                  },
                  icon: const Icon(Icons.history),
                  label: const Text('Copy mode log'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
