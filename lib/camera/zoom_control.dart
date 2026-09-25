import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../design/app_palette.dart';
import 'camera_coordinator.dart';

/// The zoom step a released zoom gesture snaps to, when one is close enough.
CameraZoomStep? snapZoomStep(List<CameraZoomStep> steps, double factor) {
  CameraZoomStep? nearest;
  double smallestDistance = double.infinity;
  for (final CameraZoomStep step in steps) {
    final double distance = (_octaves(step.factor) - _octaves(factor)).abs();
    if (distance < smallestDistance) {
      smallestDistance = distance;
      nearest = step;
    }
  }
  return smallestDistance <= _snapToleranceOctaves ? nearest : null;
}

const double _snapToleranceOctaves = 0.09;
const double _dialRadius = 820;
const double _dialTopInset = 12;
const double _dialHeight = 70;
const double _dialHalfWindowOctaves = 1;
const double _dialLabelCenterY = 50;
const double _referenceFocalLengthMm = 26;
const double _dragOctavesPerPixel = 1 / 150;

double _octaves(double factor) => math.log(math.max(factor, 0.01)) / math.ln2;

String _zoomText(double factor, {bool suffix = true}) {
  final double rounded = (factor * 100).roundToDouble() / 100;
  final String value = rounded % 1 == 0
      ? rounded.toInt().toString()
      : rounded.toStringAsFixed(2).replaceFirst(RegExp(r'0+$'), '');
  return suffix ? '${value}x' : value;
}

/// Zoom shortcuts with a drag dial, matching the system camera control.
class CameraZoomControl extends StatefulWidget {
  const CameraZoomControl({
    required this.steps,
    required this.factor,
    required this.minimumFactor,
    required this.maximumFactor,
    required this.showDial,
    required this.onFactorChanged,
    required this.onStepSelected,
    super.key,
  });

  final List<CameraZoomStep> steps;
  final double factor;
  final double minimumFactor;
  final double maximumFactor;
  final bool showDial;
  final ValueChanged<double> onFactorChanged;
  final ValueChanged<CameraZoomStep> onStepSelected;

  @override
  State<CameraZoomControl> createState() => _CameraZoomControlState();
}

class _CameraZoomControlState extends State<CameraZoomControl> {
  bool _dragging = false;
  double _dragStartFactor = 1;
  double _dragOctaves = 0;
  double _longPressOffsetX = 0;

  void _startDrag() {
    setState(() {
      _dragging = true;
      _dragStartFactor = widget.factor;
      _dragOctaves = 0;
      _longPressOffsetX = 0;
    });
  }

  void _updateDrag(double deltaX) {
    _dragOctaves += deltaX * _dragOctavesPerPixel;
    widget.onFactorChanged(
      _dragStartFactor * math.pow(2, _dragOctaves).toDouble(),
    );
  }

  void _updateLongPress(LongPressMoveUpdateDetails details) {
    final double deltaX = details.offsetFromOrigin.dx - _longPressOffsetX;
    _longPressOffsetX = details.offsetFromOrigin.dx;
    _updateDrag(deltaX);
  }

  void _endDrag() {
    if (!_dragging) {
      return;
    }
    setState(() => _dragging = false);
    final CameraZoomStep? step = snapZoomStep(widget.steps, widget.factor);
    if (step != null) {
      widget.onStepSelected(step);
    }
  }

  CameraZoomStep? get _activeStep {
    CameraZoomStep? active;
    double smallestDistance = double.infinity;
    for (final CameraZoomStep step in widget.steps) {
      final double distance = (_octaves(step.factor) - _octaves(widget.factor))
          .abs();
      if (distance < smallestDistance) {
        smallestDistance = distance;
        active = step;
      }
    }
    return active;
  }

  bool _isSettled(CameraZoomStep step) =>
      (_octaves(step.factor) - _octaves(widget.factor)).abs() < 0.05;

