import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../design/app_palette.dart';

/// Persisted, user-editable watermark fields.
class WatermarkSettings extends ChangeNotifier {
  WatermarkSettings._({
    required this._preferences,
    required this._manualLocation,
    required this._automaticLocation,
    required this._customText,
  });

  static const String _storageKey = 'watermark_settings_v1';

  final SharedPreferences _preferences;
  String _manualLocation;
  String _automaticLocation;
  String _customText;

  String get manualLocation => _manualLocation;
  String get automaticLocation => _automaticLocation;
  String get customText => _customText;
  String? get activeLocation {
    final String location = _manualLocation.isNotEmpty
        ? _manualLocation
        : _automaticLocation;
    return location.isEmpty ? null : location;
  }

  static Future<WatermarkSettings> load() async {
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    final String? storedValue = preferences.getString(_storageKey);
    if (storedValue == null) {
      return WatermarkSettings._(
        preferences: preferences,
        manualLocation: '',
        automaticLocation: '',
        customText: '',
      );
    }

    final Object? decodedValue = jsonDecode(storedValue);
    if (decodedValue is! Map<String, dynamic>) {
      throw const FormatException(
        'Stored watermark settings must be a JSON object.',
      );
    }
    final Object? schemaVersion = decodedValue['schemaVersion'];
    if ((schemaVersion != 1 || decodedValue.length != 3) &&
        (schemaVersion != 2 || decodedValue.length != 4)) {
      throw const FormatException(
        'Stored watermark settings have an unsupported schema.',
      );
    }

    final Object? manualLocation = decodedValue['manualLocation'];
    final Object? customText = decodedValue['customText'];
    final Object? automaticLocation = schemaVersion == 2
        ? decodedValue['automaticLocation']
        : '';
    if (manualLocation is! String ||
        automaticLocation is! String ||
        customText is! String) {
      throw const FormatException(
        'Stored watermark settings contain invalid field types.',
      );
    }
    _validateText(
      manualLocation.trim(),
      fieldName: 'manualLocation',
      maximumGraphemes: 40,
    );
    _validateText(
      automaticLocation.trim(),
      fieldName: 'automaticLocation',
      maximumGraphemes: 40,
    );
    _validateText(
      customText.trim(),
      fieldName: 'customText',
      maximumGraphemes: 30,
    );

    return WatermarkSettings._(
      preferences: preferences,
      manualLocation: manualLocation.trim(),
      automaticLocation: automaticLocation.trim(),
      customText: customText.trim(),
    );
  }

  Future<void> update({
    required String manualLocation,
    required String customText,
  }) async {
    final String normalizedLocation = manualLocation.trim();
    final String normalizedCustomText = customText.trim();
    _validateText(
      normalizedLocation,
      fieldName: 'manualLocation',
      maximumGraphemes: 40,
    );
    _validateText(
      normalizedCustomText,
      fieldName: 'customText',
      maximumGraphemes: 30,
    );

    if (normalizedLocation == _manualLocation &&
        normalizedCustomText == _customText) {
      return;
    }

    await _persist(
      manualLocation: normalizedLocation,
      automaticLocation: _automaticLocation,
      customText: normalizedCustomText,
    );
  }

  Future<void> useAutomaticLocation(String location) async {
    final String normalizedLocation = location.trim();
    _validateText(
      normalizedLocation,
      fieldName: 'automaticLocation',
      maximumGraphemes: 40,
    );
    if (normalizedLocation.isEmpty) {
      throw ArgumentError.value(
        location,
        'location',
        'The refreshed location must be non-empty.',
      );
    }
    if (_manualLocation.isEmpty && _automaticLocation == normalizedLocation) {
      return;
    }
    await _persist(
      manualLocation: '',
      automaticLocation: normalizedLocation,
      customText: _customText,
    );
  }

  Future<void> _persist({
    required String manualLocation,
    required String automaticLocation,
    required String customText,
  }) async {
    final String encodedValue = jsonEncode(<String, Object>{
      'schemaVersion': 2,
      'manualLocation': manualLocation,
      'automaticLocation': automaticLocation,
      'customText': customText,
    });
    final bool persisted = await _preferences.setString(
      _storageKey,
      encodedValue,
    );
    if (!persisted) {
      throw StateError('Failed to persist watermark settings.');
    }

    _manualLocation = manualLocation;
    _automaticLocation = automaticLocation;
    _customText = customText;
    notifyListeners();
  }
}

class WatermarkSettingsPage extends StatefulWidget {
  const WatermarkSettingsPage({required this.settings, super.key});

  final WatermarkSettings settings;

  @override
  State<WatermarkSettingsPage> createState() => _WatermarkSettingsPageState();
}

class _WatermarkSettingsPageState extends State<WatermarkSettingsPage> {
  late final TextEditingController _locationController;
  late final TextEditingController _customTextController;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _locationController = TextEditingController(
      text: widget.settings.manualLocation,
    );
    _customTextController = TextEditingController(
      text: widget.settings.customText,
    );
  }

  @override
  void dispose() {
    _locationController.dispose();
    _customTextController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _isSaving = true);
    try {
      await widget.settings.update(
        manualLocation: _locationController.text,
        customText: _customTextController.text,
      );
      if (mounted) {
        Navigator.of(context).pop();
      }
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('水印设置')),
      body: SafeArea(
        child: Column(
          children: <Widget>[
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 28, 20, 24),
                children: <Widget>[
                  const Text(
                    '拍摄地点',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _locationController,
                    maxLines: 1,
                    maxLength: 40,
                    maxLengthEnforcement: MaxLengthEnforcement.enforced,
                    decoration: const InputDecoration(
                      hintText: '留空则沿用上次定位',
                      prefixIcon: Icon(Icons.location_on_outlined),
                      counterText: '',
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    '点取景页右上角的定位按钮才会刷新。地点会实时显示在取景画面，并写入照片或视频。',
                    style: TextStyle(
                      color: AppPalette.secondaryText,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 36),
                  const Text(
                    '自定义文字',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _customTextController,
                    maxLines: 1,
                    maxLength: 30,
                    maxLengthEnforcement: MaxLengthEnforcement.enforced,
                    decoration: const InputDecoration(
                      hintText: '可留空',
                      prefixIcon: Icon(Icons.edit_outlined),
                      counterText: '',
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    '拍摄时间会自动加入水印。',
                    style: TextStyle(
                      color: AppPalette.secondaryText,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
              child: FilledButton(
                onPressed: _isSaving ? null : _save,
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                child: Text(_isSaving ? '保存中…' : '完成'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

void _validateText(
  String value, {
  required String fieldName,
  required int maximumGraphemes,
}) {
  if (value.characters.length > maximumGraphemes) {
    throw ArgumentError.value(
      value,
      fieldName,
      'Must contain at most $maximumGraphemes graphemes.',
    );
  }
}
