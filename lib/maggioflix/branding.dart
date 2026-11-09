import 'package:flutter/material.dart';

/// MaggioFlix neon wordmark (MAGGIO in red, FLIX in cyan) on a transparent background.
///
/// [letterHeight] is the height of the capitals; the widget is a little taller and wider than the
/// letters because the picture keeps room for the glow around the tubes.
class MaggioflixWordmark extends StatelessWidget {
  const MaggioflixWordmark({super.key, this.letterHeight = 22});

  final double letterHeight;

  // assets/maggioflix_logo.png: 539x124 units, of which the capitals take 96.
  static const double _aspectRatio = 539 / 124;
  static const double _glowFactor = 124 / 96;

  @override
  Widget build(BuildContext context) {
    final height = letterHeight * _glowFactor;
    return Image.asset(
      'assets/maggioflix_logo.png',
      height: height,
      width: height * _aspectRatio,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.medium,
      semanticLabel: 'MaggioFlix',
    );
  }
}

/// The red neon M of the app icon, on a transparent background with its glow.
class MaggioflixMark extends StatelessWidget {
  const MaggioflixMark({super.key, this.size = 32});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      'assets/maggioflix_m.png',
      width: size,
      height: size,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.medium,
      semanticLabel: 'MaggioFlix',
    );
  }
}
