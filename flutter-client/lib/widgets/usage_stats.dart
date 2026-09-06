import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/account_insights.dart';
import '../theme/tokens.dart';
import '../utils/format.dart';
import 'active_account_map.dart' show accountDeviceIcon;
import 'glass.dart';
import 'quota_bar.dart';

/// Статистика использования — ОДИН блок на все площадки.
///
/// Почему отдельный виджет, а не код внутри экрана: тот же самый
/// вид нужен на Windows и на телефоне, а две копии одного графика
/// расходятся через две правки. Хост-экран отвечает только за
/// загрузку данных, а весь UI живёт здесь.
///
/// Что исправлено по сравнению с прежним экраном ПК:
///  • период — три крупные клавиши вместо системного SegmentedButton,
///    под каждой подписано, что именно показывает график
///    (день — по часам, неделя и месяц — по дням);
///  • у графика есть подписи оси, пик и среднее, а столбики
///    закруглены и никогда не схлопываются в нить;
///  • устройства идут со своими иконками и долей от общего
///    трафика — видно, кто сколько «съел»;
///  • домены по умолчанию свёрнуты до самых тратных;
///  • бюджет — карточка НА КОНКРЕТНЫЙ СЕРВЕР, и таких карточек
///    может быть несколько (серверов будет больше одного).
class UsageStatsView extends StatelessWidget {
	const UsageStatsView({
		super.key,
		required this.period,
		required this.onPeriod,
		required this.onReload,
		required this.russian,
		this.title,
		this.data,
		this.loading = false,
		this.error,
		this.serverLabel,
		this.padding = const EdgeInsets.all(GlukSizes.pagePadding),
	});

	final AnalyticsPeriod period;
	final ValueChanged<AnalyticsPeriod> onPeriod;
	final VoidCallback onReload;
	final bool russian;
	final String? title;
	final AnalyticsSnapshot? data;
	final bool loading;
	final Object? error;

	/// Название сервера, к которому относятся траты инфраструктуры.
	final String? serverLabel;
	final EdgeInsetsGeometry padding;

	bool get _ru => russian;

	@override
	Widget build(BuildContext context) {
		final AnalyticsSnapshot? d = data;
		return ListView(
			padding: padding,
			children: <Widget>[
				_Head(
					title: title ?? (_ru ? 'Статистика использования' : 'Usage statistics'),
					period: period,
					onPeriod: onPeriod,
					russian: _ru,
					busy: loading,
					onReload: onReload,
				),
				const SizedBox(height: 14),
				if (loading)
					_Skeleton(russian: _ru)
				else if (error != null || d == null)
					_Failed(russian: _ru, onReload: onReload)
				else ...<Widget>[
					if (d.partial) _Coverage(russian: _ru, since: d.coverageSince),
					// Лимит тарифа стоит первым: из всей статистики именно он
					// отключает туннель. Цифры серверные — считает узел, не клиент.
					if (d.quota != null) ...<Widget>[
						QuotaBar(quota: d.quota!, russian: _ru),
						const SizedBox(height: 12),
					],
					_Totals(snapshot: d, russian: _ru, period: period),
					const SizedBox(height: 12),
					_TrafficChart(points: d.series, period: period, russian: _ru),
					_Section(_ru ? 'По устройствам' : 'By device'),
					_Devices(devices: d.devices, russian: _ru),
					_Section(_ru ? 'Сайты и категории' : 'Sites and categories'),
					_Domains(snapshot: d, russian: _ru),
					if (d.budget.adminOnly) ...<Widget>[
						_Section(_ru ? 'Инфраструктура — только админам' : 'Infrastructure — admins only'),
						_Budgets(budget: d.budget, russian: _ru, serverLabel: serverLabel),
					],
				],
				const SizedBox(height: 24),
			],
		);
	}
}

String _utc(DateTime? value) => value == null
		? '—'
		: '${value.toUtc().toIso8601String().substring(0, 16).replaceFirst('T', ' ')} UTC';

