// Test-only adapter. Production code passes its listener to startConnecting.
import 'dart:async';
import 'package:paho_mqtt_ffi/mqtt311.dart';

final _probes = Expando<_ConnectionProbe>();

final class _ConnectionProbe {
  final events = StreamController<MqttEvent>.broadcast(sync: true);
  late final listener = MqttEventListener(
    onEvent: (event) {
      if (event is MqttErrorEvent) {
        events.addError(event.error, event.stackTrace);
      } else {
        events.add(event);
      }
    },
  );
}

extension ConnectionProbe on MqttClient {
  _ConnectionProbe get _probe => _probes[this] ??= _ConnectionProbe();
  Stream<MqttEvent> get events => _probe.events.stream;
  Future<bool> connectAndWaitForTest() async {
    final result = Completer<bool>();
    final subscription = events.listen(
      (event) {
        if (result.isCompleted) return;
        if (event is MqttConnectionEstablished)
          result.complete(event.sessionPresent);
        if (event is MqttConnectionFailure) result.completeError(event.error);
      },
      onError: (Object e, StackTrace s) {
        if (!result.isCompleted) result.completeError(e, s);
      },
    );
    // Attach an error handler before native delivery can win the admission race.
    final outcome = result.future;
    unawaited(outcome.then<void>((_) {}, onError: (Object e) {}));
    try {
      await startConnecting(_probe.listener);
      return await outcome;
    } finally {
      await subscription.cancel();
    }
  }
}
