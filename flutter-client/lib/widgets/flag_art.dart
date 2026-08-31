import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Country flags drawn as real artwork instead of emoji.
///
/// Windows ships no colour emoji flag glyphs. A regional-indicator pair such as
/// U+1F1E9 U+1F1EA silently degrades to the bare letters "DE", which is exactly
/// what the desktop server list showed. The browser extension already solved
/// this with hand-built SVG bodies (extension/ui/flags.js); this is the same
/// artwork on the same 24x16 grid, expressed as painter primitives so the
/// desktop client, the mobile app and the extension all show one flag set.
///
/// Input is deliberately forgiving: an ISO code ("kz", "KZ"), an English
/// country name ("Kazakhstan"), a flag emoji, or nothing but a city are all
/// accepted, because the control plane sends different shapes in different
/// payloads. Country names are matched in English only - every node record
/// carries `countryCode`, so the name path is just a safety net.
const double _gw = 24;
const double _gh = 16;

const int _white = 0xFFF4F5F7;
const int _pureWhite = 0xFFFFFFFF;

@immutable
abstract class _Op {
  const _Op();
}

/// Full-bleed background.
class _Bg extends _Op {
  const _Bg(this.colour);
  final int colour;
}

/// Full-width horizontal band.
class _Band extends _Op {
  const _Band(this.y, this.h, this.colour);
  final double y;
  final double h;
  final int colour;
}

class _Box extends _Op {
  const _Box(this.x, this.y, this.w, this.h, this.colour);
  final double x;
  final double y;
  final double w;
  final double h;
  final int colour;
}

class _Disc extends _Op {
  const _Disc(this.cx, this.cy, this.r, this.colour, {this.stroke});
  final double cx;
  final double cy;
  final double r;
  final int colour;

  /// Outline width; null fills the disc.
  final double? stroke;
}

class _Stroke extends _Op {
  const _Stroke(this.x1, this.y1, this.x2, this.y2, this.colour, this.width);
  final double x1;
  final double y1;
  final double x2;
  final double y2;
  final int colour;
  final double width;
}

/// Flat list of x,y pairs.
class _Poly extends _Op {
  const _Poly(this.points, this.colour);
  final List<double> points;
  final int colour;
}

class _Star extends _Op {
  const _Star(this.cx, this.cy, this.r, this.colour);
  final double cx;
  final double cy;
  final double r;
  final int colour;
}

// ---------------------------------------------------------------------------
// Builders for the patterns that repeat across dozens of flags
// ---------------------------------------------------------------------------

List<_Op> _h3(int a, int b, int c) => <_Op>[
      _Bg(a),
      _Band(_gh / 3, _gh / 3, b),
      _Band(_gh * 2 / 3, _gh / 3, c),
    ];

List<_Op> _h2(int a, int b) => <_Op>[_Bg(a), _Band(_gh / 2, _gh / 2, b)];

List<_Op> _v3(int a, int b, int c) => <_Op>[
      _Bg(b),
      _Box(0, 0, _gw / 3, _gh, a),
      _Box(_gw * 2 / 3, 0, _gw / 3, _gh, c),
    ];

/// Nordic cross, optionally with a second cross inside it (Norway, Iceland).
List<_Op> _nordic(int bg, int outer, {int? inner}) => <_Op>[
      _Bg(bg),
      _Box(6.4, 0, 4.2, _gh, outer),
      _Band(5.9, 4.2, outer),
      if (inner != null) _Box(7.6, 0, 1.8, _gh, inner),
      if (inner != null) _Band(7.1, 1.8, inner),
    ];

/// Union flag, sized so it can also be used as a canton.
List<_Op> _unionJack(double w, double h) => <_Op>[
      _Box(0, 0, w, h, 0xFF012169),
      _Stroke(0, 0, w, h, _pureWhite, h * 0.40),
      _Stroke(w, 0, 0, h, _pureWhite, h * 0.40),
      _Stroke(0, 0, w, h, 0xFFC8102E, 0.24 * h),
      _Stroke(w, 0, 0, h, 0xFFC8102E, 0.24 * h),
      _Stroke(w / 2, 0, w / 2, h, _pureWhite, h * 0.66),
      _Stroke(0, h / 2, w, h / 2, _pureWhite, h * 0.66),
      _Stroke(w / 2, 0, w / 2, h, 0xFFC8102E, h * 0.40),
      _Stroke(0, h / 2, w, h / 2, 0xFFC8102E, h * 0.40),
    ];

// ---------------------------------------------------------------------------
// The flag set
// ---------------------------------------------------------------------------

