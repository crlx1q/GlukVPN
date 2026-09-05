import 'package:flutter/material.dart';
import '../../models/account_insights.dart';
import '../../services/api_client.dart';
import '../../theme/tokens.dart';
import '../../utils/format.dart';
import '../../widgets/glass.dart';
import '../i18n/desktop_strings.dart';
import '../state/usage_store.dart';

class DesktopStatsScreen extends StatefulWidget {
  const DesktopStatsScreen({super.key, required this.api, required this.usage, required this.strings, this.loading = false, this.reduceMotion = false});
  final ApiClient api;
  final UsageSnapshot usage;
  final DesktopStrings strings;
  final bool loading, reduceMotion;
  @override State<DesktopStatsScreen> createState() => _DesktopStatsScreenState();
}
class _DesktopStatsScreenState extends State<DesktopStatsScreen> {
  AnalyticsPeriod period = AnalyticsPeriod.day;
  AnalyticsSnapshot? data;
  Object? error;
  bool loading = true, _busy = false, _pending = false;
  int generation = 0;
  bool get ru => widget.strings.isRussian;
  @override void initState() { super.initState(); widget.api.authRevision.addListener(_reload); _reload(); }
  @override void didUpdateWidget(covariant DesktopStatsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.api != widget.api) { oldWidget.api.authRevision.removeListener(_reload); widget.api.authRevision.addListener(_reload); _reload(); }
  }
  void _reload() {
    if (!mounted) return;
    generation++;
    setState(() { loading = widget.api.isAuthenticated; data = null; error = null; });
    if (!widget.api.isAuthenticated) { _pending = false; return; }
    if (_busy) { _pending = true; return; }
    _fetch();
  }
  Future<void> _fetch() async {
    _busy = true; _pending = false;
    final g = generation, requestedPeriod = period;
    try {
      final next = await widget.api.analytics(requestedPeriod);
      if (!mounted || g != generation) return;
      if (next.period != requestedPeriod.name) throw const FormatException('Analytics period mismatch');
      setState(() => data = next);
    } catch (e) { if (mounted && g == generation) setState(() => error = e); }
    finally {
      _busy = false;
      if (mounted) {
        if (_pending && widget.api.isAuthenticated) { _fetch(); }
        else if (g == generation) setState(() => loading = false);
      }
    }
  }
  @override void dispose() { generation++; widget.api.authRevision.removeListener(_reload); super.dispose(); }
  @override Widget build(BuildContext context) {
    final d = data;
    return ListView(padding: const EdgeInsets.all(GlukSizes.pagePadding), children: <Widget>[
      Wrap(alignment: WrapAlignment.spaceBetween, crossAxisAlignment: WrapCrossAlignment.center, spacing: 18, runSpacing: 10, children: <Widget>[
        Text(widget.strings.statistics, style: const TextStyle(color: GlukColors.text0, fontSize: 20, fontWeight: FontWeight.w600)),
        SegmentedButton<AnalyticsPeriod>(segments: <ButtonSegment<AnalyticsPeriod>>[
          ButtonSegment(value: AnalyticsPeriod.day, label: Text(ru ? 'День' : 'Day')),
          ButtonSegment(value: AnalyticsPeriod.week, label: Text(ru ? 'Неделя' : 'Week')),
          ButtonSegment(value: AnalyticsPeriod.month, label: Text(ru ? 'Месяц' : 'Month')),
        ], selected: <AnalyticsPeriod>{period}, onSelectionChanged: (v) { if (period != v.first) { period = v.first; _reload(); } }),
      ]),
      const SizedBox(height: 18),
      if (loading) _StatsLoading(russian: ru)
      else if (error != null || d == null) Column(children: <Widget>[
        const Icon(Icons.insights_outlined, size: 32, color: GlukColors.text2),
        const SizedBox(height: 10), Text(ru ? 'Не удалось получить аналитику аккаунта' : 'Account analytics could not be loaded'),
        TextButton.icon(onPressed: _reload, icon: const Icon(Icons.refresh), label: Text(ru ? 'Повторить' : 'Retry')),
      ]) else ...<Widget>[
        if (d.partial) _Notice(ru ? 'Неполная история: измерения доступны с ${_utc(d.coverageSince)}. История до запуска не восстанавливается.' : 'Partial history: measurements start at ${_utc(d.coverageSince)}. Earlier usage is not reconstructed.'),
        Row(children: <Widget>[
          Expanded(child: _Metric('↓ ${widget.strings.downloaded}', formatBytes(d.downloadBytes), GlukColors.connected)),
          const SizedBox(width: 12), Expanded(child: _Metric('↑ ${widget.strings.uploaded}', formatBytes(d.uploadBytes), GlukColors.violetLight)),
        ]),
        const SizedBox(height: 14), _Chart(points: d.series, period: period, russian: ru),
        _Title(ru ? 'По устройствам' : 'By device'),
        if (d.devices.isEmpty) _Empty(ru ? 'За этот период трафик устройств не записан' : 'No device traffic was recorded for this period')
        else ...d.devices.map((x) => ListTile(contentPadding: EdgeInsets.zero, leading: const Icon(Icons.devices), title: Text(x.deviceName), subtitle: Text(x.platform), trailing: Text('↓ ${formatBytes(x.downloadBytes)}\n↑ ${formatBytes(x.uploadBytes)}', textAlign: TextAlign.end))),
        _Title(ru ? 'Домены и категории' : 'Domains and categories'),
        Text(ru ? 'Сохранённые итоги сессий за окно хранения ${d.domainWindowDays} дн. Это не выбранный период графика.' : 'Retained session totals across a ${d.domainWindowDays}-day retention window. This is not the selected chart period.', style: const TextStyle(color: GlukColors.text2, fontSize: 12)),
        if (!d.domainsEnabled) _Empty(ru ? 'Учёт доменов отключён' : 'Domain accounting is disabled')
        else if (d.domains.isEmpty) _Empty(ru ? 'Сниффер ещё не записал домены' : 'The sniffer has not recorded any domains yet')
        else ...d.domains.take(12).map((x) => ListTile(contentPadding: EdgeInsets.zero, leading: _Favicon(x.faviconUrl), title: Text(x.domain), subtitle: Text('${x.category} · ${x.connections} ${ru ? 'соединений' : 'connections'}'), trailing: Text(formatBytes(x.downloadBytes + x.uploadBytes)))),
        if (d.domainsEnabled && d.categories.isNotEmpty) ...d.categories.map((x) => ListTile(contentPadding: EdgeInsets.zero, leading: const Icon(Icons.category_outlined, size: 20), title: Text(x.category), trailing: Text(formatBytes(x.downloadBytes + x.uploadBytes)))),
        _Title(ru ? 'Месячный бюджет инфраструктуры' : 'Monthly infrastructure budget'),
        if (!d.budget.available) _Empty(ru ? 'Данные бюджета сейчас недоступны — нулевой расход не предполагается' : 'Budget data is unavailable — zero usage is not assumed')
        else GlassPanel(radius: 16, padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
          Text('${formatBytes(d.budget.usedBytes)} / ${formatBytes(d.budget.budgetBytes)} · ${d.budget.usedPercent.toStringAsFixed(1)}%', style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 10), LinearProgressIndicator(value: (d.budget.usedPercent / 100).clamp(0.0, 1.0)),
          const SizedBox(height: 10), Text('${_utc(d.budget.cycleStart)} — ${_utc(d.budget.cycleEnd)}', style: const TextStyle(color: GlukColors.text2, fontSize: 11)),
          Text('${ru ? 'Обновлено' : 'Updated'}: ${_utc(d.budget.lastPolledAt)}', style: const TextStyle(color: GlukColors.text2, fontSize: 11)),
        ])),
        const SizedBox(height: 8), Text(ru ? 'Общий бюджет OCI для сервиса, не личная квота и не лимит вашего тарифа.' : 'Shared OCI service budget, not a personal quota or a limit on your plan.', style: const TextStyle(color: GlukColors.text2, fontSize: 12)),
        Align(alignment: Alignment.centerRight, child: TextButton.icon(onPressed: _reload, icon: const Icon(Icons.refresh, size: 18), label: Text(ru ? 'Обновить' : 'Refresh'))),
      ],
      const SizedBox(height: 20),
    ]);
  }
}
String _utc(DateTime? value) => value == null ? '—' : '${value.toUtc().toIso8601String().substring(0, 16).replaceFirst('T', ' ')} UTC';
class _Chart extends StatelessWidget {
  const _Chart({required this.points, required this.period, required this.russian});
  final List<TrafficPoint> points;
  final AnalyticsPeriod period;
  final bool russian;
  String tick(TrafficPoint point) {
    final t = point.start?.toUtc(); if (t == null) return '—';
    return period == AnalyticsPeriod.day ? '${t.hour.toString().padLeft(2, '0')}:00' : '${t.day.toString().padLeft(2, '0')}.${t.month.toString().padLeft(2, '0')}';
  }
  @override Widget build(BuildContext context) {
    final peak = points.fold<int>(0, (m, p) => <int>[m, p.downloadBytes, p.uploadBytes].reduce((a, b) => a > b ? a : b));
    if (peak <= 0) return _Empty(russian ? 'За выбранный период нет записанного трафика' : 'No traffic was recorded for the selected period');
    double height(int value) => value <= 0 ? 0 : (value / peak * 112).clamp(1.0, 112.0).toDouble();
    return GlassPanel(radius: 18, padding: const EdgeInsets.all(14), child: Column(children: <Widget>[
      Row(children: <Widget>[
        Text(russian ? '↓ Получено' : '↓ Downloaded', style: const TextStyle(color: GlukColors.connected, fontSize: 11)),
        const SizedBox(width: 12), Text(russian ? '↑ Отправлено' : '↑ Uploaded', style: const TextStyle(color: GlukColors.violetLight, fontSize: 11)),
        const Spacer(), Text(formatBytes(peak), style: const TextStyle(color: GlukColors.text2, fontSize: 10)),
      ]),
      const SizedBox(height: 10), SizedBox(height: 112, child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: points.map((p) => Expanded(child: Tooltip(message: '${_utc(p.start)}\n↓ ${formatBytes(p.downloadBytes)}\n↑ ${formatBytes(p.uploadBytes)}', child: Padding(padding: const EdgeInsets.symmetric(horizontal: 1), child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: <Widget>[
        Expanded(child: Container(height: height(p.downloadBytes), color: GlukColors.connected)),
        const SizedBox(width: 1), Expanded(child: Container(height: height(p.uploadBytes), color: GlukColors.violetLight)),
      ]))))).toList())),
      const Divider(height: 8), Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: <Widget>[Text(tick(points.first)), Text('${tick(points[points.length ~/ 2])} UTC'), Text(tick(points.last))].map((w) => DefaultTextStyle(style: const TextStyle(color: GlukColors.text2, fontSize: 10), child: w)).toList()),
    ]));
  }
}
class _StatsLoading extends StatelessWidget {
  const _StatsLoading({required this.russian}); final bool russian;
  @override Widget build(BuildContext context) => Semantics(label: russian ? 'Загрузка статистики' : 'Loading statistics', child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
    for (final h in <double>[82, 174, 22, 48, 48]) Container(height: h, margin: const EdgeInsets.only(bottom: 14), decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), gradient: LinearGradient(colors: <Color>[GlukColors.violet.withOpacity(.14), GlukColors.violet.withOpacity(.04), GlukColors.violet.withOpacity(.1)]))),
  ]));
}
class _Metric extends StatelessWidget { const _Metric(this.label, this.value, this.color); final String label, value; final Color color; @override Widget build(BuildContext c) => GlassPanel(radius: 16, padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[Text(label, style: const TextStyle(color: GlukColors.text2)), const SizedBox(height: 5), Text(value, style: TextStyle(color: color, fontSize: 20, fontWeight: FontWeight.bold))])); }
class _Title extends StatelessWidget { const _Title(this.text); final String text; @override Widget build(BuildContext c) => Padding(padding: const EdgeInsets.only(top: 22, bottom: 8), child: Text(text.toUpperCase(), style: const TextStyle(color: GlukColors.text2, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1.1))); }
class _Empty extends StatelessWidget { const _Empty(this.text); final String text; @override Widget build(BuildContext c) => Padding(padding: const EdgeInsets.symmetric(vertical: 20), child: Text(text, style: const TextStyle(color: GlukColors.text2))); }
class _Notice extends StatelessWidget { const _Notice(this.text); final String text; @override Widget build(BuildContext c) => Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(text, style: const TextStyle(color: GlukColors.amber))); }
class _Favicon extends StatelessWidget {
  const _Favicon(this.url); final String? url;
  @override Widget build(BuildContext c) {
    final u = Uri.tryParse(url ?? '');
    if (u == null || u.scheme != 'https' || u.host != 'icons.duckduckgo.com' || u.userInfo.isNotEmpty || u.port != 443 || !u.path.startsWith('/ip3/') || u.hasQuery) return const Icon(Icons.language);
    return Image.network(u.toString(), width: 20, height: 20, errorBuilder: (_, __, ___) => const Icon(Icons.language));
  }
}
