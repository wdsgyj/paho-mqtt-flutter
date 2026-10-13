/// Types shared by the versioned MQTT clients.
library;

import 'src/debug.dart';
import 'dart:convert';
import 'dart:typed_data';
export 'src/errors.dart'
    show
        MqttException,
        MqttErrorInfo,
        MqttArgumentError,
        MqttStateError,
        MqttDnsError,
        MqttNetworkError,
        MqttTlsConfigurationError,
        MqttTlsHandshakeError,
        MqttCertificateError,
        MqttResourceError,
        MqttCancelledError,
        MqttInternalError,
        MqttUnknownError,
        MqttErrorContext,
        MqttErrorStage,
        MqttOperation,
        MqttStateReason,
        MqttNetworkReason,
        MqttCertificateReason,
        MqttResourceReason,
        MqttCancellationReason,
        MqttErrorAttempt,
        MqttPlatformError,
        MqttTlsDiagnostics,
        MqttRawDiagnostics,
        MqttBrokerError;

enum MqttQos { atMostOnce, atLeastOnce, exactlyOnce }

final class MqttCredentials {
  const MqttCredentials({this.username, this.passwordBytes});
  factory MqttCredentials.text({String? username, String? password}) =>
      MqttCredentials(
          username: username,
          passwordBytes: password == null
              ? null
              : Uint8List.fromList(utf8.encode(password)));
  final String? username;
  final Uint8List? passwordBytes;

  @override
  String toString() => mqttDebugString('MqttCredentials', {
        'username': username,
        'passwordBytes': mqttDebugSecret(passwordBytes),
      });
}

final class MqttTlsOptions {
  const MqttTlsOptions(
      {this.trustStore,
      this.certificate,
      this.privateKey,
      this.privateKeyPassword,
      this.insecureSkipVerify = false});
  final String? trustStore, certificate, privateKey, privateKeyPassword;
  final bool insecureSkipVerify;

  @override
  String toString() => mqttDebugString('MqttTlsOptions', {
        'trustStore': trustStore,
        'certificate': certificate,
        'privateKey': privateKey,
        'privateKeyPassword': mqttDebugSecret(privateKeyPassword),
        'insecureSkipVerify': insecureSkipVerify,
      });
}

final class MqttQueueLimits {
  const MqttQueueLimits(
      {this.maxPendingOperations = 128,
      this.maxBufferedPublishes = 128,
      this.maxInflightPublishes = 128,
      this.maxReceivedMessages = 256,
      this.maxBytes = 8 * 1024 * 1024});
  final int maxPendingOperations,
      maxBufferedPublishes,
      maxInflightPublishes,
      maxReceivedMessages,
      maxBytes;

  @override
  String toString() => mqttDebugString('MqttQueueLimits', {
        'maxPendingOperations': maxPendingOperations,
        'maxBufferedPublishes': maxBufferedPublishes,
        'maxInflightPublishes': maxInflightPublishes,
        'maxReceivedMessages': maxReceivedMessages,
        'maxBytes': maxBytes,
      });
}

final class MqttUserProperty {
  const MqttUserProperty(this.name, this.value);
  final String name, value;

  @override
  String toString() => mqttDebugString('MqttUserProperty', {
        'name': name,
        'value': value,
      });
}

/// How to treat stored Paho messages when creating a new native client.
enum MqttPersistenceRestore { restore, discard }

final class MqttPersistenceOptions {
  const MqttPersistenceOptions(
      {required this.directory,
      required this.onCreate,
      this.persistQos0 = false});
  final String directory;
  final MqttPersistenceRestore onCreate;
  final bool persistQos0;

  @override
  String toString() => mqttDebugString('MqttPersistenceOptions', {
        'directory': directory,
        'onCreate': onCreate,
        'persistQos0': persistQos0,
      });
}
