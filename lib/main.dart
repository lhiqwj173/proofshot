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
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFC6F4D5),
          brightness: Brightness.dark,
          surface: const Color(0xFF111B1D),
        ),
        scaffoldBackgroundColor: const Color(0xFF0E1719),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF0E1719),
          foregroundColor: Colors.white,
          elevation: 0,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF1B292B),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide.none,
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 18,
            vertical: 18,
          ),
        ),
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
