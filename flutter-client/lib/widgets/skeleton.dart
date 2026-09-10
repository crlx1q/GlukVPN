import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// Placeholder widths, in characters.
///
/// A skeleton is not a preview of the value, it is "this cell is busy". Sizing
/// every bar to the string it replaces turned a loading screen into a bar
/// chart of string lengths: a 15-character IP next to a 5-character ping read
/// as if the ping mattered less, and the four cells of the stats grid looked
/// like four different kinds of waiting. One width per role instead - the
/// cells themselves keep their own widths, so nothing moves when the values
/// land.
class GlukSkeleton {
  GlukSkeleton._();

  /// Any single value: an IP, a ping, a duration, a byte counter.
  static const int valueChars = 10;

  /// The title line of a list row - a server name, a place.
  static const int titleChars = 16;

  /// The muted line under such a title.
  static const int subtitleChars = 22;
}

/// Shimmering placeholder for a value that is still loading.
///
/// One skeleton for every platform: the phone, the Windows desktop and the
/// stats cards all draw the same soft bar while an IP, a ping or a byte count
/// is on its way. It replaces the old "—" dashes and stale values: a dash tells
/// the user nothing, and an old IP shown while the new one loads reads as a
/// leak.
///
/// Rules baked in:
///  * never animate when [animate] is false (reduce-motion, battery saver);
///  * placeholders of the same role share one width - see [GlukSkeleton];
///  * the sweep is seamless: it begins and ends with the bar fully dim, so
///    the loop closes on itself instead of jumping;
///  * the highlight sweeps once every 1.4 s - visible, never distracting.
class SkeletonBox extends StatefulWidget {
  const SkeletonBox({
    super.key,
    required this.width,
    required this.height,
    this.radius = 6,
    this.animate = true,
  });

  final double width;
  final double height;
  final double radius;
  final bool animate;

  @override
  State<SkeletonBox> createState() => _SkeletonBoxState();
}

class _SkeletonBoxState extends State<SkeletonBox>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(covariant SkeletonBox oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animate != widget.animate) _sync();
  }

  void _sync() {
    if (widget.animate) {
      if (!_controller.isAnimating) _controller.repeat();
    } else {
      _controller.stop();
      // Half-way through the travel below is the middle of the bar, so a
      // still skeleton still reads as lit rather than as an empty slot.
      _controller.value = 0.5;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'loading',
      child: AnimatedBuilder(
        animation: _controller,
        builder: (BuildContext context, Widget? child) {
          // The gradient is exactly one bar wide and centred on t, so the bar
          // is uniformly dim at t = -2 and again at t = +2. Travelling between
          // those two points makes the last frame identical to the first and
          // the loop closes silently. It used to start at t = -1, where the
          // left half of the bar is already lit while the end of the previous
          // pass was dark - that mismatch was the visible pop every 1.4 s.
          final double t = _controller.value * 4 - 2;
          return Container(
            width: widget.width,
            height: widget.height,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(widget.radius),
              gradient: LinearGradient(
                begin: Alignment(t - 1, 0),
                end: Alignment(t + 1, 0),
                colors: <Color>[
                  Colors.white.withOpacity(0.06),
                  Colors.white.withOpacity(0.16),
                  Colors.white.withOpacity(0.06),
                ],
                stops: const <double>[0.0, 0.5, 1.0],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// A skeleton sized like one line of text in [style].
///
/// By default the bar takes the whole width its parent offers, so a
/// placeholder fills the block it sits in: the stats grid reads as four cells
/// waiting together instead of four ragged stubs of different lengths, which
/// is what a short bar floating in a wide cell looked like. Only when the
/// parent offers no bound - a [Row] child without [Expanded], the main axis of
/// a scroll view - does the bar fall back to [characters], a width measured in
/// characters of [style]; take that fallback from [GlukSkeleton] rather than
/// counting the string that is on its way. Pass `fill: false` for the rare bar
/// that has to stay glyph-sized. The height always follows [style], so the row
/// keeps its shape when the value lands.
class SkeletonText extends StatelessWidget {
  const SkeletonText({
    super.key,
    required this.characters,
    this.style,
    this.animate = true,
    this.alignment = Alignment.centerLeft,
    this.fill = true,
  });

  final int characters;
  final TextStyle? style;
  final bool animate;
  final AlignmentGeometry alignment;

  /// Stretch to the width the parent offers whenever that width is bounded.
  final bool fill;

  @override
  Widget build(BuildContext context) {
    final TextStyle resolved = style ?? DefaultTextStyle.of(context).style;
    final double fontSize = resolved.fontSize ?? 14;
    final double height = (resolved.height ?? 1.2) * fontSize;
    // ~0.56 em per character is the average advance of a proportional font;
    // the bar deliberately lands a little under the real width.
    final double fallback = (characters * fontSize * 0.56).clamp(16.0, 320.0);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool bounded =
            constraints.hasBoundedWidth && constraints.maxWidth > 0;
        final double width = fill && bounded ? constraints.maxWidth : fallback;
        return Align(
          alignment: alignment,
          child: SizedBox(
            height: height,
            child: Center(
              child: SkeletonBox(
                width: width,
                height: (fontSize * 0.72).clamp(8.0, 40.0),
                animate: animate,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Shows [value] when known, a skeleton while loading, and a dash when the
/// value is genuinely absent (for example the VPN IP while disconnected).
///
/// The three states are distinct on purpose:
///   * `loading == true`           -> skeleton
///   * `value == null` (not loading) -> [emptyLabel] (default "—")
///   * otherwise                    -> the value
class ValueOrSkeleton extends StatelessWidget {
  const ValueOrSkeleton({
    super.key,
    required this.value,
    required this.loading,
    this.characters = GlukSkeleton.valueChars,
    this.style,
    this.emptyLabel = '\u2014',
    this.animate = true,
    this.textAlign = TextAlign.start,
    this.maxLines = 1,
    this.overflow = TextOverflow.ellipsis,
  });

  final String? value;
  final bool loading;
  final int characters;
  final TextStyle? style;
  final String emptyLabel;
  final bool animate;
  final TextAlign textAlign;
  final int maxLines;
  final TextOverflow overflow;

  @override
  Widget build(BuildContext context) {
    final String? text = value;
    // Both branches must be measured against the *same* style, or the row
    // changes height the moment the value lands - the jump this widget exists
    // to prevent. The skeleton used to fall through to the inherited
    // DefaultTextStyle while the value rendered with the local fallback below,
    // so whenever `style` was null and the ambient font size was not 14, the
    // placeholder and the text were different sizes. Merging the way Text
    // itself does keeps one resolved style for both.
    final TextStyle resolved = DefaultTextStyle.of(context).style.merge(
          style ??
              const TextStyle(
                color: GlukColors.text0,
                fontWeight: FontWeight.w600,
              ),
        );
    if (loading && (text == null || text.isEmpty)) {
      return SkeletonText(
        characters: characters,
        style: resolved,
        animate: animate,
        alignment: _alignmentFor(textAlign),
      );
    }
    return Text(
      text == null || text.isEmpty ? emptyLabel : text,
      style: resolved,
      textAlign: textAlign,
      maxLines: maxLines,
      overflow: overflow,
    );
  }

  static AlignmentGeometry _alignmentFor(TextAlign align) {
    switch (align) {
      case TextAlign.center:
        return Alignment.center;
      case TextAlign.right:
      case TextAlign.end:
        return Alignment.centerRight;
      default:
        return Alignment.centerLeft;
    }
  }
}
