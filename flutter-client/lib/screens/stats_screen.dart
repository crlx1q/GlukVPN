import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../i18n/app_strings.dart';
import '../models/account_insights.dart';
import '../models/models.dart';
import '../services/api_client.dart';
import '../state/auth_controller.dart';
import '../state/vpn_controller.dart';
import '../theme/tokens.dart';
import '../utils/geo_dictionary.dart';
import '../widgets/usage_stats.dart';

/// Статистика использования на телефоне.
///
/// Раньше такого экрана на телефоне вообще не было — цифры жили
/// только на Windows. Рисует его тот же [UsageStatsView], что и на ПК,
/// поэтому площадки не могут разойтись по виду.
class StatsScreen extends StatefulWidget {
  const StatsScreen({super.key});

  @override
  State<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends State<StatsScreen> {
  late final ApiClient _api;

  AnalyticsPeriod _period = AnalyticsPeriod.day;
  AnalyticsSnapshot? _data;
  Object? _error;
  bool _loading = true, _busy = false, _pending = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _api = context.read<AuthController>().api;
    _api.authRevision.addListener(_reload);
    _reload();
  }

  @override
  void dispose() {
    _generation++;
    _api.authRevision.removeListener(_reload);
    super.dispose();
  }

  void _reload() {
    if (!mounted) return;
    _generation++;
    setState(() {
      _loading = _api.isAuthenticated;
      _data = null;
      _error = null;
    });
    if (!_api.isAuthenticated) {
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
    final int generation = _generation;
    final AnalyticsPeriod requested = _period;
    try {
      final AnalyticsSnapshot next = await _api.analytics(requested);
      if (!mounted || generation != _generation) return;
      // Ответ на другой период не должен попасть в график.
      if (next.period != requested.name) {
        throw const FormatException('Analytics period mismatch');
      }
      setState(() => _data = next);
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _error = error);
      }
    } finally {
      _busy = false;
      if (mounted) {
        if (_pending && _api.isAuthenticated) {
          _fetch();
        } else if (generation == _generation) {
          setState(() => _loading = false);
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppStrings s = context.strings;
    final VpnNodeInfo? node = context.watch<VpnController>().selectedNode;
    // Название сервера для блока бюджета: «Франкфурт, Германия», не
    // внутренний идентификатор узла.
    final String? server = node == null
        ? null
        : formatNodeLocation(
            city: node.city,
            countryCode: node.countryCode,
            countryName: node.country,
            region: node.region,
            russian: s.isRussian,
          );
    return Scaffold(
      backgroundColor: GlukColors.pageBg,
      appBar: AppBar(
        title: Text(s.isRussian ? 'Статистика' : 'Statistics'),
        backgroundColor: Colors.transparent,
      ),
      body: UsageStatsView(
        title: s.isRussian ? 'Статистика использования' : 'Usage statistics',
        period: _period,
        data: _data,
        loading: _loading,
        error: _error,
        russian: s.isRussian,
        serverLabel: server,
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        onReload: _reload,
        onPeriod: (AnalyticsPeriod value) {
          if (_period == value) return;
          _period = value;
          _reload();
        },
      ),
    );
  }
}
