import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/models.dart';

/// Уровень подписки рядом с ником.
///
/// Один и тот же бейджик на всех четырёх площадках (сайт, ПК, телефон,
/// расширение): узел в центре и нити к соседним узлам — чем выше тариф, тем
/// больше сеть. Free — одинокая точка, Basic — одна нить, Pro — три
/// уравновешенных узла, β Pro — та же сеть за пунктирным контуром
/// (внутренний тариф, поэтому и цвет намеренно не из общего ряда).
/// Геометрия и цвета взяты из макета и повторены в `site/assets/css/auth.css`,
/// `extension/ui/theme.css` и `control-server/public/admin.css` — это тот же
/// бейджик, а не «похожий».
///
/// Токен считает сервер (`subscription.badge`): клиент его не выбирает и
/// подделать уровень локально не может. Для старых серверов, которые поля ещё
/// не присылают, выводим из кода тарифа, а отсутствие подписки — это и есть
/// Free (Free не подписка, а её отсутствие).
enum PlanBadgeTier { free, basic, pro, beta }

PlanBadgeTier planBadgeTierOf(SubscriptionInfo? subscription) {
  switch ((subscription?.badge ?? '').toLowerCase()) {
    case 'free':
      return PlanBadgeTier.free;
    case 'basic':
      return PlanBadgeTier.basic;
    case 'pro':
      return PlanBadgeTier.pro;
    case 'beta':
      return PlanBadgeTier.beta;
  }
  final String plan = subscription?.plan ?? '';
  final String raw = plan.isNotEmpty ? plan : (subscription?.planName ?? '');
  final String code = raw.toLowerCase().replaceAll(RegExp(r'[\s_-]'), '');
  if (code.contains('beta') || code.contains('β')) return PlanBadgeTier.beta;
  if (code.contains('pro')) return PlanBadgeTier.pro;
  if (code.contains('basic')) return PlanBadgeTier.basic;
  return PlanBadgeTier.free;
}

String planBadgeLabel(PlanBadgeTier tier) {
  switch (tier) {
    case PlanBadgeTier.free:
      return 'Free';
    case PlanBadgeTier.basic:
      return 'Basic';
    case PlanBadgeTier.pro:
      return 'Pro';
    case PlanBadgeTier.beta:
      return 'β Pro';
  }
}

class _BadgeStyle {
  const _BadgeStyle({
    required this.ink,
    required this.stroke,
    required this.nodes,
    this.fill,
    this.gradient,
    this.halo = 1.9,
    this.dot = 0.95,
    this.ring = false,
  });

  final Color ink;
  final Color stroke;
  final Color? fill;
  final Gradient? gradient;

  /// Сколько узлов вокруг центра рисуем: 0 у Free, 1 у Basic, 3 у Pro и β Pro.
  final int nodes;
  final double halo;
  final double dot;

  /// Пунктирный контур вокруг сети — только у закрытого β Pro.
  final bool ring;
}

/// Цвета из макета: hsl(224 10% 74%), hsl(215 90% 70%), hsl(266 84% 75%),
/// hsl(172 70% 62%). Рамка — тот же тон с прозрачностью 0.32, фон — 0.10.
const Map<PlanBadgeTier, _BadgeStyle> _styles = <PlanBadgeTier, _BadgeStyle>{
  PlanBadgeTier.free: _BadgeStyle(
    ink: Color(0xFFB6BAC3),
    stroke: Color(0x52B6BAC3),
    fill: Color(0x1AB6BAC3),
    nodes: 0,
  ),
  PlanBadgeTier.basic: _BadgeStyle(
    ink: Color(0xFF6EA7F7),
    stroke: Color(0x526EA7F7),
    fill: Color(0x1A6EA7F7),
    nodes: 1,
    halo: 2.05,
    dot: 1,
  ),
  PlanBadgeTier.pro: _BadgeStyle(
    ink: Color(0xFFB88AF5),
    stroke: Color(0x52B88AF5),
    fill: Color(0x1AB88AF5),
    nodes: 3,
  ),
  PlanBadgeTier.beta: _BadgeStyle(
    ink: Color(0xFF5AE2D0),
    stroke: Color(0x57B28DE2),
    nodes: 3,
    ring: true,
    gradient: LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: <Color>[Color(0x265AE2D0), Color(0x29B88AF5)],
    ),
  ),
};