String _periodTitle(AnalyticsPeriod period, bool ru) {
	switch (period) {
		case AnalyticsPeriod.day:
			return ru ? 'День' : 'Day';
		case AnalyticsPeriod.week:
			return ru ? 'Неделя' : 'Week';
		case AnalyticsPeriod.month:
			return ru ? 'Месяц' : 'Month';
	}
}

String _periodHint(AnalyticsPeriod period, bool ru) {
	switch (period) {
		case AnalyticsPeriod.day:
			return ru ? 'по часам' : 'by hour';
		case AnalyticsPeriod.week:
			return ru ? '7 дней' : '7 days';
		case AnalyticsPeriod.month:
			return ru ? '30 дней' : '30 days';
	}
}

/// Заголовок и выбор периода.
class _Head extends StatelessWidget {
	const _Head({
		required this.title,
		required this.period,
		required this.onPeriod,
		required this.russian,
		required this.busy,
		required this.onReload,
	});

	final String title;
	final AnalyticsPeriod period;
	final ValueChanged<AnalyticsPeriod> onPeriod;
	final bool russian, busy;
	final VoidCallback onReload;

	@override
	Widget build(BuildContext context) {
		return Column(
			crossAxisAlignment: CrossAxisAlignment.stretch,
			children: <Widget>[
				Row(
					children: <Widget>[
						Expanded(
							child: Text(
								title,
								style: const TextStyle(
									color: GlukColors.text0,
									fontSize: 19,
									fontWeight: FontWeight.w700,
								),
							),
						),
						IconButton(
							tooltip: russian ? 'Обновить' : 'Refresh',
							icon: const Icon(Icons.refresh_rounded, size: 20),
							color: GlukColors.text1,
							onPressed: busy ? null : onReload,
						),
					],
				),
				const SizedBox(height: 6),
				Row(
					children: AnalyticsPeriod.values.map((AnalyticsPeriod value) {
						final bool on = value == period;
						return Expanded(
							child: Padding(
								padding: EdgeInsets.only(right: value == AnalyticsPeriod.month ? 0 : 8),
								child: Material(
									color: on
											? GlukColors.violet.withOpacity(0.20)
											: Colors.white.withOpacity(0.04),
									borderRadius: BorderRadius.circular(14),
									clipBehavior: Clip.antiAlias,
									child: InkWell(
										onTap: on ? null : () => onPeriod(value),
										child: Container(
											padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 6),
											decoration: BoxDecoration(
												borderRadius: BorderRadius.circular(14),
												border: Border.all(
													color: on
															? GlukColors.violetLight.withOpacity(0.55)
															: Colors.white.withOpacity(0.08),
												),
											),
											child: Column(
												mainAxisSize: MainAxisSize.min,
												children: <Widget>[
													Text(
														_periodTitle(value, russian),
														style: TextStyle(
															color: on ? GlukColors.text0 : GlukColors.text1,
															fontSize: 13,
															fontWeight: FontWeight.w700,
														),
													),
													const SizedBox(height: 1),
													Text(
														_periodHint(value, russian),
														style: const TextStyle(color: GlukColors.text2, fontSize: 10),
													),
												],
											),
										),
									),
								),
							),
						);
					}).toList(),
				),
			],
		);
	}
}

/// Неполная история: раньше это была янтарная строка текста без рамки.
class _Coverage extends StatelessWidget {
	const _Coverage({required this.russian, required this.since});

	final bool russian;
	final DateTime? since;

	@override
	Widget build(BuildContext context) => Padding(
				padding: const EdgeInsets.only(bottom: 12),
				child: Container(
					padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
					decoration: BoxDecoration(
						color: GlukColors.amber.withOpacity(0.10),
						borderRadius: BorderRadius.circular(14),
						border: Border.all(color: GlukColors.amber.withOpacity(0.32)),
					),
					child: Row(
						crossAxisAlignment: CrossAxisAlignment.start,
						children: <Widget>[
							const Icon(Icons.history_toggle_off_rounded, size: 17, color: GlukColors.amber),
							const SizedBox(width: 9),
							Expanded(
								child: Text(
									russian
											? 'История ведётся с ${_utc(since)}. За более ранние дни данных нет — это не нулевой трафик, а отсутствие измерений.'
											: 'Measurements start at ${_utc(since)}. Earlier days have no data — that is missing history, not zero traffic.',
									style: const TextStyle(color: GlukColors.amber, fontSize: 12, height: 1.35),
								),
							),
						],
					),
				),
			);
}

