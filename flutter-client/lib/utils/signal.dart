import '../models/models.dart';

/// Уровень сигнала узла — три деления, как у телефона.
///
/// Считается только из того, что мы действительно знаем: онлайн ли узел,
/// какую нагрузку он отдал в heartbeat и какой round-trip только что
/// измерил сам клиент. Никогда — из страны узла: сервер во Франкфурте
/// с пингом 400 мс заслуживает одно деление.
///
/// Шкала пинга одна на телефон, ПК, расширение и сайт: [pingGreenMs] и
/// [pingAmberMs] из `models/models.dart`. Раньше здесь были свои 40/220, а у
/// `pingLevelFor` — свои 80/180: один и тот же сервер получал цифру одного
/// цвета и деления другого в одной и той же строке списка.
enum SignalStrength {
	/// Оффлайн, выключен или иначе недоступен: все деления серые.
	offline,

	/// Пинг выше [pingAmberMs] либо узел практически полон.
	weak,

	/// Середина шкалы: жёлтая зона пинга или занятый узел.
	fair,

	/// Пинг в зелёной зоне и на узле есть запас.
	strong,

	/// Замера ещё не было. Это не «средний сервер», а «неизвестно»:
	/// деления серые, пока не придёт цифра.
	unknown,
}

extension SignalStrengthDisplay on SignalStrength {
	/// Сколько из трёх делений горит.
	int get bars {
		switch (this) {
			case SignalStrength.strong:
				return 3;
			case SignalStrength.fair:
				return 2;
			case SignalStrength.weak:
				return 1;
			case SignalStrength.unknown:
				// Два деления, но серым: форма не прыгает, когда придёт замер,
				// а цвет ничего не обещает.
				return 2;
			case SignalStrength.offline:
				return 0;
		}
	}

	/// Читается скринридером и годится для подписи.
	String get label {
		switch (this) {
			case SignalStrength.strong:
				return 'Excellent connection';
			case SignalStrength.fair:
				return 'Good connection';
			case SignalStrength.weak:
				return 'Weak connection';
			case SignalStrength.unknown:
				return 'Latency not measured';
			case SignalStrength.offline:
				return 'Unavailable';
		}
	}
}

/// Ниже этого пинг уже не улучшить — вершина непрерывной оценки.
const double signalGoodPingMs = 30;

/// Здесь непрерывная оценка падает до нуля. Совпадает с границей
/// красной зоны [pingAmberMs] не случайно: авто-выбор и цвет обязаны
/// считать плохим одно и то же.
const double signalBadPingMs = pingAmberMs * 1.0;

/// Нагрузка ниже этой — свободный запас.
const double signalGoodLoadPercent = 40;

/// На этой нагрузке узел фактически полон.
const double signalBadLoadPercent = 95;

/// Узел занят: три деления ему больше не положены, каким бы ни был пинг.
const double signalBusyLoadPercent = 70;

/// Узел почти полон: одно деление независимо от пинга.
const double signalCrowdedLoadPercent = 85;

/// Латентность весит больше: её чувствуют задолго до того, как заметят
/// половину занятого узла.
const double signalPingWeight = 0.65;
const double signalLoadWeight = 0.35;

/// Оценка при отсутствии замера — сознательно серединная: узел ни наказан,
/// ни обласкан за то, что его не успели измерить.
const double signalUnknownPingScore = 0.55;

/// 1 на [good] и лучше, 0 на [bad] и хуже, линейно между.
double _grade(double value, double good, double bad) {
	if (bad == good) return 1;
	return ((bad - value) / (bad - good)).clamp(0.0, 1.0);
}

/// Непрерывное качество 0..1. Нужно авто-выбору и тестам: там, где надо
/// сравнить два узла, три корзины слишком грубы.
double signalScore({num? pingMs, num loadPercent = 0}) {
	final double ping = pingMs == null
			? signalUnknownPingScore
			: _grade(pingMs.toDouble(), signalGoodPingMs, signalBadPingMs);
	final double load = _grade(
		loadPercent.toDouble(),
		signalGoodLoadPercent,
		signalBadLoadPercent,
	);
	return ping * signalPingWeight + load * signalLoadWeight;
}

/// Три деления для узла.
///
/// [online] — состояние heartbeat, [available] — политика (включён, есть
/// место, к нему можно подключиться); любой из двух false даёт серые
/// деления: число делений не должно обещать сервер, на который нельзя
/// попасть.
///
/// Уровень берётся из той же шкалы, что и цвет цифры рядом: до
/// [pingGreenMs] — три деления, до [pingAmberMs] — два, выше — одно.
/// Нагрузка умеет только снимать уровень, но не добавлять: 20 мс на узле,
/// забитом на 93 %, — это не три деления, а усреднение прятало бы плохую
/// половину за хорошей.
///
/// Без замера результат — [SignalStrength.unknown]. Прежние «два жёлтых
/// деления по умолчанию» делали всю ленту серверов одинаково жёлтой на
/// ПК и телефоне — цвет без единого измерения.
SignalStrength signalStrengthFor({
	required bool online,
	bool available = true,
	num? pingMs,
	num loadPercent = 0,
}) {
	if (!online || !available) return SignalStrength.offline;

	// Ноль и отрицательное — не замер, а мусор в данных.
	if (pingMs == null || pingMs <= 0) return SignalStrength.unknown;

	final double ms = pingMs.toDouble();
	final double load = loadPercent.toDouble();

	final SignalStrength byPing = ms <= pingGreenMs
			? SignalStrength.strong
			: (ms <= pingAmberMs ? SignalStrength.fair : SignalStrength.weak);

	if (load >= signalCrowdedLoadPercent) return SignalStrength.weak;
	if (load >= signalBusyLoadPercent && byPing == SignalStrength.strong) {
		return SignalStrength.fair;
	}
	return byPing;
}