final Map<String, List<_Op>> _bodies = <String, List<_Op>>{
  // The first eight match the website's own icon set verbatim in colour.
  'KZ': <_Op>[
    const _Bg(0xFF00AFCA),
    const _Disc(11.4, 7, 2.5, 0xFFFEC50C),
    const _Stroke(11.4, 3.1, 11.4, 4.0, 0xFFFEC50C, 0.7),
    const _Stroke(11.4, 10.0, 11.4, 10.9, 0xFFFEC50C, 0.7),
    const _Stroke(7.5, 7, 8.4, 7, 0xFFFEC50C, 0.7),
    const _Stroke(14.4, 7, 15.3, 7, 0xFFFEC50C, 0.7),
    const _Stroke(8.6, 4.2, 9.25, 4.85, 0xFFFEC50C, 0.7),
    const _Stroke(13.55, 9.15, 14.2, 9.8, 0xFFFEC50C, 0.7),
    const _Stroke(14.2, 4.2, 13.55, 4.85, 0xFFFEC50C, 0.7),
    const _Stroke(9.25, 9.15, 8.6, 9.8, 0xFFFEC50C, 0.7),
    const _Box(1.2, 3, 1.5, 10, 0xFFFEC50C),
  ],
  'DE': <_Op>[
    const _Bg(0xFF111111),
    const _Band(5.33, 5.34, 0xFFDD0000),
    const _Band(10.67, 5.33, 0xFFFFCE00),
  ],
  // ROUND 5: the neighbours were missing, which is why the home screen showed
  // a bare "кг" instead of a flag. Windows has no colour emoji flags, so every
  // country we can plausibly place a user in needs painted art.
  'KG': <_Op>[
    const _Bg(0xFFE8112D),
    const _Disc(12, 8, 3.1, 0xFFFFEF00),
    const _Disc(12, 8, 1.9, 0xFFE8112D, stroke: 0.5),
  ],
  'UZ': <_Op>[
    const _Bg(0xFF0099B5),
    const _Band(5.33, 5.34, _white),
    const _Band(10.67, 5.33, 0xFF1EB53A),
    const _Band(5.1, 0.5, 0xFFCE1126),
    const _Band(10.4, 0.5, 0xFFCE1126),
    const _Disc(4.4, 2.7, 1.2, _white),
    const _Disc(5.2, 2.7, 1.2, 0xFF0099B5),
  ],
  'TJ': <_Op>[
    const _Bg(0xFFCC0000),
    const _Band(4.6, 6.8, _white),
    const _Band(11.4, 4.6, 0xFF006600),
    const _Disc(12, 8, 1.0, 0xFFF8C300),
  ],
  'TM': <_Op>[
    const _Bg(0xFF00843D),
    const _Box(4.4, 0, 2.6, _gh, 0xFFD22630),
    const _Disc(12.6, 4.6, 1.1, _white),
    const _Disc(13.4, 4.6, 1.1, 0xFF00843D),
  ],
  'AZ': _h3(0xFF00B5E2, 0xFFEF3340, 0xFF509E2F),
  'FR': _v3(0xFF0B3E9C, _white, 0xFFE1273B),
  'US': <_Op>[
    const _Bg(_white),
    for (int i = 0; i < 7; i++) _Band(i * 2.46, 1.23, 0xFFD02F44),
    const _Box(0, 0, 10.4, 8.6, 0xFF2A3560),
    for (int row = 0; row < 4; row++)
      for (int col = 0; col < 3; col++)
        _Disc(
          1.9 + (col * 2.7) + (row.isOdd ? 1.3 : 0),
          1.7 + (row * 1.87),
          0.6,
          _pureWhite,
        ),
  ],
  'NL': <_Op>[
    const _Bg(_white),
    const _Band(0, 5.33, 0xFFC8102E),
    const _Band(10.67, 5.33, 0xFF1E4785),
  ],
  'TR': <_Op>[
    const _Bg(0xFFE30A17),
    const _Disc(9.4, 8, 4, _pureWhite),
    const _Disc(10.9, 8, 3.2, 0xFFE30A17),
    const _Star(14.6, 8, 2.0, _pureWhite),
  ],
  'SG': <_Op>[
    const _Bg(_white),
    const _Band(0, 8, 0xFFEF3340),
    const _Disc(6.2, 4, 2.9, _pureWhite),
    const _Disc(7.7, 4, 2.6, 0xFFEF3340),
    const _Disc(9.9, 2.1, 0.5, _pureWhite),
    const _Disc(12.1, 2.1, 0.5, _pureWhite),
    const _Disc(11, 3.6, 0.5, _pureWhite),
    const _Disc(9.3, 4.6, 0.5, _pureWhite),
    const _Disc(12.7, 4.6, 0.5, _pureWhite),
  ],
  'JP': <_Op>[
    const _Bg(_white),
    const _Disc(12, 8, 4.6, 0xFFBC002D),
  ],

  // Same grid, same flat style.
  'GB': _unionJack(_gw, _gh),
  'PL': _h2(_white, 0xFFDC143C),
  'SE': <_Op>[
    const _Bg(0xFF006AA7),
    const _Box(7, 0, 3, _gh, 0xFFFECC00),
    const _Band(6.5, 3, 0xFFFECC00),
  ],
  'FI': _nordic(_white, 0xFF003580),
  'NO': _nordic(0xFFBA0C2F, _pureWhite, inner: 0xFF00205B),
  'DK': <_Op>[
    const _Bg(0xFFC8102E),
    const _Box(7, 0, 3, _gh, _pureWhite),
    const _Band(6.5, 3, _pureWhite),
  ],
  'IS': _nordic(0xFF02529C, _pureWhite, inner: 0xFFDC1E35),
  'CH': <_Op>[
    const _Bg(0xFFD52B1E),
    const _Box(10.6, 4, 2.8, 8, _pureWhite),
    const _Box(8, 6.6, 8, 2.8, _pureWhite),
  ],
  'IT': _v3(0xFF008C45, _white, 0xFFCD212A),
  'ES': <_Op>[
    const _Bg(0xFFAA151B),
    const _Band(4, 8, 0xFFF1BF00),
  ],
  'PT': <_Op>[
    const _Bg(0xFFDA291C),
    const _Box(0, 0, 9.6, _gh, 0xFF046A38),
    const _Disc(9.6, 8, 3.1, 0xFFFFE900),
    const _Disc(9.6, 8, 3.1, 0xFFDA291C, stroke: 0.6),
  ],
  'IE': _v3(0xFF169B62, _white, 0xFFFF883E),
  'AT': <_Op>[
    const _Bg(_white),
    const _Band(0, 5.33, 0xFFED2939),
    const _Band(10.67, 5.33, 0xFFED2939),
  ],
  'CZ': <_Op>[
    const _Bg(_white),
    const _Band(8, 8, 0xFFD7141A),
    const _Poly(<double>[0, 0, 11, 8, 0, 16], 0xFF11457E),
  ],
  'RO': _v3(0xFF002B7F, 0xFFFCD116, 0xFFCE1126),
  'HU': _h3(_white, 0xFFCD2A3E, 0xFF436F4D),
  'BG': _h3(_white, 0xFF00966E, 0xFFD62612),
  'GR': <_Op>[
    const _Bg(_white),
    for (int i = 0; i < 5; i++) _Band(i * 3.56, 1.78, 0xFF0D5EAF),
    const _Box(0, 0, 8.9, 8.9, 0xFF0D5EAF),
    const _Box(3.7, 0, 1.5, 8.9, _pureWhite),
    const _Box(0, 3.7, 8.9, 1.5, _pureWhite),
  ],
  'HR': _h3(_white, 0xFFFF0000, 0xFF171796),
  'RS': _h3(_white, 0xFFC6363C, 0xFF0C4076),
  'SK': _h3(_white, 0xFF0B4EA2, 0xFFEE1C25),
  'SI': _h3(_white, 0xFF0000AA, 0xFFD50000),
  'LT': _h3(0xFFFDB913, 0xFF006A44, 0xFFC1272D),
  'LV': <_Op>[
    const _Bg(0xFF9E3039),
    const _Band(6.6, 2.8, _pureWhite),
  ],
  'EE': _h3(0xFF0072CE, 0xFF000000, _white),
  'UA': _h2(0xFF0057B7, 0xFFFFD700),
  'BY': <_Op>[
    const _Bg(0xFF4AA657),
    const _Band(0, 10.4, 0xFFC8313E),
    const _Box(0, 0, 4.4, _gh, _pureWhite),
    const _Poly(<double>[1.1, 1.6, 2.2, 3.2, 1.1, 4.8, 0, 3.2], 0xFFC8313E),
    const _Poly(<double>[3.3, 6.4, 4.4, 8.0, 3.3, 9.6, 2.2, 8.0], 0xFFC8313E),
    const _Poly(<double>[1.1, 11.2, 2.2, 12.8, 1.1, 14.4, 0, 12.8], 0xFFC8313E),
  ],
  'RU': _h3(_white, 0xFF0039A6, 0xFFD52B1E),
  'MD': _v3(0xFF0046AE, 0xFFFFD200, 0xFFCC092F),
  'GE': <_Op>[
    const _Bg(_white),
    const _Box(10.2, 0, 3.6, _gh, 0xFFFF0000),
    const _Band(6.2, 3.6, 0xFFFF0000),
    const _Box(4, 2.4, 2.4, 0.9, 0xFFFF0000),
    const _Box(4.75, 1.65, 0.9, 2.4, 0xFFFF0000),
    const _Box(17.6, 2.4, 2.4, 0.9, 0xFFFF0000),
    const _Box(18.35, 1.65, 0.9, 2.4, 0xFFFF0000),
    const _Box(4, 12.7, 2.4, 0.9, 0xFFFF0000),
    const _Box(4.75, 11.95, 0.9, 2.4, 0xFFFF0000),
    const _Box(17.6, 12.7, 2.4, 0.9, 0xFFFF0000),
    const _Box(18.35, 11.95, 0.9, 2.4, 0xFFFF0000),
  ],
  'AM': _h3(0xFFD90012, 0xFF0033A0, 0xFFF2A800),
  'AZ': <_Op>[
    const _Bg(0xFF509E2F),
    const _Band(0, 5.33, 0xFF00B5E2),
    const _Band(5.33, 5.34, 0xFFEF3340),
    const _Disc(11.4, 8, 2.1, _pureWhite),
    const _Disc(12.2, 8, 1.7, 0xFFEF3340),
  ],
  'KG': <_Op>[
    const _Bg(0xFFE8112D),
    const _Disc(12, 8, 3.4, 0xFFFFEF00, stroke: 1.1),
    const _Disc(12, 8, 1.5, 0xFFFFEF00),
  ],
  'UZ': <_Op>[
    const _Bg(_white),
    const _Band(0, 5, 0xFF0099B5),
    const _Band(11, 5, 0xFF1EB53A),
    const _Disc(4.6, 2.5, 1.6, _pureWhite),
    const _Disc(5.4, 2.5, 1.4, 0xFF0099B5),
  ],
  'TJ': _h3(_white, 0xFFCC0000, 0xFF006600),
  'TM': <_Op>[
    const _Bg(0xFF28AE66),
    const _Box(3.4, 0, 3, _gh, 0xFFD22630),
  ],
  'AE': <_Op>[
    const _Bg(_white),
    const _Band(0, 5.33, 0xFF00732F),
    const _Band(10.67, 5.33, 0xFF000000),
    const _Box(0, 0, 6.4, _gh, 0xFFFF0000),
  ],
  'SA': <_Op>[
    const _Bg(0xFF006C35),
    const _Box(4, 7, 16, 0.8, _pureWhite),
    const _Box(4, 9.6, 12, 0.7, _pureWhite),
  ],
  'IL': <_Op>[
    const _Bg(_white),
    const _Band(1.6, 2, 0xFF0038B8),
    const _Band(12.4, 2, 0xFF0038B8),
    const _Stroke(12, 4.6, 14.9, 9.6, 0xFF0038B8, 0.85),
    const _Stroke(14.9, 9.6, 9.1, 9.6, 0xFF0038B8, 0.85),
    const _Stroke(9.1, 9.6, 12, 4.6, 0xFF0038B8, 0.85),
    const _Stroke(12, 11.4, 9.1, 6.4, 0xFF0038B8, 0.85),
    const _Stroke(9.1, 6.4, 14.9, 6.4, 0xFF0038B8, 0.85),
    const _Stroke(14.9, 6.4, 12, 11.4, 0xFF0038B8, 0.85),
  ],
  'EG': <_Op>[
    const _Bg(_white),
    const _Band(0, 5.33, 0xFFCE1126),
    const _Band(10.67, 5.33, 0xFF000000),
    const _Disc(12, 8, 1.7, 0xFFC09300),
  ],
  'ZA': <_Op>[
    const _Bg(0xFF002395),
    const _Band(0, 8, 0xFFDE3831),
    const _Poly(<double>[0, 0, 9, 8, 0, 16], 0xFF007A4D),
    const _Poly(<double>[0, 2.2, 6.6, 8, 0, 13.8], 0xFFFFB612),
    const _Poly(<double>[0, 4.4, 4.2, 8, 0, 11.6], 0xFF000000),
  ],
  'IN': <_Op>[
    const _Bg(_white),
    const _Band(0, 5.33, 0xFFFF9933),
    const _Band(10.67, 5.33, 0xFF138808),
    const _Disc(12, 8, 2, 0xFF000080, stroke: 0.65),
    const _Disc(12, 8, 0.5, 0xFF000080),
  ],
  'CN': <_Op>[
    const _Bg(0xFFDE2910),
    const _Star(4.4, 5.2, 3.0, 0xFFFFDE00),
    const _Disc(9.2, 2.0, 0.6, 0xFFFFDE00),
    const _Disc(11.0, 3.6, 0.6, 0xFFFFDE00),
    const _Disc(11.0, 5.9, 0.6, 0xFFFFDE00),
    const _Disc(9.2, 7.5, 0.6, 0xFFFFDE00),
  ],
  'HK': <_Op>[
    const _Bg(0xFFDE2910),
    const _Disc(12, 8, 3.2, _pureWhite),
    const _Disc(12, 8, 1.5, 0xFFDE2910),
  ],
  'TW': <_Op>[
    const _Bg(0xFFFE0000),
    const _Box(0, 0, 12, 8, 0xFF000095),
    const _Disc(6, 4, 2.2, _pureWhite),
  ],
  'KR': <_Op>[
    const _Bg(_white),
    const _Disc(12, 8, 3.4, 0xFFCD2E3A),
    const _Disc(10.3, 8, 1.7, 0xFF0047A0),
    const _Stroke(3.6, 4.2, 5.3, 6.6, 0xFF000000, 0.55),
    const _Stroke(5.0, 3.2, 6.7, 5.6, 0xFF000000, 0.55),
    const _Stroke(20.4, 11.8, 18.7, 9.4, 0xFF000000, 0.55),
    const _Stroke(19.0, 12.8, 17.3, 10.4, 0xFF000000, 0.55),
  ],
  'JP_ALT': <_Op>[const _Bg(_white)],
  'TH': <_Op>[
    const _Bg(_white),
    const _Band(0, 2.7, 0xFFA51931),
    const _Band(13.3, 2.7, 0xFFA51931),
    const _Band(5.3, 5.4, 0xFF2D2A4A),
  ],
  'VN': <_Op>[
    const _Bg(0xFFDA251D),
    const _Star(12, 8, 3.6, 0xFFFFFF00),
  ],
  'ID': _h2(0xFFCE1126, _white),
  'MY': <_Op>[
    const _Bg(_white),
    for (int i = 0; i < 7; i++) _Band(i * 2.28, 1.14, 0xFFCC0001),
    const _Box(0, 0, 12, 9.14, 0xFF010066),
    const _Disc(5.4, 4.6, 2.5, 0xFFFFCC00),
    const _Disc(6.6, 4.6, 2.1, 0xFF010066),
    const _Star(9.6, 4.6, 1.6, 0xFFFFCC00),
  ],
  'PH': <_Op>[
    const _Bg(0xFFCE1126),
    const _Band(0, 8, 0xFF0038A8),
    const _Poly(<double>[0, 0, 9, 8, 0, 16], _pureWhite),
    const _Disc(3.0, 8, 1.2, 0xFFFCD116),
  ],
  'AU': <_Op>[
    const _Bg(0xFF012169),
    ..._unionJack(11, 8),
    const _Star(17.0, 10.4, 1.5, _pureWhite),
    const _Star(19.6, 4.4, 1.0, _pureWhite),
    const _Star(20.8, 8.4, 1.0, _pureWhite),
    const _Star(17.4, 5.6, 0.8, _pureWhite),
    const _Star(19.6, 12.4, 0.8, _pureWhite),
  ],
  'NZ': <_Op>[
    const _Bg(0xFF012169),
    ..._unionJack(11, 8),
    const _Disc(19.4, 4.4, 0.8, 0xFFC8102E),
    const _Disc(20.9, 8.0, 0.8, 0xFFC8102E),
    const _Disc(17.6, 8.6, 0.8, 0xFFC8102E),
    const _Disc(19.4, 12.0, 0.8, 0xFFC8102E),
  ],
  'CA': <_Op>[
    const _Bg(_white),
    const _Box(0, 0, 6, _gh, 0xFFD80621),
    const _Box(18, 0, 6, _gh, 0xFFD80621),
    const _Poly(
      <double>[
        12, 3.4, 13, 5.8, 14.9, 4.9, 14.2, 7.2, 16.3, 7.5, 14.6, 8.9, 15.2,
        10.2, 13, 9.8, 13.1, 12.4, 10.9, 12.4, 11, 9.8, 8.8, 10.2, 9.4, 8.9,
        7.7, 7.5, 9.8, 7.2, 9.1, 4.9, 11, 5.8,
      ],
      0xFFD80621,
    ),
  ],
  'MX': <_Op>[
    ..._v3(0xFF006847, _white, 0xFFCE1126),
    const _Disc(12, 8, 1.9, 0xFF8C6239, stroke: 0.7),
  ],
  'BR': <_Op>[
    const _Bg(0xFF009B3A),
    const _Poly(<double>[12, 1.9, 21.4, 8, 12, 14.1, 2.6, 8], 0xFFFEDF00),
    const _Disc(12, 8, 3.1, 0xFF002776),
    const _Stroke(9.1, 7.1, 15.0, 8.7, _pureWhite, 0.75),
  ],
  'AR': <_Op>[
    const _Bg(_white),
    const _Band(0, 5.33, 0xFF74ACDF),
    const _Band(10.67, 5.33, 0xFF74ACDF),
    const _Disc(12, 8, 1.6, 0xFFF6B40E),
  ],
  'CL': <_Op>[
    const _Bg(_white),
    const _Band(8, 8, 0xFFD52B1E),
    const _Box(0, 0, 8, 8, 0xFF0039A6),
    const _Star(4, 4, 2.6, _pureWhite),
  ],
  'CO': <_Op>[
    const _Bg(0xFFFCD116),
    const _Band(8, 4, 0xFF003893),
    const _Band(12, 4, 0xFFCE1126),
  ],
  'PE': <_Op>[
    const _Bg(_white),
    const _Box(0, 0, 8, _gh, 0xFFD91023),
    const _Box(16, 0, 8, _gh, 0xFFD91023),
  ],
};

