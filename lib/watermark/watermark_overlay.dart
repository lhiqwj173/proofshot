import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'watermark_snapshot.dart';

/// Normalized positions and sizes shared with the native media renderer.
abstract final class WatermarkLayout {
  static const double horizontalInsetOfShortSide = 0.02;
  static const double bottomInsetOfShortSide = 0.02;
  static const double timeFontSizeOfShortSide = 0.054;
  static const double detailFontSizeOfShortSide = 0.022;
  static const double locationFontSizeOfShortSide = 0.0215;
  static const double customFontSizeOfShortSide = 0.020;
  static const double dividerWidthOfShortSide = 0.0015;
  static const double dividerHeightOfShortSide = 0.043;
  static const double dividerLeadingSpaceOfShortSide = 0.010;
  static const double dividerTrailingSpaceOfShortSide = 0.012;
  static const double detailLineSpacingOfShortSide = 0.0025;
  static const double timeLocationSpacingOfShortSide = 0.013;
  static const double customBottomSpacingOfShortSide = 0.005;
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
        final double inset =
            shortSide * WatermarkLayout.horizontalInsetOfShortSide;
        final double maximumTextWidth = canvasSize.width - (inset * 2);

        return IgnorePointer(
          child: Stack(
            clipBehavior: Clip.none,
            children: <Widget>[
              Positioned(
                left: inset,
                right: inset,
                bottom: shortSide * WatermarkLayout.bottomInsetOfShortSide,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Expanded(
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
                                  WatermarkLayout
                                      .customBottomSpacingOfShortSide,
                            ),
                          ],
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: <Widget>[
                              _WatermarkText(
                                text: snapshot.timeText,
                                baseFontSize:
                                    shortSide *
                                    WatermarkLayout.timeFontSizeOfShortSide,
                                maximumWidth: maximumTextWidth,
                                maximumLines: 1,
                                fontWeight: FontWeight.w700,
                                textAlign: TextAlign.left,
                              ),
                              SizedBox(
                                width:
                                    shortSide *
                                    WatermarkLayout
                                        .dividerLeadingSpaceOfShortSide,
                              ),
                              Container(
                                width:
                                    shortSide *
                                    WatermarkLayout.dividerWidthOfShortSide,
                                height:
                                    shortSide *
                                    WatermarkLayout.dividerHeightOfShortSide,
                                color: const Color(0xFFE5C84B),
                              ),
                              SizedBox(
                                width:
                                    shortSide *
                                    WatermarkLayout
                                        .dividerTrailingSpaceOfShortSide,
                              ),
                              Expanded(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: <Widget>[
                                    _WatermarkText(
                                      text: snapshot.dateText.replaceAll(
                                        '.',
                                        '-',
                                      ),
                                      baseFontSize:
                                          shortSide *
                                          WatermarkLayout
                                              .detailFontSizeOfShortSide,
                                      maximumWidth: maximumTextWidth,
                                      maximumLines: 1,
                                      fontWeight: FontWeight.w500,
                                      textAlign: TextAlign.left,
                                    ),
                                    SizedBox(
                                      height:
                                          shortSide *
                                          WatermarkLayout
                                              .detailLineSpacingOfShortSide,
                                    ),
                                    _WatermarkText(
                                      text: snapshot.weekdayText,
                                      baseFontSize:
                                          shortSide *
                                          WatermarkLayout
                                              .detailFontSizeOfShortSide,
                                      maximumWidth: maximumTextWidth,
                                      maximumLines: 1,
                                      fontWeight: FontWeight.w500,
                                      textAlign: TextAlign.left,
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          SizedBox(
                            height:
                                shortSide *
                                WatermarkLayout.timeLocationSpacingOfShortSide,
                          ),
                          _WatermarkText(
                            text: snapshot.locationText,
                            baseFontSize:
                                shortSide *
                                WatermarkLayout.locationFontSizeOfShortSide,
                            maximumWidth: maximumTextWidth,
                            maximumLines: 2,
                            fontWeight: FontWeight.w500,
                            textAlign: TextAlign.left,
                          ),
                        ],
                      ),
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

class _WatermarkText extends StatelessWidget {
  const _WatermarkText({
    required this.text,
    required this.baseFontSize,
    required this.maximumWidth,
    required this.maximumLines,
    required this.fontWeight,
    this.textAlign = TextAlign.center,
  });

  final String text;
  final double baseFontSize;
  final double maximumWidth;
  final int maximumLines;
  final FontWeight fontWeight;
  final TextAlign textAlign;

  @override
  Widget build(BuildContext context) {
    final TextStyle baseStyle = _watermarkTextStyle(
      fontSize: baseFontSize,
      fontWeight: fontWeight,
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
      style: _watermarkTextStyle(fontSize: fontSize, fontWeight: fontWeight),
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
}) => TextStyle(
  color: Colors.white,
  fontSize: fontSize,
  fontWeight: fontWeight,
  height: 1.0,
  shadows: const <Shadow>[
    Shadow(color: Color(0xB3000000), offset: Offset(0, 1), blurRadius: 2),
  ],
);