/// Две карточки итогов и общий объём.
class _Totals extends StatelessWidget {
	const _Totals({required this.snapshot, required this.russian, required this.period});

	final AnalyticsSnapshot snapshot;
	final bool russian;
	final AnalyticsPeriod period;

	@override
	Widget build(BuildContext context) {
		final int total = snapshot.downloadBytes + snapshot.uploadBytes;
		return Column(
			crossAxisAlignment: CrossAxisAlignment.stretch,
			children: <Widget>[
				Row(
					children: <Widget>[
						Expanded(
							child: _Metric(
								icon: Icons.south_rounded,
								label: russian ? 'Загружено' : 'Downloaded',
								value: formatBytes(snapshot.downloadBytes),
								tone: GlukColors.connected,
							),
						),
						const SizedBox(width: 10),
						Expanded(
							child: _Metric(
								icon: Icons.north_rounded,
								label: russian ? 'Отправлено' : 'Uploaded',
								value: formatBytes(snapshot.uploadBytes),
								tone: GlukColors.violetLight,
							),
						),
					],
				),
				const SizedBox(height: 8),
				Text(
					russian
							? 'Всего за период «${_periodTitle(period, russian).toLowerCase()}»: ${formatBytes(total)}'
							: 'Total for "${_periodTitle(period, russian).toLowerCase()}": ${formatBytes(total)}',
					style: const TextStyle(color: GlukColors.text2, fontSize: 11.5),
				),
			],
		);
	}
}

class _Metric extends StatelessWidget {
	const _Metric({required this.icon, required this.label, required this.value, required this.tone});

	final IconData icon;
	final String label, value;
	final Color tone;

	@override
	Widget build(BuildContext context) => GlassPanel(
				radius: 16,
				padding: const EdgeInsets.all(14),
				child: Column(
					crossAxisAlignment: CrossAxisAlignment.start,
					mainAxisSize: MainAxisSize.min,
					children: <Widget>[
						Row(
							children: <Widget>[
								Icon(icon, size: 14, color: tone),
								const SizedBox(width: 5),
								Expanded(
									child: Text(
										label.toUpperCase(),
										maxLines: 1,
										overflow: TextOverflow.ellipsis,
										style: const TextStyle(
											color: GlukColors.text2,
											fontSize: 10,
											fontWeight: FontWeight.w700,
											letterSpacing: 0.9,
										),
									),
								),
							],
						),
						const SizedBox(height: 7),
						Text(
							value,
							maxLines: 1,
							overflow: TextOverflow.ellipsis,
							style: TextStyle(color: tone, fontSize: 19, fontWeight: FontWeight.w800),
						),
					],
				),
			);
}

/// График: день — по часам, неделя и месяц — по дням.
class _TrafficChart extends StatelessWidget {
	const _TrafficChart({required this.points, required this.period, required this.russian});

	final List<TrafficPoint> points;
	final AnalyticsPeriod period;
	final bool russian;

	String _tick(TrafficPoint point) {
		final DateTime? t = point.start?.toUtc();
		if (t == null) return '—';
		final String two = t.day.toString().padLeft(2, '0');
		if (period == AnalyticsPeriod.day) return '${t.hour.toString().padLeft(2, '0')}:00';
		return '$two.${t.month.toString().padLeft(2, '0')}';
	}