/// Значок бейджика. Рисуем вручную, потому что готового глифа «узел с нитями»
/// в Material нет, а контур должен совпадать с SVG на сайте до координат.
class _PlanGlyphPainter extends CustomPainter {
  const _PlanGlyphPainter({
    required this.color,
    required this.nodes,
    required this.halo,
    required this.dot,
    required this.ring,
  });

  final Color color;
  final int nodes;
  final double halo;
  final double dot;
  final bool ring;

  /// Те же координаты, что в SVG: вверх-вправо, вниз-вправо и влево по центру.
  static const List<Offset> _spots = <Offset>[
    Offset(15.25, 6.37),
    Offset(15.25, 17.63),
    Offset(5.5, 12),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final double k = size.shortestSide / 24;
    Offset at(Offset point) => Offset(point.dx * k, point.dy * k);
    final Offset centre = at(const Offset(12, 12));
    final int count = math.min(nodes, _spots.length);

    final Paint thread = Paint()
      ..color = color.withOpacity(0.85)
      ..strokeWidth = 1.3 * k
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    for (int i = 0; i < count; i++) {
      canvas.drawLine(centre, at(_spots[i]), thread);
    }

    final Paint glow = Paint()..color = color.withOpacity(0.18);
    final Paint solid = Paint()..color = color;
    for (int i = 0; i < count; i++) {
      canvas.drawCircle(at(_spots[i]), halo * k, glow);
    }
    for (int i = 0; i < count; i++) {
      canvas.drawCircle(at(_spots[i]), dot * k, solid);
    }

    if (ring) {
      final Paint dashed = Paint()
        ..color = color.withOpacity(0.5)
        ..strokeWidth = 1 * k
        ..style = PaintingStyle.stroke;
      final Rect bounds = Rect.fromCircle(center: centre, radius: 9.3 * k);
      const int segments = 22;
      const double step = math.pi * 2 / segments;
      for (int i = 0; i < segments; i++) {
        canvas.drawArc(bounds, step * i, step * 0.42, false, dashed);
      }
    }

    canvas.drawCircle(
      centre,
      2.6 * k,
      Paint()
        ..color = color
        ..strokeWidth = 1.3 * k
        ..style = PaintingStyle.stroke,
    );
    canvas.drawCircle(centre, 1.15 * k, solid);
  }

  @override
  bool shouldRepaint(_PlanGlyphPainter old) =>
      old.color != color ||
      old.nodes != nodes ||
      old.halo != halo ||
      old.dot != dot ||
      old.ring != ring;
}

/// Маленький бейджик тарифа. `compact` — для плотных строк (шапка профиля).
class PlanBadge extends StatelessWidget {
  const PlanBadge({super.key, this.subscription, this.compact = false});

  final SubscriptionInfo? subscription;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final PlanBadgeTier tier = planBadgeTierOf(subscription);
    final _BadgeStyle style = _styles[tier]!;
    final String label = planBadgeLabel(tier);
    final double glyph = compact ? 14 : 16;
    return Semantics(
      label: label,
      child: Container(
        height: compact ? 23 : 27,
        padding: EdgeInsets.only(left: compact ? 7 : 8, right: compact ? 9 : 11),
        decoration: BoxDecoration(
          color: style.gradient == null ? style.fill : null,
          gradient: style.gradient,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: style.stroke),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            SizedBox(
              width: glyph,
              height: glyph,
              child: CustomPaint(
                painter: _PlanGlyphPainter(
                  color: style.ink,
                  nodes: style.nodes,
                  halo: style.halo,
                  dot: style.dot,
                  ring: style.ring,
                ),
              ),
            ),
            SizedBox(width: compact ? 5 : 6),
            Text(
              label,
              style: TextStyle(
                color: style.ink,
                fontSize: compact ? 11 : 12,
                fontWeight: FontWeight.w600,
                height: 1.1,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