/// Neutral placeholder: a violet wire globe, same as the extension.
final List<_Op> _globe = <_Op>[
  const _Bg(0xFF1B1626),
  const _Disc(12, 8, 5, 0xFF8B7CF6, stroke: 1.1),
  const _Stroke(7, 8, 17, 8, 0xFF8B7CF6, 1.1),
  const _Disc(12, 8, 2.2, 0xFF8B7CF6, stroke: 1.0),
];

/// English country names, because `country` is a display string in some
/// payloads and a code in others.
const Map<String, String> _names = <String, String>{
  'kazakhstan': 'KZ',
  'qazaqstan': 'KZ',
  'germany': 'DE',
  'deutschland': 'DE',
  'france': 'FR',
  'united states': 'US',
  'united states of america': 'US',
  'usa': 'US',
  'netherlands': 'NL',
  'holland': 'NL',
  'turkey': 'TR',
  'turkiye': 'TR',
  'singapore': 'SG',
  'japan': 'JP',
  'united kingdom': 'GB',
  'great britain': 'GB',
  'britain': 'GB',
  'england': 'GB',
  'uk': 'GB',
  'poland': 'PL',
  'sweden': 'SE',
  'finland': 'FI',
  'norway': 'NO',
  'denmark': 'DK',
  'iceland': 'IS',
  'switzerland': 'CH',
  'italy': 'IT',
  'spain': 'ES',
  'portugal': 'PT',
  'ireland': 'IE',
  'austria': 'AT',
  'czechia': 'CZ',
  'czech republic': 'CZ',
  'romania': 'RO',
  'hungary': 'HU',
  'bulgaria': 'BG',
  'greece': 'GR',
  'croatia': 'HR',
  'serbia': 'RS',
  'slovakia': 'SK',
  'slovenia': 'SI',
  'lithuania': 'LT',
  'latvia': 'LV',
  'estonia': 'EE',
  'ukraine': 'UA',
  'belarus': 'BY',
  'russia': 'RU',
  'russian federation': 'RU',
  'moldova': 'MD',
  'georgia': 'GE',
  'armenia': 'AM',
  'azerbaijan': 'AZ',
  'kyrgyzstan': 'KG',
  'kyrgyz republic': 'KG',
  'uzbekistan': 'UZ',
  'tajikistan': 'TJ',
  'turkmenistan': 'TM',
  'united arab emirates': 'AE',
  'uae': 'AE',
  'saudi arabia': 'SA',
  'israel': 'IL',
  'egypt': 'EG',
  'south africa': 'ZA',
  'india': 'IN',
  'china': 'CN',
  'hong kong': 'HK',
  'taiwan': 'TW',
  'south korea': 'KR',
  'korea': 'KR',
  'republic of korea': 'KR',
  'thailand': 'TH',
  'vietnam': 'VN',
  'indonesia': 'ID',
  'malaysia': 'MY',
  'philippines': 'PH',
  'australia': 'AU',
  'new zealand': 'NZ',
  'canada': 'CA',
  'mexico': 'MX',
  'brazil': 'BR',
  'argentina': 'AR',
  'chile': 'CL',
  'colombia': 'CO',
  'peru': 'PE',
};