	@override
	Widget build(BuildContext context) {
		if (points.isEmpty) {
			return _Empty(russian ? 'За этот период трафик не записан' : 'No traffic recorded for this period');
		}
		final int peak = points.fold<int>(
			0,
			(int m, TrafficPoint p) => math.max(m, math.max(p.downloadBytes, p.uploadBytes)),
		);
		if (peak <= 0) {
			return _Empty(russian ? 'За этот период трафик не записан' : 'No traffic recorded for this period');
		}
		const double chartHeight = 132;
		double bar(int value) =>
				value <= 0 ? 2 : (value / peak * chartHeight).clamp(3.0, chartHeight);

		return GlassPanel(
			radius: 18,
			padding: const EdgeInsets.fromLTRB(14, 13, 14, 11),
			child: Column(
				crossAxisAlignment: CrossAxisAlignment.stretch,
				children: <Widget>[
					Row(
						children: <Widget>[
							_Legend(colour: GlukColors.connected, label: russian ? 'Получено' : 'Downloaded'),
							const SizedBox(width: 12),
							_Legend(colour: GlukColors.violetLight, label: russian ? 'Отправлено' : 'Uploaded'),
							const Spacer(),
							Text(
								'${russian ? 'пик' : 'peak'} ${formatBytes(peak)}',
								style: const TextStyle(color: GlukColors.text2, fontSize: 10),
							),
						],
					),
					const SizedBox(height: 12),
					SizedBox(
						height: chartHeight,
						child: Row(
							crossAxisAlignment: CrossAxisAlignment.end,
							children: points.map((TrafficPoint p) {
								return Expanded(
									child: Tooltip(
										message: '${_utc(p.start)}\n'
												'↓ ${formatBytes(p.downloadBytes)}\n'
												'↑ ${formatBytes(p.uploadBytes)}',
										child: Padding(
											padding: const EdgeInsets.symmetric(horizontal: 1.2),
											child: Row(
												crossAxisAlignment: CrossAxisAlignment.end,
												children: <Widget>[
													Expanded(
														child: _Bar(height: bar(p.downloadBytes), tone: GlukColors.connected),
													),
													const SizedBox(width: 1.6),
													Expanded(
														child: _Bar(height: bar(p.uploadBytes), tone: GlukColors.violetLight),
													),
												],
											),
										),
									),
								);
							}).toList(),
						),
					),
					const SizedBox(height: 7),
					Container(height: 1, color: Colors.white.withOpacity(0.06)),
					const SizedBox(height: 6),
					Row(
						mainAxisAlignment: MainAxisAlignment.spaceBetween,
						children: <Widget>[
							Text(_tick(points.first), style: const TextStyle(color: GlukColors.text2, fontSize: 10)),
							Text(
								'${_tick(points[points.length ~/ 2])} UTC',
								style: const TextStyle(color: GlukColors.text2, fontSize: 10),
							),
							Text(_tick(points.last), style: const TextStyle(color: GlukColors.text2, fontSize: 10)),
						],
					),
				],
			),
		);
	}
}

class _Bar extends StatelessWidget {
	const _Bar({required this.height, required this.tone});

	final double height;
	final Color tone;

	@override
	Widget build(BuildContext context) => Container(
				height: height,
				decoration: BoxDecoration(
					borderRadius: const BorderRadius.vertical(top: Radius.circular(3)),
					gradient: LinearGradient(
						begin: Alignment.bottomCenter,
						end: Alignment.topCenter,
						colors: <Color>[tone.withOpacity(0.45), tone],
					),
				),
			);
}

class _Legend extends StatelessWidget {
	const _Legend({required this.colour, required this.label});

	final Color colour;
	final String label;

	@override
	Widget build(BuildContext context) => Row(
				mainAxisSize: MainAxisSize.min,
				children: <Widget>[
					Container(
						width: 8,
						height: 8,
						decoration: BoxDecoration(color: colour, borderRadius: BorderRadius.circular(3)),
					),
					const SizedBox(width: 5),
					Text(label, style: TextStyle(color: colour, fontSize: 11)),
				],
			);
}

/// Кто сколько «съел»: иконка устройства, доля и абсолютные цифры.
class _Devices extends StatelessWidget {
	const _Devices({required this.devices, required this.russian});

