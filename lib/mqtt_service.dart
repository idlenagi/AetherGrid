import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

/// Returns a linearly interpolated percentile, or null for an empty sample.
/// [quantile] is in the inclusive range 0..1.
double? calculatePercentile(List<double> samples, double quantile) {
  if (quantile < 0 || quantile > 1 || !quantile.isFinite) {
    throw ArgumentError.value(quantile, 'quantile', 'Must be between 0 and 1');
  }
  if (samples.isEmpty) return null;
  final sorted = List<double>.of(samples)..sort();
  if (sorted.length == 1) return sorted.single;
  final position = (sorted.length - 1) * quantile;
  final lowerIndex = position.floor();
  final upperIndex = position.ceil();
  final fraction = position - lowerIndex;
  return sorted[lowerIndex] +
      (sorted[upperIndex] - sorted[lowerIndex]) * fraction;
}

/// A rate limiter whose clock is supplied by the caller, making timing logic
/// deterministic in unit tests.
class HoverEventRateLimiter {
  HoverEventRateLimiter({required this.minimumIntervalUs});

  final int minimumIntervalUs;
  int? _lastAllowedUs;

  bool shouldAllow(int nowUs) {
    final previous = _lastAllowedUs;
    if (previous != null && nowUs - previous < minimumIntervalUs) return false;
    _lastAllowedUs = nowUs;
    return true;
  }

  void reset() => _lastAllowedUs = null;
}

class PendingMqttEvent {
  const PendingMqttEvent({
    required this.seq,
    required this.tSendUs,
    required this.tPhoneEpochMs,
    required this.runLabel,
    required this.qos,
  });

  final int seq;
  final int tSendUs;
  final int tPhoneEpochMs;
  final String runLabel;
  final int qos;
}

class MqttEchoMatch {
  const MqttEchoMatch(this.event, this.rttUs, this.espProcUs);

  final PendingMqttEvent event;
  final int rttUs;
  final int? espProcUs;
}

/// Pure timing/correlation state shared by the service and its unit tests.
class MqttLatencyTracker {
  MqttLatencyTracker({required this.clockUs, this.pendingTimeoutUs = 10000000});

  final int Function() clockUs;
  final int pendingTimeoutUs;
  final Map<int, PendingMqttEvent> _pending = {};
  int unknownEchoes = 0;
  int noEchoes = 0;

  int get pendingCount => _pending.length;

  void recordSend(PendingMqttEvent event) => _pending[event.seq] = event;

  void forgetUnsent(int seq) => _pending.remove(seq);

  MqttEchoMatch? receiveEcho({
    required int seq,
    required int tPhoneEpochMs,
    required int espProcUs,
    int? receivedAtUs,
  }) {
    final event = _pending[seq];
    if (event == null || event.tPhoneEpochMs != tPhoneEpochMs) {
      unknownEchoes++;
      return null;
    }
    _pending.remove(seq);
    final rtt = (receivedAtUs ?? clockUs()) - event.tSendUs;
    if (rtt < 0) {
      unknownEchoes++;
      return null;
    }
    return MqttEchoMatch(event, rtt, espProcUs);
  }

  List<PendingMqttEvent> pruneExpired({int? atUs}) {
    final now = atUs ?? clockUs();
    final expired = _pending.values
        .where((event) => now - event.tSendUs >= pendingTimeoutUs)
        .toList(growable: false);
    for (final event in expired) {
      _pending.remove(event.seq);
    }
    noEchoes += expired.length;
    return expired;
  }

  List<PendingMqttEvent> drainAsNoEcho() {
    final pending = _pending.values.toList(growable: false);
    _pending.clear();
    noEchoes += pending.length;
    return pending;
  }

  void reset() {
    _pending.clear();
    unknownEchoes = 0;
    noEchoes = 0;
  }
}

class MqttLatencyTestSummary {
  const MqttLatencyTestSummary({
    required this.sent,
    required this.received,
    required this.lost,
    required this.p50,
    required this.p95,
    required this.p99,
    required this.max,
  });

  final int sent;
  final int received;
  final int lost;
  final double? p50;
  final double? p95;
  final double? p99;
  final double? max;
}

class _LatencyTestRun {
  _LatencyTestRun(this.requestedCount);

  final int requestedCount;
  final Completer<MqttLatencyTestSummary> completer = Completer();
  final Set<int> sequences = {};
  final List<double> rttsMs = [];
  int attempted = 0;
  int sent = 0;
  int received = 0;
  Timer? sendTimer;
  Timer? timeoutTimer;
}

