import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paho_mqtt_ffi/mqtt311.dart';

import 'support/native_bootstrap.dart';

// A test-only ABI table drives the public admission-error path. No native library,
// production decode hook, broker, background callback or polling is needed.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('typed ABI mapping preserves missing/zero/future evidence', () async {
    var wire = Uint8List(2440);
    final initialize =
        NativeCallable<Int32 Function(Pointer<Void>)>.isolateLocal(
            (Pointer<Void> _) => 0,
            exceptionalReturn: 1);
    final describe = NativeCallable<
            Void Function(Int32, Int32, Pointer<Uint8>)>.isolateLocal(
        (int _, int __, Pointer<Uint8> out) {
      out.asTypedList(2440).setAll(0, wire);
    });
    final pointerSize = sizeOf<IntPtr>();
    final tableSize = 16 + 9 * pointerSize;
    final table = calloc<Uint8>(tableSize);
    final header = ByteData.sublistView(table.asTypedList(tableSize));
    header.setUint32(0, 2, Endian.host);
    header.setUint32(4, tableSize, Endian.host);
    header.setUint64(8, 1661, Endian.host);
    final functions = (table + 16).cast<Pointer<Void>>();
    // Version is required to be non-null but never called in this test.
    functions[0] = table.cast();
    functions[6] = initialize.nativeFunction.cast();
    functions[8] = describe.nativeFunction.cast();
    final create = NativeCallable<
            Int32 Function(Pointer<Void>, Pointer<Uint64>)>.isolateLocal(
        (Pointer<Void> _, Pointer<Uint64> __) => -1000,
        exceptionalReturn: 1);
    final tableV2Size = 16 + 10 * pointerSize;
    final tableV2 = calloc<Uint8>(tableV2Size);
    final headerV2 = ByteData.sublistView(tableV2.asTypedList(tableV2Size));
    headerV2.setUint32(0, 2, Endian.host);
    headerV2.setUint32(4, tableV2Size, Endian.host);
    headerV2.setUint64(8, 1, Endian.host);
    final v2Functions = (tableV2 + 16).cast<Pointer<Void>>();
    v2Functions[0] = table.cast();
    v2Functions[1] = create.nativeFunction.cast();
    final bootstrap = mockMqttNativeApi(api: tableV2.cast());
    Future<MqttErrorInfo> decode(int category, int reason,
        {int flags = 0, int attempt = 0}) async {
      wire = Uint8List(2440);
      final b = ByteData.sublistView(wire);
      for (final entry in <int, int>{
        0: category,
        4: reason,
        8: 999,
        12: -42,
        16: 999,
        20: 123,
        24: 456,
        40: flags
      }.entries) {
        b.setInt32(entry.key, entry.value, Endian.host);
      }
      b.setUint64(48, attempt, Endian.host);
      b.setUint64(56, 1700000000000, Endian.host);
      b.setUint64(64, 1234, Endian.host);
      wire.setAll(72, utf8.encode('现场'));
      wire.setAll(2376, utf8.encode('SecTrust'));
      try {
        await MqttClient.create(const MqttOptions(
            serverUri: 'tcp://invalid:1883', clientId: 'mapping'));
      } on MqttException catch (e) {
        return e.info;
      }
      throw StateError('Expected admission error');
    }

    // No default: compile-time exhaustiveness is part of the public contract.
    String kind(MqttErrorInfo e) => switch (e) {
          MqttArgumentError() => 'argument',
          MqttStateError() => 'state',
          MqttDnsError() => 'dns',
          MqttNetworkError() => 'network',
          MqttTlsConfigurationError() => 'tlsConfiguration',
          MqttTlsHandshakeError() => 'tlsHandshake',
          MqttCertificateError() => 'certificate',
          MqttBrokerError() => 'broker',
          MqttResourceError() => 'resource',
          MqttCancelledError() => 'cancelled',
          MqttInternalError() => 'internal',
          MqttUnknownError() => 'unknown',
        };
    try {
      for (final (category, reason, expected) in [
        (1, 1, 'argument'),
        (2, 20, 'state'),
        (3, 7, 'dns'),
        (4, 0, 'network'),
        (5, 13, 'tlsConfiguration'),
        (5, 14, 'tlsHandshake'),
        (5, 22, 'certificate'),
        (6, 19, 'broker'),
        (7, 5, 'resource'),
        (8, 21, 'cancelled'),
        (9, 0, 'internal'),
        (99, 88, 'unknown'),
        (5, 999, 'unknown'),
        (2, 17, 'unknown'),
      ]) {
        final e = await decode(category, reason);
        expect(kind(e), expected);
        expect(e.message, '现场');
        expect(e.toString(), contains('现场'));
        expect(e.toString(), contains('MqttErrorContext('));
        expect(MqttException(e).toString(), isNot(contains('Instance of')));
        expect(e.attempt, isNull);
        expect(e.stage, MqttErrorStage.unknown);
        expect(e.operationType, MqttOperation.unknown);
      }
      final missing = await decode(5, 16) as MqttCertificateError;
      expect(missing.reason, MqttCertificateReason.expired);
      expect(missing.diagnostics.verifyCode, isNull);
      expect(missing.diagnostics.platform, isNull);
      final present =
          await decode(5, 22, flags: 127, attempt: 7) as MqttCertificateError;
      expect(present.reason, MqttCertificateReason.notYetValid);
      expect(present.diagnostics.verifyCode, 0);
      expect(present.diagnostics.tlsCode, 0);
      expect(present.diagnostics.platform!.code, 0);
      expect(present.diagnostics.platform!.domain, 'SecTrust');
      expect(present.toString(), contains('SecTrust'));
      expect(present.toString(), contains('notYetValid'));
      expect(present.toString(), contains('MqttErrorAttempt('));
      expect(present.toString(), contains('verifyCode: 0'));
      expect(present.attempt!.id, 7);
      expect(present.attempt!.elapsedMs, 1234);
      expect(present.attempt!.willRetry, true);
      expect(present.truncated, true);
      final unknown = await decode(99, 88, flags: 31) as MqttUnknownError;
      expect(unknown.diagnostics.category, 99);
      expect(unknown.diagnostics.reason, 88);
      expect(unknown.diagnostics.systemCode, 123);
      expect(unknown.diagnostics.dnsCode, 456);
      expect(unknown.diagnostics.tls.platform!.code, 0);
      final dns = await decode(3, 7, flags: 3) as MqttDnsError;
      expect(dns.dnsCode, 456);
      expect(dns.systemCode, 123);
    } finally {
      bootstrap.dispose();
      create.close();
      calloc.free(tableV2);
      describe.close();
      initialize.close();
      calloc.free(table);
    }
  });
}
