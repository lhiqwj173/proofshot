import 'dart:async';

import 'package:flutter/widgets.dart';

import 'watermark_overlay.dart';
import 'watermark_snapshot.dart';

class LiveWatermarkPreview extends StatefulWidget {
  const LiveWatermarkPreview({
    required this.locationText,
    required this.customText,
    this.frozenSnapshot,
    super.key,
  });

  final String locationText;
  final String customText;
  final WatermarkSnapshot? frozenSnapshot;

  @override
  State<LiveWatermarkPreview> createState() => _LiveWatermarkPreviewState();
}

class _LiveWatermarkPreviewState extends State<LiveWatermarkPreview> {
  late WatermarkSnapshot _snapshot;
  Timer? _minuteTimer;

  @override
  void initState() {
    super.initState();
    _snapshot = widget.frozenSnapshot ?? _captureSnapshot();
    if (widget.frozenSnapshot == null) {
      _scheduleMinuteRefresh();
    }
  }

  @override
  void didUpdateWidget(covariant LiveWatermarkPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.frozenSnapshot != null) {
      _minuteTimer?.cancel();
      _minuteTimer = null;
      _snapshot = widget.frozenSnapshot!;
      return;
    }
    if (oldWidget.frozenSnapshot != null ||
        oldWidget.locationText != widget.locationText ||
        oldWidget.customText != widget.customText) {
      _snapshot = _captureSnapshot();
    }
    if (_minuteTimer == null) {
      _scheduleMinuteRefresh();
    }
  }

  @override
  void dispose() {
    _minuteTimer?.cancel();
    super.dispose();
  }

  WatermarkSnapshot _captureSnapshot() => WatermarkSnapshot.capture(
    capturedAt: DateTime.now(),
    locationText: widget.locationText,
    customText: widget.customText,
  );

  void _scheduleMinuteRefresh() {
    final DateTime now = DateTime.now();
    final DateTime nextMinute = DateTime(
      now.year,
      now.month,
      now.day,
      now.hour,
      now.minute + 1,
    );
    _minuteTimer = Timer(nextMinute.difference(now), () {
      if (!mounted) {
        return;
      }
      setState(() => _snapshot = _captureSnapshot());
      _scheduleMinuteRefresh();
    });
  }

  @override
  Widget build(BuildContext context) => WatermarkOverlay(snapshot: _snapshot);
}