/// MQTT transport for event telemetry. Sending events never waits for a
/// response and never throws into the game loop.
class MqttService {
  MqttService({
    required this.host,
    this.port = 1883,
    MqttQos qos = MqttQos.atMostOnce,
    this.brokerTag = 'mosquitto-local',
    this.minHoverIntervalMs = 50,
    int Function()? clockMicroseconds,
  }) : _qos = qos,
       _injectedClockUs = clockMicroseconds,
       _client = MqttServerClient(
         host,
         'smg-tablet-${DateTime.now().millisecondsSinceEpoch}',
       ) {
    _validateQos(qos);
    _client
      ..port = port
      ..keepAlivePeriod = 15
      ..autoReconnect = true
      ..logging(on: false)
      ..connectionMessage = MqttConnectMessage()
          .startClean()
          .withWillTopic(tPhoneStatus)
          .withWillMessage('offline')
          .withWillQos(MqttQos.atLeastOnce)
          .withWillRetain();
    _client.onAutoReconnected = _afterReconnect;
  }

  final String host;
  final int port;
  final String brokerTag;
  final int minHoverIntervalMs;
  final int Function()? _injectedClockUs;
  final MqttServerClient _client;
  final Stopwatch _stopwatch = Stopwatch()..start();
  late final MqttLatencyTracker _tracker = MqttLatencyTracker(
    clockUs: () => _nowUs,
  );
  late final HoverEventRateLimiter _hoverLimiter = HoverEventRateLimiter(
    minimumIntervalUs: minHoverIntervalMs * 1000,
  );

  static const tEvent = 'smg/phone/event';
  static const tStats = 'smg/phone/stats';
  static const tStatsRtt = 'smg/stats/rtt';
  static const tStatsP95 = 'smg/stats/p95';
  static const tPhoneStatus = 'smg/phone/status';
  static const tEcho = 'smg/esp32/echo';
  static const tButton = 'smg/esp32/button';
  static const tEspStatus = 'smg/esp32/status';
  static const tCommand = 'smg/esp32/cmd';

  final List<double> _recentRttMs = [];
  final List<String> _csvRows = [
    'run_label,broker,qos,seq,t_send_us,rtt_us,esp_proc_us',
  ];
  final _buttonCtrl = StreamController<String>.broadcast();
  final _buttonEventCtrl = StreamController<MqttButtonEvent>.broadcast();
  final _espOnlineCtrl = StreamController<bool>.broadcast();
  final _rttCtrl = StreamController<double>.broadcast();

  StreamSubscription<List<MqttReceivedMessage<MqttMessage?>>>?
  _updatesSubscription;
  Future<bool>? _connecting;
  bool _updatesListenerAttached = false;
  Timer? _statsTimer;
  _LatencyTestRun? _latencyTest;
  MqttQos _qos;
  int _seq = 0;
  int _droppedEvents = 0;
  int _rateLimitedHovers = 0;
  String _runLabel = 'unlabeled';
  // Counted per QoS so labels read q0_r1, q0_r2, ... and q1_r1, q1_r2, ...
  final Map<MqttQos, int> _runNumbers = {};
  bool _hasStartedRun = false;
  bool _runConfigurationPending = true;
  bool _disposed = false;

  MqttQos get qos => _qos;
  String get runLabel => _runLabel;
  Stream<String> get buttons => _buttonCtrl.stream;
  Stream<MqttButtonEvent> get buttonEvents => _buttonEventCtrl.stream;
  Stream<bool> get espOnline => _espOnlineCtrl.stream;
  Stream<double> get rttMs => _rttCtrl.stream;
  int get droppedEvents => _droppedEvents;
  int get rateLimitedHovers => _rateLimitedHovers;
  int get unknownEchoes => _tracker.unknownEchoes;
  int get noEchoes => _tracker.noEchoes;
  int get lostEchoes => noEchoes;
  int get monotonicMicroseconds => _nowUs;
  bool get isConnected =>
      !_disposed &&
      _client.connectionStatus?.state == MqttConnectionState.connected;

  int get _nowUs =>
      _injectedClockUs?.call() ?? _stopwatch.elapsedMicroseconds;

  Future<bool> connect() {
    if (_disposed) return Future.value(false);
    if (isConnected) return Future.value(true);
    return _connecting ??= _connect().whenComplete(() => _connecting = null);
  }

