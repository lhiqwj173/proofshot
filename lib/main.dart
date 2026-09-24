import 'package:flutter/material.dart';

import 'camera/camera_screen.dart';
import 'settings/watermark_settings.dart';

void main() {
  runApp(const ProofshotApp());
}

class ProofshotApp extends StatefulWidget {
  const ProofshotApp({super.key});

  @override
  State<ProofshotApp> createState() => _ProofshotAppState();
}

class _ProofshotAppState extends State<ProofshotApp> {
  late Future<WatermarkSettings> _settingsLoad;

  @override
  void initState() {
    super.initState();
    _settingsLoad = WatermarkSettings.load();
  }

  void _retrySettingsLoad() {
    setState(() => _settingsLoad = WatermarkSettings.load());
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '水印相机',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blueGrey),
        useMaterial3: true,
      ),
      home: FutureBuilder<WatermarkSettings>(
        future: _settingsLoad,
        builder:
            (BuildContext context, AsyncSnapshot<WatermarkSettings> snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Scaffold(
                  body: Center(child: CircularProgressIndicator()),
                );
              }
              if (snapshot.hasError) {
                return Scaffold(
                  body: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Text('水印设置加载失败：${snapshot.error}'),
                          const SizedBox(height: 12),
                          FilledButton(
                            onPressed: _retrySettingsLoad,
                            child: const Text('重试'),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }
              if (!snapshot.hasData) {
                throw StateError(
                  'Watermark settings load completed without a value or error.',
                );
              }
              return CameraScreen(settings: snapshot.requireData);
            },
      ),
    );
  }
}
