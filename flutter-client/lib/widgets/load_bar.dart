import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// Шкала загрузки узла — тот же элемент, что `.load-bar` в расширении:
/// дорожка 52×4 и заливка по единой шкале [QuotaScale].
///
/// До этого телефон и ПК писали загрузку только числом, и рядом с цветной
/// цифрой пинга она читалась как ещё один серый текст. Полоса даёт то же,
/// что в браузере: занятость узла видно, не читая процентов.
///
/// Цвет считает [QuotaScale] — тот же расчёт, что у квот в расширении, на
/// сайте и в админке. Своих порогов здесь нет намеренно: одинаковая
/// заполненность обязана выглядеть одинаково на всех площадках.
class NodeLoadBar extends StatelessWidget {
  const NodeLoadBar({
    super.key,
    required this.percent,
    this.width = 52,
    this.height = 4,
  });

  /// Загрузка узла в процентах, 0..100 — как её присылает сервер
  /// (`loadPercent` в heartbeat), клиент ничего не досчитывает.
  final num percent;

  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final double value = percent.toDouble().clamp(0, 100).toDouble();
    return Semantics(
      label: 'Load ${value.round()}%',
      child: Container(
        width: width,
        height: height,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.09),
          borderRadius: BorderRadius.circular(height),
        ),
        child: Align(
          alignment: Alignment.centerLeft,
          child: FractionallySizedBox(
            widthFactor: value / 100,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: QuotaScale.toneFromPercent(value),
                borderRadius: BorderRadius.circular(height),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