  Future<bool> _connect() async {
    try {
      await _client.connect();
      if (!isConnected) return false;
      _attachUpdatesOnce();
      _ensureStatsTimer();
      _subscribeAndPublishOnline();
      if (_hasStartedRun) _publishRunConfiguration();
      return true;
    } catch (_) {
      _client.disconnect();
      return false;
    }
  }

  void _attachUpdatesOnce() {
    if (_updatesListenerAttached) return;
    final updates = _client.updates;
    if (updates == null) return;
    // mqtt_client creates this stream during connect; reconnect callbacks keep
    // the listener and never attach another one.
    _updatesSubscription = updates.listen(_onMessages);
    _updatesListenerAttached = true;
  }

  /// Keep the subscriptions and the ESP32's active run configuration in sync.
  void _afterReconnect() {
    _subscribeAndPublishOnline();
    if (_hasStartedRun) _publishRunConfiguration();
  }

  void _subscribeAndPublishOnline() {
    if (_disposed || !isConnected) return;
    try {
      _client
        ..subscribe(tEcho, MqttQos.atLeastOnce)
        ..subscribe(tButton, MqttQos.atLeastOnce)
        ..subscribe(tEspStatus, MqttQos.atLeastOnce);
      _publish(
        tPhoneStatus,
        'online',
        retain: true,
        qos: MqttQos.atLeastOnce,
      );
    } catch (_) {}
  }

  void _ensureStatsTimer() {
    _statsTimer ??= Timer.periodic(const Duration(seconds: 1), (_) {
      _logLost(_tracker.pruneExpired());
      _publishStats();
    });
  }

  /// Starts a run with sequence zero and a fresh set of run counters.
  /// Existing pending sends are first retained in the CSV as no-echo rows.
  void startRun({String? label}) {
    if (_disposed) return;
    final activeTest = _latencyTest;
    if (activeTest != null) _completeLatencyTest(activeTest);
    final pendingFromPreviousRun = _tracker.drainAsNoEcho();
    _logLost(pendingFromPreviousRun);
    final runNumber = (_runNumbers[_qos] ?? 0) + 1;
    _runNumbers[_qos] = runNumber;
    _runLabel = label ?? 'q${_qos.index}_r$runNumber';
    _hasStartedRun = true;
    _runConfigurationPending = true;
    // The ESP32 must learn the run label and echo QoS before seq 0 is emitted.
    _publishRunConfiguration();
    _tracker.reset();
    _seq = 0;
    _droppedEvents = 0;
    _rateLimitedHovers = 0;
    _recentRttMs.clear();
    _hoverLimiter.reset();
  }

  /// Changes event QoS and tells the ESP32 to use the corresponding echo QoS.
  /// Pass [startNewRun] false when the caller starts its own run right after
  /// (e.g. [runLatencyTest]) so the run counter is not advanced twice.
  void setQos(MqttQos value, {bool startNewRun = true}) {
    _validateQos(value);
    if (_qos == value) return;
    _qos = value;
    // A QoS change starts a separately labeled measurement run at seq 0.
    if (startNewRun) startRun();
  }

  bool _publishRunConfiguration() {
    if (_disposed || !isConnected) {
      _runConfigurationPending = true;
      return false;
    }
    final runSent = _publish(
      tCommand,
      'run:$_runLabel',
      qos: MqttQos.atLeastOnce,
    );
    final qosSent = _publish(
      tCommand,
      _qos == MqttQos.atMostOnce ? 'qos0' : 'qos1',
      qos: MqttQos.atLeastOnce,
    );
    _runConfigurationPending = !(runSent && qosSent);
    return !_runConfigurationPending;
  }

  static void _validateQos(MqttQos value) {
    if (value != MqttQos.atMostOnce && value != MqttQos.atLeastOnce) {
      throw ArgumentError.value(value, 'qos', 'Only QoS 0 and QoS 1 are supported');
    }
  }

  /// Fire-and-forget. Hover events are throttled; discrete events are not.
  void sendEvent(String event, {Map<String, dynamic> extra = const {}}) {
    _sendEvent(event: event, extra: extra);
  }