	final List<AnalyticsDevice> devices;
	final bool russian;

	@override
	Widget build(BuildContext context) {
		if (devices.isEmpty) {
			return _Empty(russian
					? 'За этот период трафик устройств не записан'
					: 'No device traffic was recorded for this period');
		}
		final int top = devices.fold<int>(
			0,
			(int m, AnalyticsDevice d) => math.max(m, d.downloadBytes + d.uploadBytes),
		);
		return Column(
			children: devices.map((AnalyticsDevice d) {
				final int total = d.downloadBytes + d.uploadBytes;
				return Padding(
					padding: const EdgeInsets.only(bottom: 8),
					child: GlassPanel(
						radius: 14,
						padding: const EdgeInsets.fromLTRB(11, 10, 12, 11),
						child: Column(
							crossAxisAlignment: CrossAxisAlignment.stretch,
							children: <Widget>[
								Row(
									children: <Widget>[
										Container(
											width: 34,
											height: 34,
											alignment: Alignment.center,
											decoration: BoxDecoration(
												color: GlukColors.violet.withOpacity(0.20),
												borderRadius: BorderRadius.circular(11),
											),
											child: Icon(accountDeviceIcon(d.platform), size: 18, color: GlukColors.violetLight),
										),
										const SizedBox(width: 10),
										Expanded(
											child: Column(
												crossAxisAlignment: CrossAxisAlignment.start,
												mainAxisSize: MainAxisSize.min,
												children: <Widget>[
													Text(
														d.deviceName.isEmpty
																? (russian ? 'Устройство' : 'Device')
																: d.deviceName,
														maxLines: 1,
														overflow: TextOverflow.ellipsis,
														style: const TextStyle(
															color: GlukColors.text0,
															fontSize: 13,
															fontWeight: FontWeight.w700,
														),
													),
													Text(
														d.platform.isEmpty ? '—' : d.platform,
														maxLines: 1,
														overflow: TextOverflow.ellipsis,
														style: const TextStyle(color: GlukColors.text1, fontSize: 11),
													),
												],
											),
										),
										const SizedBox(width: 8),
										Text(
											formatBytes(total),
											style: const TextStyle(
												color: GlukColors.text0,
												fontSize: 13,
												fontWeight: FontWeight.w800,
											),
										),
									],
								),
								const SizedBox(height: 9),
								ClipRRect(
									borderRadius: BorderRadius.circular(999),
									child: SizedBox(
										height: 6,
										child: Row(
											children: <Widget>[
												Expanded(
													flex: math.max(1, d.downloadBytes),
													child: const ColoredBox(color: GlukColors.connected),
												),
												Expanded(
													flex: math.max(1, d.uploadBytes),
													child: const ColoredBox(color: GlukColors.violetLight),
												),
												if (top > total)
													Expanded(
														flex: math.max(1, top - total),
														child: ColoredBox(color: Colors.white.withOpacity(0.05)),
													),
											],
										),
									),
								),
								const SizedBox(height: 7),
								Text(
									'↓ ${formatBytes(d.downloadBytes)}   ↑ ${formatBytes(d.uploadBytes)}',
									style: const TextStyle(color: GlukColors.text1, fontSize: 11),
								),
							],
						),
					),
				);
			}).toList(),
		);
	}
}

/// Сайты и категории со скрытием: сразу видны только самые тратные.
class _Domains extends StatefulWidget {
	const _Domains({required this.snapshot, required this.russian});

	final AnalyticsSnapshot snapshot;
	final bool russian;

	@override
	State<_Domains> createState() => _DomainsState();
}

class _DomainsState extends State<_Domains> {
	static const int _collapsed = 5;
	bool _open = false;
	bool _categories = false;

	bool get _ru => widget.russian;

