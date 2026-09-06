import 'package:flutter/material.dart';

import '../models/models.dart';

/// Уровень подписки рядом с ником.
///
/// Один и тот же набор бейджиков на всех площадках: серый Free, синий Basic,
/// фиолетовый Pro и «необычный» бирюзово-фиолетовый β Pro (внутренний тариф,
/// поэтому и цвет у него намеренно не из общего ряда). Цвета и подписи
/// совпадают с `site/assets/js/auth.js` и `extension/ui/theme.css` — это тот
/// же бейджик, а не «похожий».
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
    required this.icon,
    required this.ink,
    required this.stroke,
    this.fill,
    this.gradient,
  });

  final IconData icon;
  final Color ink;
  final Color stroke;
  final Color? fill;
  final Gradient? gradient;
}

/// Готовые глифы Material, а не самодельная графика: тот же смысл, что у
/// SVG-контуров на сайте (кольцо, щит с галочкой, искра, колба).
const Map<PlanBadgeTier, _BadgeStyle> _styles = <PlanBadgeTier, _BadgeStyle>{
  PlanBadgeTier.free: _BadgeStyle(
    icon: Icons.radio_button_checked_rounded,
    ink: Color(0xFFC3CBD8),
    stroke: Color(0x579AA4B2),
    fill: Color(0x229AA4B2),
  ),
  PlanBadgeTier.basic: _BadgeStyle(
    icon: Icons.verified_user_outlined,
    ink: Color(0xFF8FB8FF),
    stroke: Color(0x664C8DFF),
    fill: Color(0x264C8DFF),
  ),
  PlanBadgeTier.pro: _BadgeStyle(
    icon: Icons.auto_awesome_rounded,
    ink: Color(0xFFD6BCFF),
    stroke: Color(0x70A970FF),
    fill: Color(0x2BA970FF),
  ),
  PlanBadgeTier.beta: _BadgeStyle(
    icon: Icons.science_rounded,
    ink: Color(0xFF7FF0DD),
    stroke: Color(0x7316E0C0),
    gradient: LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: <Color>[Color(0x3316E0C0), Color(0x38A970FF)],
    ),
  ),
};

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
    return Semantics(
      label: label,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 7 : 9,
          vertical: compact ? 2 : 3,
        ),
        decoration: BoxDecoration(
          color: style.gradient == null ? style.fill : null,
          gradient: style.gradient,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: style.stroke),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(style.icon, size: compact ? 11 : 13, color: style.ink),
            SizedBox(width: compact ? 4 : 5),
            Text(
              label,
              style: TextStyle(
                color: style.ink,
                fontSize: compact ? 10 : 11,
                fontWeight: FontWeight.w700,
                height: 1.1,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
