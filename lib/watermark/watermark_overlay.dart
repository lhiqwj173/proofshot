import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'watermark_snapshot.dart';

/// Normalized positions and sizes shared with the native media renderer.
abstract final class WatermarkLayout {
  static const double safeMargin = 0.03;
  static const double customCenterY = 0.71;
  static const double timeCenterY = 0.80;
  static const double metadataCenterY = 0.91;
  static const double timeFontSizeOfShortSide = 0.14;
  static const double metadataFontSizeOfShortSide = 0.035;
  static const double customFontSizeOfShortSide = 0.032;
  static const double brandFontSizeOfShortSide = 0.019;
  static const double minimumTextScale = 0.70;
}

class WatermarkOverlay extends StatelessWidget {
  const WatermarkOverlay({required this.snapshot, super.key});

  final WatermarkSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final Size canvasSize = constraints.biggest;
        if (!canvasSize.width.isFinite ||
            !canvasSize.height.isFinite ||
            canvasSize.width <= 0 ||
            canvasSize.height <= 0) {
          throw StateError(
            'WatermarkOverlay requires a finite, non-empty canvas.',
          );
        }

        final double shortSide = math.min(canvasSize.width, canvasSize.height);
        final double horizontalInset =
            canvasSize.width * WatermarkLayout.safeMargin;
        final double maximumTextWidth =
            canvasSize.width - (horizontalInset * 2);

