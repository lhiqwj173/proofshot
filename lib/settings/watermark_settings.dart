import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persisted, user-editable watermark fields.
class WatermarkSettings extends ChangeNotifier {
  WatermarkSettings._({
    required this._preferences,
    required this._manualLocation,
    required this._customText,
  });

  static const String _storageKey = 'watermark_settings_v1';

  final SharedPreferences _preferences;
  String _manualLocation;
  String _customText;

  String get manualLocation => _manualLocation;
  String get customText => _customText;

  static Future<WatermarkSettings> load() async {
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    final String? storedValue = preferences.getString(_storageKey);
    if (storedValue == null) {
      return WatermarkSettings._(
        preferences: preferences,
        manualLocation: '',
        customText: '',
      );
    }

    final Object? decodedValue = jsonDecode(storedValue);
    if (decodedValue is! Map<String, dynamic>) {
      throw const FormatException(
        'Stored watermark settings must be a JSON object.',
      );
    }
    if (decodedValue.length != 3 || decodedValue['schemaVersion'] != 1) {
      throw const FormatException(
        'Stored watermark settings have an unsupported schema.',
      );
    }

    final Object? manualLocation = decodedValue['manualLocation'];
    final Object? customText = decodedValue['customText'];
    if (manualLocation is! String || customText is! String) {
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
      customText.trim(),
      fieldName: 'customText',
      maximumGraphemes: 30,
    );

    return WatermarkSettings._(
      preferences: preferences,
      manualLocation: manualLocation.trim(),
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

    final String encodedValue = jsonEncode(<String, Object>{
      'schemaVersion': 1,
      'manualLocation': normalizedLocation,
      'customText': normalizedCustomText,
    });
    final bool persisted = await _preferences.setString(
      _storageKey,
      encodedValue,
    );
    if (!persisted) {
      throw StateError('Failed to persist watermark settings.');
    }

    _manualLocation = normalizedLocation;
    _customText = normalizedCustomText;
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
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('水印设置已保存')));
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
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: <Widget>[
          TextField(
            controller: _locationController,
            maxLines: 1,
            maxLength: 40,
            maxLengthEnforcement: MaxLengthEnforcement.enforced,
            decoration: const InputDecoration(
              labelText: '手动地点',
              helperText: '填写后优先使用；清空后恢复自动定位',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _customTextController,
            maxLines: 1,
            maxLength: 30,
            maxLengthEnforcement: MaxLengthEnforcement.enforced,
            decoration: const InputDecoration(
              labelText: '自定义水印',
              helperText: '可留空，最多 30 个字符',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _isSaving ? null : _save,
            child: Text(_isSaving ? '保存中…' : '保存设置'),
          ),
        ],
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
