Pod::Spec.new do |s|
  s.name = 'paho_mqtt_ffi'
  s.version = '0.1.0'
  s.summary = 'Dart FFI bootstrap for the shared Paho MQTT mobile runtime.'
  s.description = 'Swift MethodChannel discovery only; MQTT traffic uses the C function table through Dart FFI.'
  s.homepage = 'https://github.com/eclipse-paho/paho.mqtt.c'
  s.license = { :type => 'EPL-2.0 OR BSD-3-Clause', :file => 'LICENSE' }
  s.author = 'Paho mobile SDK contributors'
  s.source = { :path => '.' }
  s.source_files = 'Classes/**/*.swift'
  s.dependency 'Flutter'
  # Link the XCFramework itself: CocoaPods does not traverse a symlinked parent directory.
  # Frameworks entries point to the repository's dist/ios without duplicate binaries.
  s.vendored_frameworks = 'Frameworks/CMqttSdk.xcframework'
  s.preserve_paths = 'Frameworks/build-info.json', 'ThirdPartyNotices/**/*'
  s.libraries = 'z'
  s.frameworks = 'Security', 'CoreFoundation'
  s.platform = :ios, '15.0'
  s.swift_version = '5.9'
  s.static_framework = true
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => '$(inherited) i386 x86_64' }
end
