import 'package:flutter/material.dart';

import '../../models/account_insights.dart';
import '../../services/api_client.dart';
import '../../widgets/usage_stats.dart';
import '../i18n/desktop_strings.dart';
import '../state/usage_store.dart';

/// Экран статистики на Windows.
///
/// Весь UI живёт в [UsageStatsView] — том же самом виджете, что и на
/// телефоне. Здесь осталась только загрузка данных: пока экранов
/// было два, любая правка графика требовала двух правок.
class DesktopStatsScreen extends StatefulWidget {
  const DesktopStatsScreen({
    super.key,
    required this.api,
    required this.usage,
    required this.strings,
    this.loading = false,
    this.reduceMotion = false,
    this.serverLabel,
  });

  final ApiClient api;
  final UsageSnapshot usage;
  final DesktopStrings strings;
  final bool loading, reduceMotion;

  /// Сервер, к которому относятся траты инфраструктуры.
  final String? serverLabel;

  @override
  State<DesktopStatsScreen> createState() => _DesktopStatsScreenState();
}

class _DesktopStatsScreenState extends State<DesktopStatsScreen> {
  AnalyticsPeriod period = AnalyticsPeriod.day;
  AnalyticsSnapshot? data;
  Object? error;
  bool loading = true, _busy = false, _pending = false;
  int generation = 0;

  bool get ru => widget.strings.isRussian;

  @override
  void initState() {
    super.initState();
    widget.api.authRevision.addListener(_reload);
    _reload();
  }

  @override
  void didUpdateWidget(covariant DesktopStatsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.api != widget.api) {
      oldWidget.api.authRevision.removeListener(_reload);
      widget.api.authRevision.addListener(_reload);
      _reload();
    }
  }

  void _reload() {
    if (!mounted) return;
    generation++;
    setState(() {
      loading = widget.api.isAuthenticated;
      data = null;
      error = null;
    });
    if (!widget.api.isAuthenticated) {
      _pending = false;
      return;
    }
    if (_busy) {
      _pending = true;
      return;
    }
    _fetch();
  }

  Future<void> _fetch() async {
    _busy = true;
    _pending = false;
    final int g = generation;
    final AnalyticsPeriod requestedPeriod = period;
    try {
      final AnalyticsSnapshot next = await widget.api.analytics(requestedPeriod);
      if (!mounted || g != generation) return;
      // Ответ на другой период не должен попасть в график: иначе
      // неделя может нарисоваться как день.
      if (next.period != requestedPeriod.name) {
        throw const FormatException('Analytics period mismatch');
      }
      setState(() => data = next);
    } catch (e) {
      if (mounted && g == generation) setState(() => error = e);
    } finally {
      _busy = false;
      if (mounted) {
        if (_pending && widget.api.isAuthenticated) {
          _fetch();
        } else if (g == generation) {
          setState(() => loading = false);
        }
      }
    }
  }

  @override
  void dispose() {
    generation++;
    widget.api.authRevision.removeListener(_reload);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => UsageStatsView(
        title: widget.strings.statistics,
        period: period,
        data: data,
        loading: loading,
        error: error,
        russian: ru,
        serverLabel: widget.serverLabel,
        onReload: _reload,
        onPeriod: (AnalyticsPeriod value) {
          if (period == value) return;
          period = value;
          _reload();
        },
      );
}