/// Some payloads only carry a city. A correct flag beats a grey globe.
const Map<String, String> _cities = <String, String>{
  'frankfurt': 'DE',
  'berlin': 'DE',
  'munich': 'DE',
  'falkenstein': 'DE',
  'nuremberg': 'DE',
  'paris': 'FR',
  'amsterdam': 'NL',
  'london': 'GB',
  'new york': 'US',
  'ashburn': 'US',
  'los angeles': 'US',
  'chicago': 'US',
  'dallas': 'US',
  'miami': 'US',
  'seattle': 'US',
  'istanbul': 'TR',
  'singapore': 'SG',
  'tokyo': 'JP',
  'osaka': 'JP',
  'almaty': 'KZ',
  'astana': 'KZ',
  'nur-sultan': 'KZ',
  'qyzylorda': 'KZ',
  'kyzylorda': 'KZ',
  'shymkent': 'KZ',
  'aqtobe': 'KZ',
  'karaganda': 'KZ',
  'warsaw': 'PL',
  'stockholm': 'SE',
  'helsinki': 'FI',
  'oslo': 'NO',
  'copenhagen': 'DK',
  'reykjavik': 'IS',
  'zurich': 'CH',
  'geneva': 'CH',
  'vienna': 'AT',
  'prague': 'CZ',
  'milan': 'IT',
  'rome': 'IT',
  'madrid': 'ES',
  'lisbon': 'PT',
  'dublin': 'IE',
  'bucharest': 'RO',
  'budapest': 'HU',
  'sofia': 'BG',
  'athens': 'GR',
  'zagreb': 'HR',
  'belgrade': 'RS',
  'bratislava': 'SK',
  'ljubljana': 'SI',
  'vilnius': 'LT',
  'riga': 'LV',
  'tallinn': 'EE',
  'kyiv': 'UA',
  'kiev': 'UA',
  'minsk': 'BY',
  'moscow': 'RU',
  'saint petersburg': 'RU',
  'tbilisi': 'GE',
  'yerevan': 'AM',
  'baku': 'AZ',
  'bishkek': 'KG',
  'osh': 'KG',
  'tashkent': 'UZ',
  'dushanbe': 'TJ',
  'ashgabat': 'TM',
  'dubai': 'AE',
  'tel aviv': 'IL',
  'cairo': 'EG',
  'johannesburg': 'ZA',
  'mumbai': 'IN',
  'delhi': 'IN',
  'bangalore': 'IN',
  'seoul': 'KR',
  'bangkok': 'TH',
  'hanoi': 'VN',
  'jakarta': 'ID',
  'kuala lumpur': 'MY',
  'manila': 'PH',
  'sydney': 'AU',
  'melbourne': 'AU',
  'auckland': 'NZ',
  'toronto': 'CA',
  'montreal': 'CA',
  'mexico city': 'MX',
  'sao paulo': 'BR',
  'buenos aires': 'AR',
  'santiago': 'CL',
  'bogota': 'CO',
  'lima': 'PE',
};

