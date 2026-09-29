import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proofshot/diagnostics/runtime_logs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('记录拍照链路、错误堆栈，导出原始日志并通过系统桥分享', () async {
    final root = await Directory.systemTemp.createTemp('proofshot-logs-');
    addTearDown(() => root.delete(recursive: true));
    final support = Directory('${root.path}/support');
    final documents = Directory('${root.path}/documents');
    final sharedPaths = <String>[];
    const channel = MethodChannel('proofshot/runtime_logs');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'paths':
          return <String, String>{
            'support': support.path,
            'documents': documents.path,
          };
        case 'shareFiles':
          sharedPaths.addAll(
            ((call.arguments as Map<Object?, Object?>)['paths']
                    as List<Object?>)
                .cast<String>(),
          );
          return null;
        default:
          throw StateError('Unexpected method: ${call.method}');
      }
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final logs = RuntimeLogs.instance;
    await logs.initialize();
    await logs.trace('camera.take_photo', () async => 'captured');
    await expectLater(
      logs.trace<void>(
        'haptics.impact',
        () async => throw StateError('haptic failed'),
      ),
      throwsStateError,
    );

    final source = File('${support.path}/runtime_logs/runtime.jsonl');
    final sourceBytes = await source.readAsBytes();
    final exported = await logs.export();
    expect(exported.paths, hasLength(1));
    expect(await File(exported.paths.single).readAsBytes(), sourceBytes);
    expect(exported.damagedLines, 0);
    expect(exported.records, 5);
    final entries = (await source.readAsLines(encoding: utf8))
        .map((line) => jsonDecode(line) as Map<String, dynamic>)
        .toList();
    expect(entries.map((entry) => entry['seq']), <int>[1, 2, 3, 4, 5]);
    expect(entries[1]['operation_id'], entries[2]['operation_id']);
    expect(entries[3]['operation_id'], entries[4]['operation_id']);
    expect(entries[1]['operation_id'], isNot(entries[3]['operation_id']));
    expect(entries.last['type'], 'error');
    expect(entries.last['stack'], isNotEmpty);

    await logs.shareFile(exported.paths.single);
    expect(sharedPaths, exported.paths);

    await source.writeAsString(
      'broken-json\n',
      mode: FileMode.append,
      encoding: utf8,
    );
    final damagedExport = await logs.export();
    expect(damagedExport.damagedLines, 1);
    expect(damagedExport.firstDamagedLine, 6);
    expect(
      await File(damagedExport.paths.single).readAsBytes(),
      await source.readAsBytes(),
    );

    final padding = RuntimeLogs.maxFileBytes - await source.length() - 5;
    await source.writeAsString(
      'x' * padding,
      mode: FileMode.append,
      encoding: utf8,
    );
    await logs.event('runtime.rotate');
    final rotatedExport = await logs.export();
    expect(rotatedExport.paths, hasLength(2));
    expect(rotatedExport.paths.first, endsWith('runtime.1.jsonl'));
    expect(rotatedExport.paths.last, endsWith('runtime.jsonl'));
    expect(rotatedExport.damagedLines, greaterThan(0));
  });
}
