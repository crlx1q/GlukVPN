import 'package:flutter/material.dart';

import '../models/models.dart';
import '../theme/tokens.dart';

/// `color:#f3c98b` — текст плашки запретов. Светлее янтарной заливки под
/// ним, поэтому читается на ней, в отличие от самого [GlukColors.amber].
const Color _ink = Color(0xFFF3C98B);

/// `transition:transform .16s ease` у `.srv-limits-chev`.
const Duration _turn = Duration(milliseconds: 160);

/// «Что запрещено на этом сервере» — плашка под строкой сервера: свёрнуто
/// одна строка со счётчиком, раскрыто — запрет, правила за ним и короткий
/// комментарий почему.
///
/// ОДИН виджет на телефон и на Windows, как и [QuotaBar]: до этого каждый
/// экран рисовал свой список, и один и тот же запрет выглядел на телефоне
/// и на ПК по-разному. Вид взят с плашки в расширении и в админке
/// (`.srv-limits-toggle` в `extension/ui/theme.css`): бейджик по размеру
/// текста, а не полоса на всю ширину — серверов в списке много, и строка
/// не должна распухать.
///
/// Все тексты приходят с сервера: политика узла решает, что запрещено, а
/// [NodeRestriction] лишь переводит известные коды. Текст админа рисуется
/// как текст ([Text]), поэтому разметку через него не подсунуть.
class NodeLimits extends StatefulWidget {
  const NodeLimits({
    super.key,
    required this.restrictions,
    required this.russian,
    this.compact = false,
    this.reduceMotion = false,
  });

  final List<NodeRestriction> restrictions;

  final bool russian;

  /// Компактный вид для телефона — те же отступы, что у плашки в
  /// расширении. На ПК всё на пункт-два крупнее: там строка шире.
  final bool compact;

  /// `prefers-reduced-motion` из расширения: поворот шеврона и смена цвета
  /// плашки перестают анимироваться. На сам список это не влияет.
  final bool reduceMotion;

  @override
  State<NodeLimits> createState() => _NodeLimitsState();
}

class _NodeLimitsState extends State<NodeLimits> {
  bool _open = false;
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final List<NodeRestriction> items = widget.restrictions;
    // Без запретов плашки нет вовсе: бейджик «0» читался бы как
    // предупреждение на сервере, где всё разрешено.
    if (items.isEmpty) return const SizedBox.shrink();
    final bool ru = widget.russian;
    final bool compact = widget.compact;
    // В расширении наведение и раскрытие дают плашке один и тот же вид.
    final bool lit = _open || _hovered;
    final Duration motion = widget.reduceMotion ? Duration.zero : _turn;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        // Заливка и обводка живут на Material, а не в Container вокруг
        // InkWell: иначе отклик на нажатие рисуется под фоном и его не
        // видно.
        Material(
          color: GlukColors.amber.withOpacity(lit ? 0.14 : 0.08),
          shape: StadiumBorder(
            side: BorderSide(
              color: GlukColors.amber.withOpacity(lit ? 0.46 : 0.28),
            ),
          ),
          animationDuration: motion,
          child: InkWell(
            customBorder: const StadiumBorder(),
            onTap: () => setState(() => _open = !_open),
            onHover: (bool hover) => setState(() => _hovered = hover),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: compact ? 9 : 10,
                vertical: compact ? 3 : 4,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    ru
                        ? 'Запрещено здесь \u00b7 ${items.length}'
                        : 'Blocked here \u00b7 ${items.length}',
                    style: TextStyle(
                      color: _ink,
                      fontSize: compact ? 10 : 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.1,
                    ),
                  ),
                  const SizedBox(width: 6),
                  AnimatedRotation(
                    turns: _open ? 0.5 : 0,
                    duration: motion,
                    curve: Curves.easeOut,
                    child: Icon(
                      Icons.expand_more_rounded,
                      size: compact ? 14 : 15,
                      color: _ink,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (_open)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(top: 5),
            padding: EdgeInsets.symmetric(
              horizontal: compact ? 10 : 12,
              vertical: compact ? 8 : 10,
            ),
            decoration: BoxDecoration(
              color: GlukColors.amber.withOpacity(0.04),
              borderRadius: BorderRadius.circular(
                compact ? 12 : GlukSizes.cellRadius,
              ),
              border: Border.all(color: GlukColors.amber.withOpacity(0.18)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                for (int i = 0; i < items.length; i++)
                  Padding(
                    // `gap:9px` между запретами и ничего под последним:
                    // иначе рамка снизу висит с пустой полосой.
                    padding: EdgeInsets.only(
                      bottom: i == items.length - 1 ? 0 : 9,
                    ),
                    child: _Limit(
                      restriction: items[i],
                      russian: ru,
                      compact: compact,
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Один запрет: чип с названием, правила фильтра за ним и комментарий
/// «почему» — тот же порядок, что в `.srv-limit` в расширении.
class _Limit extends StatelessWidget {
  const _Limit({
    required this.restriction,
    required this.russian,
    required this.compact,
  });

  final NodeRestriction restriction;
  final bool russian;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final String rules = restriction.rulesLine;
    final String detail = restriction.localizedDetail(russian);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        // `.restriction` — чип по размеру названия (`align-self:flex-start`),
        // а не на всю ширину блока.
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: GlukColors.amber.withOpacity(0.10),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: GlukColors.amber.withOpacity(0.30)),
          ),
          child: Text(
            restriction.localizedLabel(russian),
            style: TextStyle(
              color: _ink,
              fontSize: compact ? 9.5 : 10,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        if (rules.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Text(
              rules,
              style: TextStyle(
                color: GlukColors.text2,
                fontSize: compact ? 9 : 10,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        if (detail.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Text(
              detail,
              style: TextStyle(
                color: GlukColors.text2,
                fontSize: compact ? 10 : 11,
                height: 1.42,
              ),
            ),
          ),
      ],
    );
  }
}
