import 'package:flutter/material.dart';

import '../models/models.dart';
import '../theme/tokens.dart';
import '../utils/format.dart';

/// Шкала месячного лимита тарифа — «234 МБ из 5 ГБ».
///
/// ОДИН виджет на телефон и на Windows, и такая же шкала на сайте и в
/// расширении: если каждая площадка будет считать проценты по-своему,
/// человек увидит три разные цифры одного и того же трафика.
///
/// Важное правило: все числа приходят с сервера. Байты считает узел,
/// API складывает их в окне тарифа и решает, исчерпан ли лимит. Клиент
/// ничего не сообщает о своём расходе и потому не может его занизить.
///
/// Цвет меняется только на деле: зелёный пока запас есть, янтарный после
/// 90 %, красный когда сервер уже не даст подключиться.
class QuotaBar extends StatelessWidget {
	const QuotaBar({
		super.key,
		required this.quota,
		required this.russian,
		this.compact = false,
	});

	final QuotaInfo quota;
	final bool russian;

	/// Компактный вид для главного экрана и узких колонок.
	final bool compact;

	@override
	Widget build(BuildContext context) {
		// Без лимита шкалу рисовать нечего: пустая полоса читалась бы как
		// «лимит ноль», а это прямая противоположность смысла.
		if (!quota.hasLimit) return const SizedBox.shrink();
		final double fraction = quota.fraction;
		final bool over = quota.exceeded || fraction >= 1;
		final Color tone = over
				? GlukColors.danger
				: fraction >= 0.9
						? GlukColors.amber
						: GlukColors.connected;
		final String reset = _shortDate(quota.periodEnd);
		final String value =
				'${formatBytes(quota.usedBytes)} ${russian ? 'из' : 'of'} ${formatBytes(quota.limitBytes)}';
		final String note = over
				? (russian
						? 'Лимит израсходован. Подключения возобновятся $reset.'
						: 'Allowance spent. Connections resume on $reset.')
				: (russian
						? 'Осталось ${formatBytes(quota.leftBytes)} · сброс $reset'
						: '${formatBytes(quota.leftBytes)} left · resets $reset');
		return Container(
			padding: EdgeInsets.symmetric(
				horizontal: compact ? 12 : 14,
				vertical: compact ? 10 : 13,
			),
			decoration: BoxDecoration(
				color: tone.withOpacity(0.09),
				borderRadius: BorderRadius.circular(compact ? 13 : 16),
				border: Border.all(color: tone.withOpacity(0.30)),
			),
			child: Column(
				crossAxisAlignment: CrossAxisAlignment.stretch,
				children: <Widget>[
					Row(
						children: <Widget>[
							Icon(
								over ? Icons.speed_rounded : Icons.data_usage_rounded,
								size: compact ? 15 : 17,
								color: tone,
							),
							const SizedBox(width: 8),
							if (!compact)
								Text(
									russian ? 'Лимит тарифа' : 'Plan allowance',
									style: const TextStyle(
										color: GlukColors.text1,
										fontSize: 12,
										fontWeight: FontWeight.w700,
										letterSpacing: 0.2,
									),
								),
							const Spacer(),
							Text(
								value,
								style: TextStyle(
									color: over ? tone : GlukColors.text0,
									fontSize: compact ? 12.5 : 14,
									fontWeight: FontWeight.w800,
								),
							),
						],
					),
					SizedBox(height: compact ? 7 : 9),
					// Ширина берётся от реальной ширины родителя, а не от процента
					// на глаз: так шкала одинакова в узкой колонке и на широком ПК.
					LayoutBuilder(
						builder: (BuildContext context, BoxConstraints constraints) {
							final double height = compact ? 7 : 9;
							final double full = constraints.maxWidth;
							final double width = (full * fraction).clamp(height, full).toDouble();
							return Stack(
								children: <Widget>[
									Container(
										height: height,
										decoration: BoxDecoration(
											color: Colors.white.withOpacity(0.07),
											borderRadius: BorderRadius.circular(999),
										),
									),
									AnimatedContainer(
										duration: const Duration(milliseconds: 420),
										curve: Curves.easeOutCubic,
										height: height,
										width: width,
										decoration: BoxDecoration(
											gradient: LinearGradient(
												colors: <Color>[tone.withOpacity(0.72), tone],
											),
											borderRadius: BorderRadius.circular(999),
										),
									),
								],
							);
						},
					),
					SizedBox(height: compact ? 6 : 8),
					Text(
						note,
						style: TextStyle(
							color: over ? tone : GlukColors.text2,
							fontSize: compact ? 10.5 : 11.5,
							height: 1.35,
						),
					),
				],
			),
		);
	}
}

/// Дата сброса без intl: окно тарифа — календарная дата, не время.
String _shortDate(DateTime? value) {
	if (value == null) return '\u2014';
	final DateTime local = value.toLocal();
	String two(int number) => number < 10 ? '0$number' : '$number';
	return '${two(local.day)}.${two(local.month)}.${local.year}';
}