	@override
	Widget build(BuildContext context) {
		final AnalyticsSnapshot d = widget.snapshot;
		if (!d.domainsEnabled) {
			return _Empty(_ru ? 'Учёт доменов отключён' : 'Domain accounting is disabled');
		}
		if (d.domains.isEmpty) {
			return _Empty(_ru ? 'Домены ещё не записаны' : 'No domains recorded yet');
		}
		final List<DomainUsage> shown =
				_open ? d.domains : d.domains.take(_collapsed).toList(growable: false);
		final int hidden = d.domains.length - shown.length;
		final int peak = d.domains.first.totalBytes;

		return Column(
			crossAxisAlignment: CrossAxisAlignment.stretch,
			children: <Widget>[
				Text(
					_ru
							? 'Самые тратные сайты за окно хранения ${d.domainWindowDays} дн. Это не выбранный период графика.'
							: 'Heaviest sites across a ${d.domainWindowDays}-day retention window. This is not the selected chart period.',
					style: const TextStyle(color: GlukColors.text2, fontSize: 11.5, height: 1.35),
				),
				const SizedBox(height: 10),
				for (final DomainUsage x in shown)
					Padding(
						padding: const EdgeInsets.only(bottom: 7),
						child: _DomainRow(item: x, peak: peak, russian: _ru),
					),
				if (hidden > 0 || _open)
					Align(
						alignment: Alignment.centerLeft,
						child: TextButton.icon(
							onPressed: () => setState(() => _open = !_open),
							icon: Icon(_open ? Icons.expand_less_rounded : Icons.expand_more_rounded, size: 18),
							label: Text(
								_open
										? (_ru ? 'Свернуть' : 'Collapse')
										: (_ru ? 'Показать ещё $hidden' : 'Show $hidden more'),
							),
						),
					),
				if (d.categories.isNotEmpty) ...<Widget>[
					Align(
						alignment: Alignment.centerLeft,
						child: TextButton.icon(
							onPressed: () => setState(() => _categories = !_categories),
							icon: Icon(_categories ? Icons.expand_less_rounded : Icons.expand_more_rounded, size: 18),
							label: Text(
								_categories
										? (_ru ? 'Скрыть категории' : 'Hide categories')
										: (_ru ? 'Категории (${d.categories.length})' : 'Categories (${d.categories.length})'),
							),
						),
					),
					if (_categories)
						Wrap(
							spacing: 7,
							runSpacing: 7,
							children: d.categories.map((CategoryUsage c) {
								return Container(
									padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
									decoration: BoxDecoration(
										color: GlukColors.violet.withOpacity(0.10),
										borderRadius: BorderRadius.circular(999),
										border: Border.all(color: GlukColors.violet.withOpacity(0.24)),
									),
									child: Text(
										'${c.category} · ${formatBytes(c.downloadBytes + c.uploadBytes)}',
										style: const TextStyle(color: GlukColors.text1, fontSize: 11),
									),
								);
							}).toList(),
						),
				],
			],
		);
	}
}

class _DomainRow extends StatelessWidget {
	const _DomainRow({required this.item, required this.peak, required this.russian});

	final DomainUsage item;
	final int peak;
	final bool russian;

	@override
	Widget build(BuildContext context) {
		final int total = item.totalBytes;
		final double share = peak <= 0 ? 0 : (total / peak).clamp(0.0, 1.0);
		return GlassPanel(
			radius: 13,
			padding: const EdgeInsets.fromLTRB(11, 9, 12, 10),
			child: Column(
				crossAxisAlignment: CrossAxisAlignment.stretch,
				children: <Widget>[
					Row(
						children: <Widget>[
							const Icon(Icons.language_rounded, size: 15, color: GlukColors.text2),
							const SizedBox(width: 8),
							Expanded(
								child: Text(
									item.domain,
									maxLines: 1,
									overflow: TextOverflow.ellipsis,
									style: const TextStyle(color: GlukColors.text0, fontSize: 12.5, fontWeight: FontWeight.w600),
								),
							),
							const SizedBox(width: 8),
							Text(
								formatBytes(total),
								style: const TextStyle(color: GlukColors.text0, fontSize: 12, fontWeight: FontWeight.w700),
							),
						],
					),
					const SizedBox(height: 7),
					ClipRRect(
						borderRadius: BorderRadius.circular(999),
						child: SizedBox(
							height: 5,
							child: Align(
								alignment: Alignment.centerLeft,
								child: FractionallySizedBox(
									widthFactor: share <= 0 ? 0.02 : share,
									child: const ColoredBox(color: GlukColors.violet),
								),
							),
						),
					),
					const SizedBox(height: 6),
					Text(
						'${item.category} · ${item.connections} ${russian ? 'соединений' : 'connections'}',
						style: const TextStyle(color: GlukColors.text2, fontSize: 10.5),
					),
				],
			),
		);
	}
}