  String _chipLabel(CameraZoomStep step, CameraZoomStep? active) {
    if (!identical(step, active) || _isSettled(step)) {
      return step.label;
    }
    return _zoomText(widget.factor);
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '变焦 ${_zoomText(widget.factor)}',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: (DragStartDetails details) => _startDrag(),
        onHorizontalDragUpdate: (DragUpdateDetails details) =>
            _updateDrag(details.delta.dx),
        onHorizontalDragEnd: (DragEndDetails details) => _endDrag(),
        onHorizontalDragCancel: _endDrag,
        onLongPressStart: (LongPressStartDetails details) => _startDrag(),
        onLongPressMoveUpdate: _updateLongPress,
        onLongPressEnd: (LongPressEndDetails details) => _endDrag(),
        onLongPressCancel: _endDrag,
        child: SizedBox(
          height: _dialHeight,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            child: widget.showDial || _dragging
                ? _ZoomDial(
                    key: const ValueKey<String>('dial'),
                    steps: widget.steps,
                    factor: widget.factor,
                    minimumFactor: widget.minimumFactor,
                    maximumFactor: widget.maximumFactor,
                  )
                : _buildChips(),
          ),
        ),
      ),
    );
  }

  Widget _buildChips() {
    final CameraZoomStep? active = _activeStep;
    return Row(
      key: const ValueKey<String>('chips'),
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        for (final CameraZoomStep step in widget.steps)
          _ZoomChip(
            label: _chipLabel(step, active),
            selected: identical(step, active),
            onTap: () => widget.onStepSelected(step),
          ),
      ],
    );
  }
}

class _ZoomChip extends StatelessWidget {
  const _ZoomChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(18),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            height: 34,
            constraints: const BoxConstraints(minWidth: 46),
            margin: const EdgeInsets.symmetric(horizontal: 3),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: selected
                  ? AppPalette.elevatedSurface
                  : AppPalette.translucentControl,
              borderRadius: BorderRadius.circular(18),
            ),
            child: Text(
              label,
              textScaler: TextScaler.noScaling,
              style: TextStyle(
                color: selected ? AppPalette.accent : Colors.white70,
                fontSize: 13,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ZoomDial extends StatelessWidget {
  const _ZoomDial({
    required this.steps,
    required this.factor,
    required this.minimumFactor,
    required this.maximumFactor,
    super.key,
  });

  final List<CameraZoomStep> steps;
  final double factor;
  final double minimumFactor;
  final double maximumFactor;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: _dialHeight,
      child: CustomPaint(
        painter: _ZoomDialPainter(
          steps: steps,
          factor: factor,
          minimumFactor: minimumFactor,
          maximumFactor: maximumFactor,
        ),
      ),
    );
  }
}

class _ZoomDialPainter extends CustomPainter {
  const _ZoomDialPainter({
    required this.steps,
    required this.factor,
    required this.minimumFactor,
    required this.maximumFactor,
  });