        return IgnorePointer(
          child: Stack(
            clipBehavior: Clip.none,
            children: <Widget>[
              if (snapshot.customText.isNotEmpty)
                Align(
                  alignment: Alignment(
                    0,
                    (WatermarkLayout.customCenterY * 2) - 1,
                  ),
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: horizontalInset),
                    child: _WatermarkText(
                      text: snapshot.customText,
                      baseFontSize:
                          shortSide * WatermarkLayout.customFontSizeOfShortSide,
                      maximumWidth: maximumTextWidth,
                      maximumLines: 2,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              Align(
                alignment: Alignment(0, (WatermarkLayout.timeCenterY * 2) - 1),
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: horizontalInset),
                  child: _WatermarkText(
                    text: snapshot.timeText,
                    baseFontSize:
                        shortSide * WatermarkLayout.timeFontSizeOfShortSide,
                    maximumWidth: maximumTextWidth,
                    maximumLines: 1,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Align(
                alignment: Alignment(
                  0,
                  (WatermarkLayout.metadataCenterY * 2) - 1,
                ),
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: horizontalInset),
                  child: _WatermarkMetadata(
                    snapshot: snapshot,
                    shortSide: shortSide,
                    maximumWidth: maximumTextWidth,
                  ),
                ),
              ),
              Positioned(
                right: horizontalInset,
                bottom: canvasSize.height * WatermarkLayout.safeMargin,
                child: _WatermarkText(
                  text: snapshot.brandText,
                  baseFontSize:
                      shortSide * WatermarkLayout.brandFontSizeOfShortSide,
                  maximumWidth: maximumTextWidth,
                  maximumLines: 1,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0.4,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _WatermarkMetadata extends StatelessWidget {
  const _WatermarkMetadata({
    required this.snapshot,
    required this.shortSide,
    required this.maximumWidth,
  });

  final WatermarkSnapshot snapshot;
  final double shortSide;
  final double maximumWidth;

  @override
  Widget build(BuildContext context) {
    final double baseFontSize =
        shortSide * WatermarkLayout.metadataFontSizeOfShortSide;
    final TextStyle baseStyle = _watermarkTextStyle(
      fontSize: baseFontSize,
      fontWeight: FontWeight.w500,
    );
    final TextPainter measurement = TextPainter(
      text: TextSpan(
        text:
            '${snapshot.dateText} ${snapshot.weekdayText} ${snapshot.locationText}',
        style: baseStyle,
      ),
      textDirection: TextDirection.ltr,
      maxLines: 2,
    )..layout();
    final double fontSize = _fitFontSize(
      baseFontSize: baseFontSize,
      measuredWidth: measurement.width,
      maximumWidth: maximumWidth,
    );

    return Text.rich(
      TextSpan(
        style: _watermarkTextStyle(
          fontSize: fontSize,
          fontWeight: FontWeight.w500,
        ),
        children: <InlineSpan>[
          TextSpan(text: '${snapshot.dateText}  ${snapshot.weekdayText}  '),
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Padding(
              padding: EdgeInsets.only(right: fontSize * 0.12),
              child: CustomPaint(
                size: Size(fontSize * 0.58, fontSize * 0.86),
                painter: const _LocationPinPainter(),
              ),
            ),
          ),
          TextSpan(text: snapshot.locationText),
        ],
      ),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.noScaling,
      maxLines: 2,
      softWrap: true,
      overflow: TextOverflow.clip,
    );
  }
}

class _WatermarkText extends StatelessWidget {
  const _WatermarkText({
    required this.text,
    required this.baseFontSize,
    required this.maximumWidth,
    required this.maximumLines,
    required this.fontWeight,
    this.letterSpacing = 0,
  });

  final String text;
  final double baseFontSize;
  final double maximumWidth;
  final int maximumLines;
  final FontWeight fontWeight;
  final double letterSpacing;

  @override
  Widget build(BuildContext context) {
    final TextStyle baseStyle = _watermarkTextStyle(
      fontSize: baseFontSize,
      fontWeight: fontWeight,
      letterSpacing: letterSpacing,
    );
    final TextPainter measurement = TextPainter(
      text: TextSpan(text: text, style: baseStyle),
      textDirection: TextDirection.ltr,
      maxLines: maximumLines,
    )..layout();
    final double fontSize = _fitFontSize(
      baseFontSize: baseFontSize,
      measuredWidth: measurement.width,
      maximumWidth: maximumWidth,
    );

    return Text(
      text,
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.noScaling,
      maxLines: maximumLines,
      softWrap: true,
      overflow: TextOverflow.clip,
      style: _watermarkTextStyle(
        fontSize: fontSize,
        fontWeight: fontWeight,
        letterSpacing: letterSpacing,
      ),
    );
  }
}

double _fitFontSize({
  required double baseFontSize,
  required double measuredWidth,
  required double maximumWidth,
}) {
  if (measuredWidth <= maximumWidth) {
    return baseFontSize;
  }
  final double requiredScale = maximumWidth / measuredWidth;
  return baseFontSize *
      math.max(WatermarkLayout.minimumTextScale, requiredScale);
}

TextStyle _watermarkTextStyle({
  required double fontSize,
  required FontWeight fontWeight,
  double letterSpacing = 0,
}) => TextStyle(
  color: Colors.white,
  fontSize: fontSize,
  fontWeight: fontWeight,
  height: 1.0,
  letterSpacing: letterSpacing,
  shadows: const <Shadow>[
    Shadow(color: Color(0xB3000000), offset: Offset(0, 1), blurRadius: 2),
  ],
);

class _LocationPinPainter extends CustomPainter {
  const _LocationPinPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final double centerX = size.width / 2;
    final Path pin = Path()
      ..moveTo(centerX, 0)
      ..cubicTo(
        size.width * 0.92,
        0,
        size.width,
        size.height * 0.18,
        centerX,
        size.height,
      )
      ..cubicTo(0, size.height * 0.18, size.width * 0.08, 0, centerX, 0)
      ..close();
    canvas.drawPath(pin, Paint()..color = const Color(0xFFE53935));
    canvas.drawCircle(
      Offset(centerX, size.height * 0.28),
      size.width * 0.14,
      Paint()..color = Colors.white,
    );
  }

  @override
  bool shouldRepaint(_LocationPinPainter oldDelegate) => false;
}
