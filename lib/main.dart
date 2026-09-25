import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'camera/camera_screen.dart';
import 'design/app_palette.dart';
import 'settings/watermark_settings.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.light);
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
        colorScheme:
            ColorScheme.fromSeed(
              seedColor: Colors.white,
              brightness: Brightness.dark,
              surface: AppPalette.background,
            ).copyWith(
              primary: AppPalette.accent,
              onPrimary: AppPalette.background,
            ),
        scaffoldBackgroundColor: AppPalette.background,
        appBarTheme: const AppBarTheme(
          backgroundColor: AppPalette.background,
          foregroundColor: Colors.white,
          elevation: 0,
          centerTitle: true,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: AppPalette.surface,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
          hintStyle: const TextStyle(color: AppPalette.secondaryText),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 16,
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
