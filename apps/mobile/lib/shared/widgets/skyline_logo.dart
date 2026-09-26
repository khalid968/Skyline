import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// Skyline's logo (board 45, "Blue shield S", chosen 2026-09-26). The same
/// drawing as branding/skyline-logo.svg, which the app icons are made from.
class SkylineLogo extends StatelessWidget {
  const SkylineLogo({super.key, this.size = 48});
  final double size;

  static const svg = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 120 120">'
      '<rect width="120" height="120" rx="28" fill="#0C111C"/>'
      '<path d="M60 20L31 32V55C31 75 43 90 60 98C77 90 89 75 89 55V32Z" fill="#3A63D8"/>'
      '<path d="M70 45C67 38 51 38 51 47C51 55 69 54 69 64C69 73 53 75 49 68" fill="none" stroke="#FFFFFF" '
      'stroke-width="8" stroke-linecap="round"/>'
      '<circle cx="78" cy="34" r="4" fill="#E8A33D"/></svg>';

  @override
  Widget build(BuildContext context) =>
      Semantics(label: 'Skyline', image: true, child: SvgPicture.string(svg, width: size, height: size));
}