  int? _sendEvent({
    required String event,
    Map<String, dynamic> extra = const {},
    bool latencyTestEvent = false,
  }) {
    if (_disposed) return null;
    try {
      if (!_hasStartedRun) startRun();
      if (_latencyTest != null && !latencyTestEvent) {
        _droppedEvents++;
        return null;
      }
      final tSendUs = _nowUs;
      if (event == 'hover' && !_hoverLimiter.shouldAllow(tSendUs)) {
        _rateLimitedHovers++;
        return null;
      }
      if (!isConnected) {
        _droppedEvents++;
        return null;
      }
      if (_runConfigurationPending && !_publishRunConfiguration()) {
        _droppedEvents++;
        return null;
      }

      final seq = _seq;
      final tPhone = DateTime.now().millisecondsSinceEpoch;
      // Reserved protocol fields are written last so extras cannot override them.
      final payload = jsonEncode({
        ...extra,
        'seq': seq,
        't_phone': tPhone,
        'event': event,
      });
      final pending = PendingMqttEvent(
        seq: seq,
        tSendUs: tSendUs,
        tPhoneEpochMs: tPhone,
        runLabel: _runLabel,
        qos: _qos == MqttQos.atMostOnce ? 0 : 1,
      );
      _tracker.recordSend(pending);
      if (!_publish(tEvent, payload, qos: _qos)) {
        _tracker.forgetUnsent(seq);
        _droppedEvents++;
        return null;
      }
      _seq++;
      return seq;
    } catch (_) {
      _droppedEvents++;
      return null;
    }
  }

  bool _publish(
    String topic,
    String payload, {
    required MqttQos qos,
    bool retain = false,
  }) {
    if (!isConnected) return false;
    try {
      final builder = MqttClientPayloadBuilder()..addString(payload);
      final bytes = builder.payload;
      if (bytes == null) return false;
      _client.publishMessage(topic, qos, bytes, retain: retain);
      return true;
    } catch (_) {
      return false;
    }
  }

  void _onMessages(List<MqttReceivedMessage<MqttMessage?>> messages) {
    for (final message in messages) {
      try {
        if (message.payload is! MqttPublishMessage) continue;
        final publish = message.payload as MqttPublishMessage;
        final text = MqttPublishPayload.bytesToStringAsString(
          publish.payload.message,
        );
        if (message.topic == tEcho) {
          _handleEcho(text);
        } else if (message.topic == tButton) {
          final receivedAtUs = _nowUs;
          final json = jsonDecode(text);
          if (json is Map<String, dynamic> && json['btn'] is String) {
            final button = json['btn'] as String;
            _buttonCtrl.add(button);
            _buttonEventCtrl.add(MqttButtonEvent(button, receivedAtUs));
          }
        } else if (message.topic == tEspStatus) {
          _espOnlineCtrl.add(text.trim() == 'online');
        }
      } catch (_) {
        // Ignore malformed messages and continue processing the batch.
      }
    }
  }

  void _handleEcho(String text) {
    final dynamic decoded = jsonDecode(text);
    if (decoded is! Map<String, dynamic>) return;
    final seqValue = decoded['seq'];
    final phoneTimeValue = decoded['t_phone'];
    final procValue = decoded['proc_us'];
    if (seqValue is! int || phoneTimeValue is! int || procValue is! int) return;
    final match = _tracker.receiveEcho(
      seq: seqValue,
      tPhoneEpochMs: phoneTimeValue,
      espProcUs: procValue,
      receivedAtUs: _nowUs,
    );
    if (match == null) return;

    final rttMs = match.rttUs / 1000.0;
    _recentRttMs.add(rttMs);
    if (_recentRttMs.length > 200) _recentRttMs.removeAt(0);
    _csvRows.add(_csvRow([
      match.event.runLabel,
      brokerTag,
      '${match.event.qos}',
      '${match.event.seq}',
      '${match.event.tSendUs}',
      '${match.rttUs}',
      '${match.espProcUs ?? ''}',
    ]));
    _rttCtrl.add(rttMs);

    final latencyTest = _latencyTest;
    if (latencyTest != null && latencyTest.sequences.remove(seqValue)) {
      latencyTest.received++;
      latencyTest.rttsMs.add(rttMs);
      _finishLatencyTestIfComplete(latencyTest);
    }
  }

  void _logLost(Iterable<PendingMqttEvent> events) {
    for (final event in events) {
      _csvRows.add(_csvRow([
        event.runLabel,
        brokerTag,
        '${event.qos}',
        '${event.seq}',
        '${event.tSendUs}',
        '',
        '',
      ]));
    }
  }

