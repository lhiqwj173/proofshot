import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 始终开启的运行日志。仅记录预定义的技术事件和非敏感字段。
class RuntimeLogs {
  RuntimeLogs._();

  static final RuntimeLogs instance = RuntimeLogs._();
  static const int maxFileBytes = 2 * 1024 * 1024;
  static const MethodChannel _channel = MethodChannel('proofshot/runtime_logs');

  late final Directory _sourceDirectory;
  late final Directory _exportDirectory;
  late final String _sessionId;
  Future<void> _tail = Future<void>.value();
  int _sequence = 0;
  int _operationSequence = 0;
  int _writeFailures = 0;
  Object? _lastWriteError;
  bool _initialized = false;

  void installGlobalErrorHandlers() {
    if (!_initialized) throw StateError('RuntimeLogs is not initialized.');
    final previousFlutter = FlutterError.onError;
    FlutterError.onError = (details) {
      observe(
        failure(
          'global.flutter',
          details.exception,
          details.stack ?? StackTrace.current,
        ),
      );
      if (previousFlutter == null) {
        FlutterError.presentError(details);
      } else {
        previousFlutter(details);
      }
    };
    final previousPlatform = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (error, stack) {
      observe(failure('global.platform', error, stack));
      return previousPlatform?.call(error, stack) ?? false;
    };
  }

  void observe(Future<void> future) {
    unawaited(
      future.then<void>(
        (_) {},
        onError: (Object error, StackTrace stack) {
          debugPrint('Runtime log write failed: $error\n$stack');
        },
      ),
    );
  }

  Future<void> initialize() async {
    if (_initialized) throw StateError('RuntimeLogs is already initialized.');
    final paths = await _channel.invokeMapMethod<String, String>('paths');
    if (paths == null ||
        paths['support'] == null ||
        paths['documents'] == null) {
      throw StateError('Runtime log directories are unavailable.');
    }
    _sourceDirectory = Directory('${paths['support']}/runtime_logs');
    _exportDirectory = Directory('${paths['documents']}/runtime_logs_export');
    await _sourceDirectory.create(recursive: true);
    _sessionId = '${DateTime.now().microsecondsSinceEpoch}-$pid';
    _initialized = true;
    await event(
      'app.start',
      context: <String, Object?>{
        'platform': Platform.operatingSystem,
        'build_mode': kReleaseMode
            ? 'release'
            : kProfileMode
            ? 'profile'
            : 'debug',
      },
    );
  }

  Future<T> trace<T>(
    String code,
    Future<T> Function() action, {
    Map<String, Object?> context = const <String, Object?>{},
    bool startImmediately = false,
  }) async {
    final timer = Stopwatch()..start();
    final operationId = '$_sessionId-${++_operationSequence}';
    final Future<void> startLog = event(
      code,
      phase: 'start',
      context: context,
      operationId: operationId,
    );
    try {
      late final T result;
      if (startImmediately) {
        // 快门请求直接发出，日志仍按序写入并传播错误。
        Future<void> runAction() async {
          result = await action();
        }

        await Future.wait<void>(<Future<void>>[startLog, runAction()]);
      } else {
        await startLog;
        result = await action();
      }
      await event(
        code,
        phase: 'success',
        durationUs: timer.elapsedMicroseconds,
        context: context,
        operationId: operationId,
      );
      return result;
    } catch (error, stack) {
      await failure(
        code,
        error,
        stack,
        durationUs: timer.elapsedMicroseconds,
        context: context,
        operationId: operationId,
      );
      Error.throwWithStackTrace(error, stack);
    }
  }

  Future<void> event(
    String code, {
    String phase = 'event',
    int? durationUs,
    String? operationId,
    Map<String, Object?> context = const <String, Object?>{},
  }) => _record(
    type: 'event',
    code: code,
    phase: phase,
    durationUs: durationUs,
    operationId: operationId,
    context: context,
  );

  Future<void> failure(
    String code,
    Object error,
    StackTrace stack, {
    int? durationUs,
    String? operationId,
    Map<String, Object?> context = const <String, Object?>{},
  }) => _record(
    type: 'error',
    code: code,
    phase: 'failed',
    durationUs: durationUs,
    operationId: operationId,
    message: error.toString(),
    stack: stack.toString(),
    context: context,
  );

