import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/models.dart';
import '../theme/tokens.dart';
import '../utils/format.dart';

/// Шкала месячного лимита тарифа — «234 МБ из 5 ГБ» и ширина канала.
///
/// ОДИН виджет на телефон и на Windows, и такая же шкала на сайте и в
/// расширении: если каждая площадка будет считать проценты по-своему,
/// человек увидит три разные цифры одного и того же трафика.
///
/// Важное правило: все числа приходят с сервера. Байты считает узел,
/// API складывает их в окне тарифа и решает, исчерпан ли лимит. Клиент
/// ничего не сообщает о своём расходе и потому не может его занизить.
///
/// Цвет едет непрерывно через [QuotaScale]: зелёный до 50 %, жёлтый к
/// 70 %, красный к 90 %. Ступенька на 90 % предупреждала слишком поздно:
/// тариф выбирают заранее, а не в последние десять процентов.
class QuotaBar extends StatelessWidget {
	const QuotaBar({
		super.key,
		required this.quota,
		required this.russian,
		this.compact = false,
		this.ring = false,
	});

	final QuotaInfo quota;
	final bool russian;

	/// Компактный вид для главного экрана и узких колонок.
	final bool compact;

	/// Подробный вид для экрана статистики: кольцо доли и бейдж
	/// с самим лимитом. На главном экране кольцо лишнее — там важно
	/// одно: пустит ли сервер в туннель сейчас.
	final bool ring;