/// Accepts a code, an English country name, a flag emoji or a node's country
/// field; returns a two-letter code that [FlagArt] can draw, or null.
String? resolveCountryCode(String? raw, {String? city}) {
  final String value = (raw ?? '').trim();

  if (value.isNotEmpty) {
    final String? fromEmoji = _decodeEmojiFlag(value);
    if (fromEmoji != null && _bodies.containsKey(fromEmoji)) return fromEmoji;

    if (value.length == 2) {
      final String upper = value.toUpperCase();
      if (_bodies.containsKey(upper)) return upper;
    }

    final String? byName = _names[value.toLowerCase()];
    if (byName != null) return byName;
  }

  final String cityKey = (city ?? '').trim().toLowerCase();
  if (cityKey.isNotEmpty) {
    final String? byCity = _cities[cityKey];
    if (byCity != null) return byCity;
  }

  return null;
}

/// Turns a regional-indicator pair back into letters, so every existing call
/// site that already passes `countryFlag(code)` keeps working unchanged.
String? _decodeEmojiFlag(String value) {
  final List<int> runes = value.runes.toList();
  if (runes.length < 2) return null;
  const int base = 0x1F1E6;
  final int first = runes[0];
  final int second = runes[1];
  if (first < base || first > base + 25) return null;
  if (second < base || second > base + 25) return null;
  return String.fromCharCodes(<int>[65 + first - base, 65 + second - base]);
}