  void _publishStats() {
    if (!isConnected) return;
    final median = calculatePercentile(_recentRttMs, .5) ?? 0.0;
    final p95 = calculatePercentile(_recentRttMs, .95) ?? 0.0;
    _publish(
      tStats,
      jsonEncode({'rtt': median, 'p95': p95}),
      qos: MqttQos.atMostOnce,
    );
    _publish(tStatsRtt, median.toString(), qos: MqttQos.atMostOnce);
    _publish(tStatsP95, p95.toString(), qos: MqttQos.atMostOnce);
  }

  /// Sends [count] pings at [rateHz], then returns their echo latency summary.
  /// Pings use sequence zero onward in a dedicated run label.
  Future<MqttLatencyTestSummary> runLatencyTest({
    required int count,
    required int rateHz,
    String? label,
  }) {
    if (count <= 0) throw ArgumentError.value(count, 'count', 'Must be positive');
    if (rateHz <= 0) throw ArgumentError.value(rateHz, 'rateHz', 'Must be positive');
    if (_disposed) throw StateError('MqttService has been disposed');
    if (_latencyTest != null) throw StateError('A latency test is already running');

    startRun(label: label);
    final run = _LatencyTestRun(count);
    _latencyTest = run;
    final intervalUs = math.max(1, 1000000 ~/ rateHz).toInt();
    final timeoutSeconds = math
        .max(10, (count / rateHz).ceil() + 10)
        .toInt();
    run.timeoutTimer = Timer(Duration(seconds: timeoutSeconds), () {
      _completeLatencyTest(run);
    });

    void emitPing() {
      if (run.completer.isCompleted) return;
      final seq = _sendEvent(event: 'ping', latencyTestEvent: true);
      run.attempted++;
      if (seq != null) {
        run.sent++;
        run.sequences.add(seq);
      }
      if (run.attempted >= count) {
        run.sendTimer?.cancel();
      }
      _finishLatencyTestIfComplete(run);
    }

    emitPing();
    if (count > 1 && !run.completer.isCompleted) {
      run.sendTimer = Timer.periodic(
        Duration(microseconds: intervalUs),
        (_) => emitPing(),
      );
    }
    return run.completer.future;
  }

  void _finishLatencyTestIfComplete(_LatencyTestRun run) {
    if (identical(_latencyTest, run) &&
        run.attempted == run.requestedCount &&
        run.received == run.sent) {
      _completeLatencyTest(run);
    }
  }

  void _completeLatencyTest(_LatencyTestRun run) {
    if (run.completer.isCompleted) return;
    run.sendTimer?.cancel();
    run.timeoutTimer?.cancel();
    final sorted = List<double>.of(run.rttsMs)..sort();
    final maxRtt = sorted.isEmpty ? null : sorted.last;
    run.completer.complete(
      MqttLatencyTestSummary(
        sent: run.sent,
        received: run.received,
        lost: run.sent - run.received,
        p50: calculatePercentile(sorted, .5),
        p95: calculatePercentile(sorted, .95),
        p99: calculatePercentile(sorted, .99),
        max: maxRtt,
      ),
    );
    if (identical(_latencyTest, run)) _latencyTest = null;
  }

  Future<File> saveLog(String path, {String? runLabel}) {
    _logLost(_tracker.drainAsNoEcho());
    final rows = runLabel == null
        ? _csvRows
        : _csvRows.where((row) => row.startsWith('$runLabel,') ||
            row == _csvRows.first);
    return File(path).writeAsString(rows.join('\n'));
  }

  static String _csvRow(List<String> fields) => fields.map((field) {
    if (field.contains(',') || field.contains('"') || field.contains('\n')) {
      return '"${field.replaceAll('"', '""')}"';
    }
    return field;
  }).join(',');

  Future<void> dispose() async {
    if (_disposed) return;
    _statsTimer?.cancel();
    final latencyTest = _latencyTest;
    if (latencyTest != null) _completeLatencyTest(latencyTest);
    await _updatesSubscription?.cancel();
    try {
      if (_client.connectionStatus?.state == MqttConnectionState.connected) {
        _publish(
          tPhoneStatus,
          'offline',
          retain: true,
          qos: MqttQos.atLeastOnce,
        );
        _client.disconnect();
      }
    } catch (_) {
      // Still close streams if the transport has already failed.
    }
    _disposed = true;
    await _buttonCtrl.close();
    await _buttonEventCtrl.close();
    await _espOnlineCtrl.close();
    await _rttCtrl.close();
  }
}

class MqttButtonEvent {
  const MqttButtonEvent(this.button, this.receivedAtUs);
  final String button;
  /// Receive timestamp from the same monotonic clock used by [MqttService].
  final int receivedAtUs;
}