  Future<void> _record({
    required String type,
    required String code,
    required String phase,
    int? durationUs,
    String? operationId,
    String? message,
    String? stack,
    required Map<String, Object?> context,
  }) {
    if (!_initialized) throw StateError('RuntimeLogs is not initialized.');
    if (code.isEmpty || code.length > 80) {
      throw ArgumentError.value(code, 'code');
    }
    if (context.length > 32) {
      throw ArgumentError.value(context.length, 'context', 'Too many fields.');
    }
    for (final entry in context.entries) {
      if (entry.key.isEmpty ||
          entry.key.length > 40 ||
          entry.key == 'source_path' ||
          entry.key == 'location' ||
          entry.key == 'media_bytes' ||
          entry.value is String && (entry.value as String).length > 256 ||
          entry.value is! String &&
              entry.value is! num &&
              entry.value is! bool &&
              entry.value != null) {
        throw ArgumentError.value(
          entry.key,
          'context',
          'Only scalar values are allowed.',
        );
      }
    }
    return _enqueue(() async {
      if (_writeFailures > 0) {
        await _write(<String, Object?>{
          'type': 'log_failure',
          'code': 'runtime_log.write_failure',
          'phase': 'recovered',
          'context': <String, Object?>{
            'count': _writeFailures,
            'last_error': _bounded(_lastWriteError.toString(), 1024),
          },
        });
        _writeFailures = 0;
        _lastWriteError = null;
      }
      await _write(<String, Object?>{
        'type': type,
        'code': code,
        'phase': phase,
        'duration_us': durationUs,
        'operation_id': operationId,
        'message': message == null ? null : _bounded(message, 2048),
        'stack': stack == null ? null : _bounded(stack, 8192),
        'context': context,
      });
    });
  }

  Future<T> _enqueue<T>(
    Future<T> Function() task, {
    bool countWriteFailure = true,
  }) async {
    final previous = _tail;
    final completion = Completer<void>();
    _tail = completion.future;
    try {
      await previous;
      return await task();
    } catch (error) {
      if (countWriteFailure) {
        _writeFailures += 1;
        _lastWriteError = error;
      }
      rethrow;
    } finally {
      completion.complete();
    }
  }

  Future<void> _write(Map<String, Object?> fields) async {
    final record = <String, Object?>{
      'schema_version': 1,
      'ts_ms': DateTime.now().millisecondsSinceEpoch,
      'seq': ++_sequence,
      'session_id': _sessionId,
      ...fields,
    };
    final bytes = utf8.encode('${jsonEncode(record)}\n');
    if (bytes.length > maxFileBytes) {
      throw StateError('Runtime log entry is too large.');
    }
    final current = File('${_sourceDirectory.path}/runtime.jsonl');
    if (await current.exists() &&
        await current.length() + bytes.length > maxFileBytes) {
      final rotated = File('${_sourceDirectory.path}/runtime.1.jsonl');
      if (await rotated.exists()) await rotated.delete();
      await current.rename(rotated.path);
    }
    await current.writeAsBytes(bytes, mode: FileMode.append, flush: true);
  }

  String _bounded(String value, int max) =>
      value.length <= max ? value : '${value.substring(0, max)}<truncated>';

  Future<RuntimeLogExport> export() => _enqueue(() async {
    await _exportDirectory.create(recursive: true);
    final paths = <String>[];
    var records = 0;
    var damaged = 0;
    var totalBytes = 0;
    int? firstDamagedLine;
    var globalLine = 0;
    for (final name in <String>['runtime.1.jsonl', 'runtime.jsonl']) {
      final source = File('${_sourceDirectory.path}/$name');
      if (!await source.exists()) continue;
      final target = File('${_exportDirectory.path}/$name');
      final temporary = File('${target.path}.tmp');
      if (await temporary.exists()) await temporary.delete();
      await source.copy(temporary.path);
      final bytes = await temporary.readAsBytes();
      final lines = <List<int>>[];
      var start = 0;
      for (var index = 0; index < bytes.length; index++) {
        if (bytes[index] == 10) {
          lines.add(bytes.sublist(start, index));
          start = index + 1;
        }
      }
      if (start < bytes.length) lines.add(bytes.sublist(start));
      for (final lineBytes in lines) {
        globalLine += 1;
        try {
          final line = utf8.decode(lineBytes);
          if (jsonDecode(line) is Map<String, dynamic>) {
            records += 1;
          } else {
            damaged += 1;
            firstDamagedLine ??= globalLine;
          }
        } on FormatException {
          damaged += 1;
          firstDamagedLine ??= globalLine;
        }
      }
      await temporary.rename(target.path);
      paths.add(target.path);
      totalBytes += await target.length();
    }
    if (paths.isEmpty) throw StateError('No runtime log file exists.');
    return RuntimeLogExport(
      paths: paths,
      records: records,
      damagedLines: damaged,
      firstDamagedLine: firstDamagedLine,
      totalBytes: totalBytes,
    );
  }, countWriteFailure: false);

  Future<void> shareFile(String path) async {
    if (path.isEmpty) throw ArgumentError('No file to share.');
    await _channel.invokeMethod<void>('shareFiles', <String, Object?>{
      'paths': <String>[path],
    });
  }
}

class RuntimeLogExport {
  const RuntimeLogExport({
    required this.paths,
    required this.records,
    required this.damagedLines,
    required this.firstDamagedLine,
    required this.totalBytes,
  });
  final List<String> paths;
  final int records;
  final int damagedLines;
  final int? firstDamagedLine;
  final int totalBytes;
}
