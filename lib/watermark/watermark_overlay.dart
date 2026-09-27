import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'watermark_snapshot.dart';

/// Normalized positions and sizes shared with the native media renderer.
abstract final class WatermarkLayout {
  static const double safeMarginOfShortSide = 0.06;
  static const double topInsetOfShortSide = 0.06;
  static const double dateFontSizeOfShortSide = 0.027;
  static const double timeFontSizeOfShortSide = 0.09;
  static const double locationFontSizeOfShortSide = 0.027;
  static const double customFontSizeOfShortSide = 0.032;
  static const double brandFontSizeOfShortSide = 0.019;
  static const double customBottomSpacingOfShortSide = 0.012;
  static const double dateBottomSpacingOfShortSide = 0.0075;
  static const double timeBottomSpacingOfShortSide = 0.036;
  static const double locationBottomSpacingOfShortSide = 0.025;
  static const double locationPinWidthOfFontSize = 0.58;
  static const double locationPinHeightOfFontSize = 0.86;
  static const double locationPinGapOfFontSize = 0.55;
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
        final double inset = shortSide * WatermarkLayout.safeMarginOfShortSide;
        final double maximumTextWidth = canvasSize.width - (inset * 2);

        return IgnorePointer(
          child: Stack(
            clipBehavior: Clip.none,
            children: <Widget>[
              Positioned(
                left: inset,
                top: shortSide * WatermarkLayout.topInsetOfShortSide,
                right: inset,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    if (snapshot.customText.isNotEmpty) ...<Widget>[
                      _WatermarkText(
                        text: snapshot.customText,
                        baseFontSize:
                            shortSide *
                            WatermarkLayout.customFontSizeOfShortSide,
                        maximumWidth: maximumTextWidth,
                        maximumLines: 2,
                        fontWeight: FontWeight.w500,
                        textAlign: TextAlign.left,
                      ),
                      SizedBox(
                        height:
                            shortSide *
                            WatermarkLayout.customBottomSpacingOfShortSide,
                      ),
                    ],
                    _WatermarkText(
                      text: '${snapshot.dateText}  ·  ${snapshot.weekdayText}',
                      baseFontSize:
                          shortSide * WatermarkLayout.dateFontSizeOfShortSide,
                      maximumWidth: maximumTextWidth,
                      maximumLines: 1,
                      fontWeight: FontWeight.w500,
                      textAlign: TextAlign.left,
                    ),
                    SizedBox(
                      height:
                          shortSide *
                          WatermarkLayout.dateBottomSpacingOfShortSide,
                    ),
                    _WatermarkText(
                      text: snapshot.timeText,
                      baseFontSize:
                          shortSide * WatermarkLayout.timeFontSizeOfShortSide,
                      maximumWidth: maximumTextWidth,
                      maximumLines: 1,
                      fontWeight: FontWeight.w600,
                      textAlign: TextAlign.left,
                    ),
                    SizedBox(
                      height:
                          shortSide *
                          WatermarkLayout.timeBottomSpacingOfShortSide,
                    ),
                    _WatermarkLocationRow(
                      text: snapshot.locationText,
                      shortSide: shortSide,
                      maximumWidth: maximumTextWidth,
                    ),
                    SizedBox(
                      height:
                          shortSide *
                          WatermarkLayout.locationBottomSpacingOfShortSide,
                    ),
                    _WatermarkText(
                      text: snapshot.brandText,
                      baseFontSize:
                          shortSide * WatermarkLayout.brandFontSizeOfShortSide,
                      maximumWidth: maximumTextWidth,
                      maximumLines: 1,
                      fontWeight: FontWeight.w500,
                      letterSpacing: 0.4,
                      textAlign: TextAlign.left,
                      color: const Color(0xCCFFFFFF),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _WatermarkLocationRow extends StatelessWidget {
  const _WatermarkLocationRow({
    required this.text,
    required this.shortSide,
    required this.maximumWidth,
  });

  final String text;
  final double shortSide;
  final double maximumWidth;

  @override
  Widget build(BuildContext context) {
    final double baseFontSize =
        shortSide * WatermarkLayout.locationFontSizeOfShortSide;
    final TextStyle baseStyle = _watermarkTextStyle(
      fontSize: baseFontSize,
      fontWeight: FontWeight.w500,
    );
    final TextPainter measurement = TextPainter(
      text: TextSpan(text: text, style: baseStyle),
      textDirection: TextDirection.ltr,
      maxLines: 2,
    )..layout();
    final double rowDecorationWidth =
        baseFontSize *
        (WatermarkLayout.locationPinWidthOfFontSize +
            WatermarkLayout.locationPinGapOfFontSize);
    final double fontSize = _fitFontSize(
      baseFontSize: baseFontSize,
      measuredWidth: measurement.width + rowDecorationWidth,
      maximumWidth: maximumWidth,
    );
    final double locationTextWidth =
        maximumWidth -
        fontSize *
            (WatermarkLayout.locationPinWidthOfFontSize +
                WatermarkLayout.locationPinGapOfFontSize);

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        CustomPaint(
          size: Size(
            fontSize * WatermarkLayout.locationPinWidthOfFontSize,
            fontSize * WatermarkLayout.locationPinHeightOfFontSize,
          ),
          painter: const _LocationPinPainter(),
        ),
        SizedBox(width: fontSize * WatermarkLayout.locationPinGapOfFontSize),
        SizedBox(
          width: locationTextWidth,
          child: _WatermarkText(
            text: text,
            baseFontSize: fontSize,
            maximumWidth: locationTextWidth,
            maximumLines: 2,
            fontWeight: FontWeight.w500,
            textAlign: TextAlign.left,
          ),
        ),
      ],
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
    this.textAlign = TextAlign.center,
    this.color = Colors.white,
  });

  final String text;
  final double baseFontSize;
  final double maximumWidth;
  final int maximumLines;
  final FontWeight fontWeight;
  final double letterSpacing;
  final TextAlign textAlign;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final TextStyle baseStyle = _watermarkTextStyle(
      fontSize: baseFontSize,
      fontWeight: fontWeight,
      letterSpacing: letterSpacing,
      color: color,
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
      textAlign: textAlign,
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.noScaling,
      maxLines: maximumLines,
      softWrap: true,
      overflow: TextOverflow.clip,
      style: _watermarkTextStyle(
        fontSize: fontSize,
        fontWeight: fontWeight,
        letterSpacing: letterSpacing,
        color: color,
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
  Color color = Colors.white,
}) => TextStyle(
  color: color,
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
