import 'dart:async';

import 'package:flutter/material.dart';

import 'runtime_logs.dart';

class RuntimeLogDialog extends StatefulWidget {
  const RuntimeLogDialog({super.key});

  @override
  State<RuntimeLogDialog> createState() => _RuntimeLogDialogState();
}

class _RuntimeLogDialogState extends State<RuntimeLogDialog> {
  RuntimeLogExport? _export;
  String? _status;
  bool _busy = false;

  Future<void> _generate() async {
    setState(() {
      _busy = true;
      _export = null;
      _status = null;
    });
    try {
      await RuntimeLogs.instance.event('runtime_log.export', phase: 'start');
      final result = await RuntimeLogs.instance.export();
      await RuntimeLogs.instance.event(
        'runtime_log.export',
        phase: 'success',
        context: <String, Object?>{
          'files': result.paths.length,
          'bytes': result.totalBytes,
          'damaged_lines': result.damagedLines,
        },
      );
      if (!mounted) return;
      setState(() {
        _export = result;
        _status =
            '已导出 ${result.paths.length} 个文件，${result.totalBytes} 字节，'
            '${result.records} 条记录；损坏行 ${result.damagedLines} 条'
            '${result.firstDamagedLine == null ? '' : '（首个第 ${result.firstDamagedLine} 行）'}。';
      });
    } catch (error, stack) {
      RuntimeLogs.instance.observe(
        RuntimeLogs.instance.failure('runtime_log.export', error, stack),
      );
      if (mounted) setState(() => _status = '导出失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _share(String path) async {
    final export = _export;
    if (export == null) throw StateError('请先导出运行日志。');
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      await RuntimeLogs.instance.event('runtime_log.share', phase: 'start');
      if (!export.paths.contains(path)) {
        throw StateError('The selected log file is not in the export.');
      }
      await RuntimeLogs.instance.shareFile(path);
      await RuntimeLogs.instance.event('runtime_log.share', phase: 'presented');
      if (mounted) setState(() => _status = '已打开系统分享面板，请选择微信或其他目标。');
    } catch (error, stack) {
      RuntimeLogs.instance.observe(
        RuntimeLogs.instance.failure('runtime_log.share', error, stack),
      );
      if (mounted) setState(() => _status = '分享失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('运行日志'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Text('日志始终记录。导出文件保存在 App 文稿目录；分享由系统面板打开，不会自动发送。'),
        if (_status != null) ...<Widget>[
          const SizedBox(height: 12),
          Text(_status!),
        ],
      ],
    ),
    actions: <Widget>[
      TextButton(
        onPressed: _busy ? null : () => Navigator.pop(context),
        child: const Text('关闭'),
      ),
      TextButton(
        onPressed: _busy ? null : () => unawaited(_generate()),
        child: Text(_busy ? '处理中…' : '导出'),
      ),
      FilledButton(
        onPressed: _busy || _export == null
            ? null
            : () => unawaited(_share(_export!.paths.last)),
        child: const Text('分享最新日志'),
      ),
      if (_export != null && _export!.paths.length > 1)
        TextButton(
          onPressed: _busy
              ? null
              : () => unawaited(_share(_export!.paths.first)),
          child: const Text('分享较早日志'),
        ),
    ],
  );
}