	@override
	Widget build(BuildContext context) {
		// Без лимита шкалу рисовать нечего: пустая полоса читалась бы как
		// «лимит ноль», а это прямая противоположность смысла.
		if (!quota.hasLimit) return const SizedBox.shrink();
		final double fraction = quota.fraction;
		final bool over = quota.exceeded || fraction >= 1;
		// При исчерпанном лимите берём край шкалы: сервер может считать квоту
		// законченной и на 0.98 — полоса не должна оставаться оранжевой.
		final Color tone = QuotaScale.tone(over ? 1 : fraction);
		// В подробном виде дата сброса читается как обещание — «5 октября»,
		// а не как номер документа.
		final String reset = ring ? _longDate(quota.periodEnd, russian) : _shortDate(quota.periodEnd);
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
					if (ring)
						_RingHead(
							russian: russian,
							tone: tone,
							fraction: fraction,
							over: over,
							value: value,
							limit: formatBytes(quota.limitBytes),
						)
					else
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
					// Второе измерение того же тарифа: гигабайты говорят «сколько»,
					// Мбит/с — «как быстро». Цифра серверная: её же получает узел,
					// когда ставит ограничение на пира, поэтому обещанное и реальное совпадают.
					if (quota.hasSpeedLimit) ...<Widget>[
						SizedBox(height: compact ? 3 : 4),
						Text(
							russian
									? 'Скорость до ${quota.speedLimitMbps} Мбит/с'
									: 'Up to ${quota.speedLimitMbps} Mbit/s',
							style: TextStyle(
								color: over ? tone : GlukColors.connected,
								fontSize: compact ? 10.5 : 11.5,
								fontWeight: FontWeight.w700,
								height: 1.35,
							),
						),
					],
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

/// «5 октября» вместо «05.10.2026» для подробного вида. Год не нужен:
/// окно тарифа всегда в пределах месяца от сегодня. Без intl —
/// ради одной строки тянуть локали незачем.
String _longDate(DateTime? value, bool russian) {
	if (value == null) return '\u2014';
	final DateTime local = value.toLocal();
	if (russian) {
		const List<String> months = <String>[
			'января', 'февраля', 'марта', 'апреля', 'мая', 'июня',
			'июля', 'августа', 'сентября', 'октября', 'ноября', 'декабря',
		];
		return '${local.day} ${months[local.month - 1]}';
	}
	const List<String> months = <String>[
		'January', 'February', 'March', 'April', 'May', 'June',
		'July', 'August', 'September', 'October', 'November', 'December',
	];
	return '${months[local.month - 1]} ${local.day}';
}

/// Доля в процентах для центра кольца. Десятая доля важна только
/// на малых значениях: «4.7 %» говорит больше, чем «5 %», а вот «93.4 %»
/// уже нет.
String _percentLabel(double fraction) {
	final double percent = ((fraction.isFinite ? fraction : 0.0) * 100).clamp(0, 999).toDouble();
	return percent >= 10 ? '${percent.toStringAsFixed(0)}%' : '${percent.toStringAsFixed(1)}%';
}

/// Кольцо доли, крупный расход и бейдж с лимитом.
///
/// Кольцо и полоса под ним считаются от одного `fraction`, иначе
/// в одной карточке оказалось бы два разных процента одного трафика.
class _RingHead extends StatelessWidget {
	const _RingHead({
		required this.russian,
		required this.tone,
		required this.fraction,
		required this.over,
		required this.value,
		required this.limit,
	});

	final bool russian, over;
	final Color tone;
	final double fraction;
	final String value, limit;

	@override
	Widget build(BuildContext context) => Row(
				children: <Widget>[
					SizedBox(
						width: 62,
						height: 62,
						child: CustomPaint(
							painter: _RingPainter(fraction: fraction, tone: tone),
							child: Center(
								child: Text(
									_percentLabel(fraction),
									style: TextStyle(
										color: tone,
										fontSize: 13,
										fontWeight: FontWeight.w800,
									),
								),
							),
						),
					),
					const SizedBox(width: 14),
					Expanded(
						child: Column(
							crossAxisAlignment: CrossAxisAlignment.start,
							mainAxisSize: MainAxisSize.min,
							children: <Widget>[
								Text(
									(russian ? 'Лимит тарифа' : 'Plan allowance').toUpperCase(),
									style: const TextStyle(
										color: GlukColors.text2,
										fontSize: 10,
										fontWeight: FontWeight.w700,
										letterSpacing: 0.9,
									),
								),
								const SizedBox(height: 5),
								Text(
									value,
									maxLines: 1,
									overflow: TextOverflow.ellipsis,
									style: TextStyle(
										color: over ? tone : GlukColors.text0,
										fontSize: 18,
										fontWeight: FontWeight.w800,
									),
								),
							],
						),
					),
					const SizedBox(width: 10),
					// Бейдж повторяет сам лимит: его ищут глазами отдельно
					// от текущего расхода, когда решают, хватит ли тарифа.
					Container(
						padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
						decoration: BoxDecoration(
							color: tone.withOpacity(0.14),
							borderRadius: BorderRadius.circular(999),
							border: Border.all(color: tone.withOpacity(0.34)),
						),
						child: Text(
							limit,
							style: TextStyle(color: tone, fontSize: 11, fontWeight: FontWeight.w800),
						),
					),
				],
			);
}

/// Кольцо расхода. Отсчёт от двенадцати часов и по часовой:
/// так же растёт кольцо на сайте и в расширении.
class _RingPainter extends CustomPainter {
	const _RingPainter({required this.fraction, required this.tone});

	final double fraction;
	final Color tone;

	@override
	void paint(Canvas canvas, Size size) {
		const double stroke = 7;
		final Rect rect = Rect.fromLTWH(
			stroke / 2,
			stroke / 2,
			size.width - stroke,
			size.height - stroke,
		);
		canvas.drawArc(
			rect,
			0,
			math.pi * 2,
			false,
			Paint()
				..style = PaintingStyle.stroke
				..strokeWidth = stroke
				..color = Colors.white.withOpacity(0.08),
		);
		final double swept = (fraction.isFinite ? fraction : 0.0).clamp(0.0, 1.0).toDouble() * math.pi * 2;
		// Ровно нуль рисовать нечего, а вот сотую долю процента видно
		// как точку — это верно: трафик уже есть.
		if (swept <= 0) return;
		canvas.drawArc(
			rect,
			-math.pi / 2,
			swept,
			false,
			Paint()
				..style = PaintingStyle.stroke
				..strokeWidth = stroke
				..strokeCap = StrokeCap.round
				// Сплошной цвет вместо SweepGradient. Круглый кап на старте арки
				// стоит на 12 часах, то есть на самом конце развёртки градиента,
				// и сэмплил её яркий край, пока тело арки рядом шло с прозрачностью
				// 0.55 — сверху горела заметная точка. Ограничить углы нельзя:
				// у кольца развёртка ровно 2π, край всё равно окажется под капом.
				..color = tone,
		);
	}

	@override
	bool shouldRepaint(_RingPainter old) => old.fraction != fraction || old.tone != tone;
}