bool hasFlagArt(String? raw, {String? city}) {
  final String? code = resolveCountryCode(raw, city: city);
  return code != null && _bodies.containsKey(code);
}

enum FlagShape {
  /// Round badge, as used in the server list and the tray panel.
  circle,

  /// 3:2 rounded rectangle, as in the approved desktop mockup.
  rounded,
}

class FlagArt extends StatelessWidget {
  const FlagArt({
    super.key,
    required this.code,
    this.city,
    this.size = 26,
    this.shape = FlagShape.circle,
  });

  /// Country code, English name or flag emoji.
  final String? code;

  /// Optional city, used only when [code] resolves to nothing.
  final String? city;

  /// Height of the artwork. Circles are [size] wide, rectangles 1.5x wider.
  final double size;

  final FlagShape shape;

  @override
  Widget build(BuildContext context) {
    final String? resolved = resolveCountryCode(code, city: city);
    final List<_Op> ops =
        (resolved == null ? null : _bodies[resolved]) ?? _globe;

    final bool circle = shape == FlagShape.circle;
    final double width = circle ? size : size * 1.5;
    final BorderRadius radius = BorderRadius.circular(size * 0.24);

    final Widget art = SizedBox(
      width: width,
      height: size,
      child: CustomPaint(painter: _FlagPainter(ops)),
    );

    return DecoratedBox(
      position: DecorationPosition.foreground,
      decoration: BoxDecoration(
        shape: circle ? BoxShape.circle : BoxShape.rectangle,
        borderRadius: circle ? null : radius,
        border: Border.all(color: const Color(0x1FFFFFFF), width: 0.7),
      ),
      child: circle
          ? ClipOval(child: art)
          : ClipRRect(borderRadius: radius, child: art),
    );
  }
}