  final List<CameraZoomStep> steps;
  final double factor;
  final double minimumFactor;
  final double maximumFactor;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) {
      return;
    }
    final double halfWidth = (size.width / 2) - 4;
    final double halfAngle = math.asin(math.min(1, halfWidth / _dialRadius));
    final Offset origin = Offset(size.width / 2, _dialRadius + _dialTopInset);
    final double centerOctave = _octaves(factor);
    final CameraZoomStep? activeStep = snapZoomStep(steps, factor);
    final List<CameraZoomStep> visibleSteps = steps
        .where(
          (CameraZoomStep step) =>
              (_octaves(step.factor) - centerOctave).abs() <=
              _dialHalfWindowOctaves,
        )
        .toList(growable: false);

    final Paint tickPaint = Paint()
      ..strokeWidth = 1
      ..strokeCap = StrokeCap.round
      ..color = Colors.white.withValues(alpha: 0.42);
    final Paint majorTickPaint = Paint()
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round
      ..color = Colors.white.withValues(alpha: 0.85);

    const int tickCount = 44;
    final double minimumOctave = _octaves(minimumFactor);
    final double maximumOctave = _octaves(maximumFactor);
    for (int index = 0; index <= tickCount; index++) {
      final double octave =
          centerOctave -
          _dialHalfWindowOctaves +
          (2 * _dialHalfWindowOctaves) * index / tickCount;
      if (octave < minimumOctave || octave > maximumOctave) {
        continue;
      }
      final bool major = visibleSteps.any(
        (CameraZoomStep step) =>
            (_octaves(step.factor) - octave).abs() <
            _dialHalfWindowOctaves / tickCount,
      );
      _drawTick(
        canvas,
        origin,
        _dialAngle(octave, centerOctave, halfAngle),
        major ? 11 : 6,
        major ? majorTickPaint : tickPaint,
      );
    }

    _drawTick(canvas, origin, 0, 18, majorTickPaint);
    _drawMarker(canvas, Offset(size.width / 2, _dialTopInset));
    _drawCenteredText(
      canvas,
      _zoomText(factor),
      Offset(size.width / 2, _dialTopInset + 24),
      const TextStyle(
        color: AppPalette.accent,
        fontSize: 15,
        fontWeight: FontWeight.w600,
      ),
    );
    _drawCenteredText(
      canvas,
      '${(_referenceFocalLengthMm * factor).round()}MM',
      Offset(size.width / 2, _dialTopInset + 44),
      TextStyle(
        color: Colors.white.withValues(alpha: 0.6),
        fontSize: 10,
        fontWeight: FontWeight.w500,
      ),
    );

    for (final CameraZoomStep step in visibleSteps) {
      if ((_octaves(step.factor) - centerOctave).abs() < 0.36) {
        continue;
      }
      final double angle = _dialAngle(
        _octaves(step.factor),
        centerOctave,
        halfAngle,
      );
      final bool selected = identical(step, activeStep);
      final double labelX = origin.dx + (math.sin(angle) * _dialRadius);
      _drawCenteredText(
        canvas,
        _zoomText(step.factor, suffix: false),
        Offset(labelX, _dialLabelCenterY),
        TextStyle(
          color: selected
              ? AppPalette.accent
              : Colors.white.withValues(alpha: 0.62),
          fontSize: 12,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
        ),
        horizontalBounds: (12, size.width - 12),
      );
      _drawCenteredText(
        canvas,
        '${(_referenceFocalLengthMm * step.factor).round()}MM',
        Offset(labelX, _dialLabelCenterY + 14),
        TextStyle(
          color: Colors.white.withValues(alpha: 0.42),
          fontSize: 9,
          fontWeight: FontWeight.w500,
        ),
        horizontalBounds: (12, size.width - 12),
      );
    }
  }

  double _dialAngle(double octave, double centerOctave, double halfAngle) =>
      halfAngle *
      (octave - centerOctave).clamp(
        -_dialHalfWindowOctaves,
        _dialHalfWindowOctaves,
      ) /
      _dialHalfWindowOctaves;

  void _drawTick(
    Canvas canvas,
    Offset origin,
    double angle,
    double length,
    Paint paint,
  ) {
    canvas.drawLine(
      origin + _radialOffset(angle, _dialRadius),
      origin + _radialOffset(angle, _dialRadius - length),
      paint,
    );
  }

  void _drawMarker(Canvas canvas, Offset apex) {
    final Path marker = Path()
      ..moveTo(apex.dx - 4, apex.dy - 10)
      ..lineTo(apex.dx + 4, apex.dy - 10)
      ..lineTo(apex.dx, apex.dy - 3)
      ..close();
    canvas.drawPath(marker, Paint()..color = AppPalette.accent);
  }

  void _drawCenteredText(
    Canvas canvas,
    String value,
    Offset center,
    TextStyle style, {
    (double, double)? horizontalBounds,
  }) {
    final TextPainter painter = TextPainter(
      text: TextSpan(text: value, style: style),
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.noScaling,
      maxLines: 1,
    )..layout();
    double x = center.dx - (painter.width / 2);
    if (horizontalBounds case (final double minimum, final double maximum)) {
      x = math.min(
        math.max(x, minimum),
        math.max(minimum, maximum - painter.width),
      );
    }
    painter.paint(canvas, Offset(x, center.dy - (painter.height / 2)));
  }

  Offset _radialOffset(double angle, double radius) =>
      Offset(math.sin(angle) * radius, -math.cos(angle) * radius);

  @override
  bool shouldRepaint(_ZoomDialPainter oldDelegate) =>
      oldDelegate.factor != factor ||
      oldDelegate.steps != steps ||
      oldDelegate.minimumFactor != minimumFactor ||
      oldDelegate.maximumFactor != maximumFactor;
}
