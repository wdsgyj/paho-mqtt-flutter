import 'package:flutter/material.dart';
import 'package:paho_mqtt_ffi/mqtt311.dart' as mqtt311;
import 'package:paho_mqtt_ffi/mqtt5.dart';

// Build fixture: retain plugin bootstrap, TLS options and FFI client lifecycle in AOT.
// Building does not connect to a broker or require a device.
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: ElevatedButton(
            onPressed: () async {
              final client = await MqttClient.create(
                const MqttOptions(
                  serverUri: 'ssl://localhost:8883',
                  clientId: 'release-build-check',
                  tls: MqttTlsOptions(insecureSkipVerify: false),
                ),
              );
              await client.close();
              final old = await mqtt311.MqttClient.create(
                const mqtt311.MqttOptions(
                  serverUri: 'ssl://localhost:8883',
                  clientId: 'release-build-check-311',
                ),
              );
              await old.close();
            },
            child: const Text('Create and close MQTT client'),
          ),
        ),
      ),
    ),
  );
}