/// Бюджет инфраструктуры — список карточек ПО СЕРВЕРАМ.
///
/// Сейчас сервер один, и управляющий сервер отдаёт один `budget`,
/// но рисуем мы его сразу как карточку конкретного сервера в списке.
/// Когда серверов станет 2-3, сюда придёт массив таких же
/// записей, и ни один экран переделывать не придётся.
class _Budgets extends StatelessWidget {
	const _Budgets({required this.budget, required this.russian, this.serverLabel});

	final ServiceBudget budget;
	final bool russian;
	final String? serverLabel;

	@override
	Widget build(BuildContext context) {
		final String label = (serverLabel == null || serverLabel!.isEmpty)
				? (russian ? 'Текущий сервер' : 'Current server')
				: serverLabel!;
		return Column(
			crossAxisAlignment: CrossAxisAlignment.stretch,
			children: <Widget>[
				Text(
					russian
							? 'Месячные траты сервиса по серверам. Это общий бюджет инфраструктуры, а не личная квота и не лимит тарифа.'
							: 'Monthly service spend per server. This is the shared infrastructure budget, not a personal quota or a plan limit.',
					style: const TextStyle(color: GlukColors.text2, fontSize: 11.5, height: 1.35),
				),
				const SizedBox(height: 10),
				_BudgetCard(budget: budget, russian: russian, server: label),
				const SizedBox(height: 8),
				Text(
					russian
							? 'Когда серверов станет больше, каждый получит свою карточку рядом с этой.'
							: 'As more servers come online, each one gets its own card next to this one.',
					style: const TextStyle(color: GlukColors.text2, fontSize: 11),
				),
			],
		);
	}
}

class _BudgetCard extends StatelessWidget {
	const _BudgetCard({required this.budget, required this.russian, required this.server});

	final ServiceBudget budget;
	final bool russian;
	final String server;

	@override
	Widget build(BuildContext context) {
		final double fraction = (budget.usedPercent / 100).clamp(0.0, 1.0);
		final Color tone = budget.usedPercent >= 90
				? GlukColors.danger
				: (budget.usedPercent >= 70 ? GlukColors.amber : GlukColors.connected);
		return GlassPanel(
			radius: 16,
			padding: const EdgeInsets.all(15),
			child: Column(
				crossAxisAlignment: CrossAxisAlignment.stretch,
				children: <Widget>[
					Row(
						children: <Widget>[
							const Icon(Icons.dns_rounded, size: 16, color: GlukColors.violetLight),
							const SizedBox(width: 8),
							Expanded(
								child: Text(
									server,
									maxLines: 1,
									overflow: TextOverflow.ellipsis,
									style: const TextStyle(color: GlukColors.text0, fontSize: 13.5, fontWeight: FontWeight.w700),
								),
							),
							Container(
								padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
								decoration: BoxDecoration(
									color: GlukColors.violet.withOpacity(0.16),
									borderRadius: BorderRadius.circular(999),
								),
								child: Text(
									russian ? 'только админ' : 'admin only',
									style: const TextStyle(color: GlukColors.violetLight, fontSize: 9.5, fontWeight: FontWeight.w700),
								),
							),
						],
					),
					const SizedBox(height: 12),
					if (!budget.available)
						Text(
							russian
									? 'Данные бюджета сейчас недоступны — нулевой расход не предполагается.'
									: 'Budget data is unavailable — zero usage is not assumed.',
							style: const TextStyle(color: GlukColors.text1, fontSize: 12),
						)
					else ...<Widget>[
						Row(
							crossAxisAlignment: CrossAxisAlignment.end,
							children: <Widget>[
								Text(
									formatBytes(budget.usedBytes),
									style: TextStyle(color: tone, fontSize: 20, fontWeight: FontWeight.w800),
								),
								const SizedBox(width: 6),
								Padding(
									padding: const EdgeInsets.only(bottom: 2),
									child: Text(
										'/ ${formatBytes(budget.budgetBytes)} · ${budget.usedPercent.toStringAsFixed(1)}%',
										style: const TextStyle(color: GlukColors.text1, fontSize: 12),
									),
								),
							],
						),
						const SizedBox(height: 10),
						ClipRRect(
							borderRadius: BorderRadius.circular(999),
							child: SizedBox(
								height: 8,
								child: Stack(
									children: <Widget>[
										ColoredBox(color: Colors.white.withOpacity(0.06)),
										FractionallySizedBox(
											widthFactor: fraction,
											child: ColoredBox(color: tone),
										),
									],
								),
							),
						),
						const SizedBox(height: 10),
						Text(
							'${_utc(budget.cycleStart)} — ${_utc(budget.cycleEnd)}',
							style: const TextStyle(color: GlukColors.text2, fontSize: 10.5),
						),
						Text(
							'${russian ? 'Обновлено' : 'Updated'}: ${_utc(budget.lastPolledAt)}',
							style: const TextStyle(color: GlukColors.text2, fontSize: 10.5),
						),
					],
				],
			),
		);
	}
}

