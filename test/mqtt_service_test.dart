import 'package:flutter_test/flutter_test.dart';
import 'package:aether_grid/mqtt_service.dart';

void main() {
  group('calculatePercentile', () {
    test('returns null for an empty window', () {
      expect(calculatePercentile(const <double>[], .5), isNull);
    });

    test('returns the only sample for a one-sample window', () {
      expect(calculatePercentile([12.5], .5), 12.5);
    });

    test('interpolates the median and upper percentile', () {
      expect(calculatePercentile([40.0, 10.0, 30.0, 20.0], .5), 25);
      expect(calculatePercentile([10.0, 20.0, 30.0, 40.0], .95), 38.5);
    });
  });

  group('MqttLatencyTracker', () {
    test('matches by sequence and counts duplicate and late echoes', () {
      var nowUs = 100;
      final tracker = MqttLatencyTracker(
        clockUs: () => nowUs,
        pendingTimeoutUs: 100,
      );
      tracker.recordSend(
        const PendingMqttEvent(
          seq: 4,
          tSendUs: 100,
          tPhoneEpochMs: 1000,
          runLabel: 'trial',
          qos: 0,
        ),
      );

      nowUs = 135;
      final match = tracker.receiveEcho(
        seq: 4,
        tPhoneEpochMs: 1000,
        espProcUs: 7,
      );
      expect(match?.event.seq, 4);
      expect(match?.rttUs, 35);
      expect(match?.espProcUs, 7);

      nowUs = 140;
      expect(
        tracker.receiveEcho(seq: 4, tPhoneEpochMs: 1000, espProcUs: 7),
        isNull,
      );
      expect(tracker.unknownEchoes, 1);

      tracker.recordSend(
        const PendingMqttEvent(
          seq: 5,
          tSendUs: 150,
          tPhoneEpochMs: 1500,
          runLabel: 'trial',
          qos: 0,
        ),
      );
      nowUs = 251;
      final expired = tracker.pruneExpired();
      expect(expired.map((event) => event.seq), [5]);
      expect(tracker.noEchoes, 1);

      nowUs = 260;
      expect(
        tracker.receiveEcho(seq: 5, tPhoneEpochMs: 1500, espProcUs: 8),
        isNull,
      );
      expect(tracker.unknownEchoes, 2);
    });
  });

  group('HoverEventRateLimiter', () {
    test('allows the first hover, then enforces the configured interval', () {
      final limiter = HoverEventRateLimiter(minimumIntervalUs: 50000);

      expect(limiter.shouldAllow(0), isTrue);
      expect(limiter.shouldAllow(49999), isFalse);
      expect(limiter.shouldAllow(50000), isTrue);
    });

    test('reset allows the next hover immediately', () {
      final limiter = HoverEventRateLimiter(minimumIntervalUs: 50000);

      expect(limiter.shouldAllow(100), isTrue);
      limiter.reset();
      expect(limiter.shouldAllow(101), isTrue);
    });
  });
}
