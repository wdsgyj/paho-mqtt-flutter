package main

var apiExpressions = []string{
	"v5.MqttProperties([]);",
	"v5.PropertyValue(31, \"reason\");",
	"v5.NativeClient;",
	"v5.MqttReceivedPublishProperties([]);",
	"v5.MqttConnackProperties([]);",
	"v5.MqttAcknowledgementProperties([]);",
	"v5.MqttPublishAcknowledgement(null);",
	"v5.MqttConnected(null, null);",
	"v3.MqttConnected(null, null);",
	"v5.MqttMessage(null);",
	"v3.MqttMessage(null);",
	"v5.MqttSubscribeResult([], ack);",
	"v3.MqttSubscribeResult([]);",
	"ack.number(31);",
	"received.number(2);",
	"received.reasonString;",
	"connected.history;",
	"connected3.history;",
	"common.decodeNativeException(null);",
	"common.NativeError;",
}
var apiPrelude = []string{
	"import 'package:paho_mqtt_ffi/mqtt5.dart' as v5;",
	"import 'package:paho_mqtt_ffi/mqtt311.dart' as v3;",
	"import 'package:paho_mqtt_ffi/common.dart' as common;",
	"void check(v5.MqttAcknowledgementProperties ack,",
	"v5.MqttReceivedPublishProperties received, v5.MqttConnected connected,",
	"v3.MqttConnected connected3) {",
}