class _Section extends StatelessWidget {
	const _Section(this.text);

	final String text;

	@override
	Widget build(BuildContext context) => Padding(
				padding: const EdgeInsets.only(top: 22, bottom: 10),
				child: Text(
					text.toUpperCase(),
					style: const TextStyle(
						color: GlukColors.text2,
						fontSize: 10.5,
						fontWeight: FontWeight.w800,
						letterSpacing: 1.1,
					),
				),
			);
}

class _Empty extends StatelessWidget {
	const _Empty(this.text);

	final String text;

	@override
	Widget build(BuildContext context) => Padding(
				padding: const EdgeInsets.symmetric(vertical: 16),
				child: Text(text, style: const TextStyle(color: GlukColors.text2, fontSize: 12.5)),
			);
}

class _Failed extends StatelessWidget {
	const _Failed({required this.russian, required this.onReload});

	final bool russian;
	final VoidCallback onReload;

	@override
	Widget build(BuildContext context) => Column(
				children: <Widget>[
					const SizedBox(height: 12),
					const Icon(Icons.insights_outlined, size: 30, color: GlukColors.text2),
					const SizedBox(height: 10),
					Text(
						russian ? 'Не удалось получить статистику' : 'Statistics could not be loaded',
						textAlign: TextAlign.center,
						style: const TextStyle(color: GlukColors.text1, fontSize: 13),
					),
					TextButton.icon(
						onPressed: onReload,
						icon: const Icon(Icons.refresh_rounded, size: 18),
						label: Text(russian ? 'Повторить' : 'Retry'),
					),
				],
			);
}

class _Skeleton extends StatelessWidget {
	const _Skeleton({required this.russian});

	final bool russian;

	@override
	Widget build(BuildContext context) => Semantics(
				label: russian ? 'Загрузка статистики' : 'Loading statistics',
				child: Column(
					crossAxisAlignment: CrossAxisAlignment.stretch,
					children: <Widget>[
						for (final double h in <double>[76, 168, 22, 62, 62])
							Container(
								height: h,
								margin: const EdgeInsets.only(bottom: 12),
								decoration: BoxDecoration(
									borderRadius: BorderRadius.circular(14),
									gradient: LinearGradient(
										colors: <Color>[
											GlukColors.violet.withOpacity(0.14),
											GlukColors.violet.withOpacity(0.04),
											GlukColors.violet.withOpacity(0.10),
										],
									),
								),
							),
					],
				),
			);
}