class _FlagPainter extends CustomPainter {
  const _FlagPainter(this.ops);

  final List<_Op> ops;

  @override
  void paint(Canvas canvas, Size size) {
    // Cover-fit and centre, so circles stay round inside a round badge.
    final double scale = math.max(size.width / _gw, size.height / _gh);
    canvas.save();
    canvas.translate(
      (size.width - (_gw * scale)) / 2,
      (size.height - (_gh * scale)) / 2,
    );
    canvas.scale(scale);

    final Paint paint = Paint()..isAntiAlias = true;

    for (final _Op op in ops) {
      if (op is _Bg) {
        paint
          ..style = PaintingStyle.fill
          ..color = Color(op.colour);
        canvas.drawRect(const Rect.fromLTWH(0, 0, _gw, _gh), paint);
      } else if (op is _Band) {
        paint
          ..style = PaintingStyle.fill
          ..color = Color(op.colour);
        canvas.drawRect(Rect.fromLTWH(0, op.y, _gw, op.h), paint);
      } else if (op is _Box) {
        paint
          ..style = PaintingStyle.fill
          ..color = Color(op.colour);
        canvas.drawRect(Rect.fromLTWH(op.x, op.y, op.w, op.h), paint);
      } else if (op is _Disc) {
        paint.color = Color(op.colour);
        if (op.stroke == null) {
          paint.style = PaintingStyle.fill;
        } else {
          paint
            ..style = PaintingStyle.stroke
            ..strokeWidth = op.stroke!;
        }
        canvas.drawCircle(Offset(op.cx, op.cy), op.r, paint);
      } else if (op is _Stroke) {
        paint
          ..style = PaintingStyle.stroke
          ..strokeWidth = op.width
          ..strokeCap = StrokeCap.butt
          ..color = Color(op.colour);
        canvas.drawLine(
          Offset(op.x1, op.y1),
          Offset(op.x2, op.y2),
          paint,
        );
      } else if (op is _Poly) {
        paint
          ..style = PaintingStyle.fill
          ..color = Color(op.colour);
        final Path path = Path();
        for (int i = 0; i + 1 < op.points.length; i += 2) {
          if (i == 0) {
            path.moveTo(op.points[0], op.points[1]);
          } else {
            path.lineTo(op.points[i], op.points[i + 1]);
          }
        }
        path.close();
        canvas.drawPath(path, paint);
      } else if (op is _Star) {
        paint
          ..style = PaintingStyle.fill
          ..color = Color(op.colour);
        canvas.drawPath(_starPath(op.cx, op.cy, op.r), paint);
      }
    }

    canvas.restore();
  }

  static Path _starPath(double cx, double cy, double r) {
    final Path path = Path();
    const int points = 5;
    for (int i = 0; i < points; i++) {
      final double outer = (-math.pi / 2) + (i * 2 * math.pi / points);
      final double inner = outer + (math.pi / points);
      final double ox = cx + (r * math.cos(outer));
      final double oy = cy + (r * math.sin(outer));
      final double ix = cx + (r * 0.42 * math.cos(inner));
      final double iy = cy + (r * 0.42 * math.sin(inner));
      if (i == 0) {
        path.moveTo(ox, oy);
      } else {
        path.lineTo(ox, oy);
      }
      path.lineTo(ix, iy);
    }
    path.close();
    return path;
  }

  @override
  bool shouldRepaint(covariant _FlagPainter oldDelegate) =>
      !identical(oldDelegate.ops, ops);
}
