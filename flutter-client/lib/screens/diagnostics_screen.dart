import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import '../models/models.dart';
import '../services/api_client.dart';
import '../services/vpn_service.dart';
import '../theme/tokens.dart';

typedef DiagnosticsProbe = Future<DiagnosticResult> Function();
enum DiagnosticState { running, ok, warning, failed }
class DiagnosticResult {
  const DiagnosticResult(this.state, this.detail, {this.tip});
  final DiagnosticState state;
  final String detail;
  final String? tip;
}
class DiagnosticStep {
  const DiagnosticStep(this.name, this.probe);
  final String name;
  final DiagnosticsProbe probe;
}
DiagnosticState summarizeDiagnostics(Iterable<DiagnosticResult> results, {int expected = 8}) {
  final rows = results.toList(growable: false);
  if (rows.any((r) => r.state == DiagnosticState.failed)) return DiagnosticState.failed;
  if (rows.length != expected || rows.any((r) => r.state != DiagnosticState.ok)) return DiagnosticState.warning;
  return DiagnosticState.ok;
}

/// Checks report exactly what was observed. Neither an installed TUN nor a
/// successful OS DNS lookup proves that all traffic or DNS traverses the VPN.
class DiagnosticsRunner {
  DiagnosticsRunner({required this.api, required this.node, required this.tunnelStage, List<DiagnosticStep>? steps}) : customSteps = steps;
  final ApiClient api;
  final VpnNodeInfo? node;
  final Future<TunnelStage> Function() tunnelStage;
  final List<DiagnosticStep>? customSteps;

  List<DiagnosticStep> build({bool russian = false}) {
    if (customSteps != null) return customSteps!;
    String tr(String ru, String en) => russian ? ru : en;
    final observed = <DiagnosticResult>[];
    Future<String?>? exitProbe;
    Future<String?> exitIp() => exitProbe ??= api.probeExitIp();
    Future<Set<String>> expectedIps() async {
      final n = node;
      if (n == null) return <String>{};
      final published = InternetAddress.tryParse(n.publicIp);
      if (published != null) return <String>{published.address};
      if (n.host.isEmpty) return <String>{};
      return (await InternetAddress.lookup(n.host)).map((a) => a.address).toSet();
    }
    DiagnosticResult warning(String ru, String en, [String? tip]) => DiagnosticResult(DiagnosticState.warning, tr(ru, en), tip: tip);
    final retryTip = tr('Проверьте сеть и повторите. При техработах дождитесь восстановления сервиса.', 'Check your connection and retry. During maintenance, wait for the service to recover.');
    DiagnosticStep step(String ru, String en, DiagnosticsProbe probe) => DiagnosticStep(tr(ru, en), () async {
      DiagnosticResult result;
      try { result = await probe().timeout(const Duration(seconds: 9)); }
      on ApiException catch (e) {
        result = DiagnosticResult(DiagnosticState.failed, e.statusCode == 401 || e.statusCode == 403 ? tr('Сервер отклонил авторизацию', 'The server rejected authentication') : tr('Проверка API не удалась', 'The API check failed'), tip: e.statusCode == 401 || e.statusCode == 403 ? tr('Войдите в аккаунт заново.', 'Sign in again.') : retryTip);
      } on TimeoutException {
        result = DiagnosticResult(DiagnosticState.failed, tr('Превышено время ожидания', 'The check timed out'), tip: retryTip);
      } catch (_) {
        result = DiagnosticResult(DiagnosticState.failed, tr('Сетевой запрос не выполнен', 'The network request failed'), tip: retryTip);
      }
      observed.add(result);
      return result;
    });
    Future<DiagnosticResult> nodeTcp() async {
      final n = node;
      final port = n?.gatewayPort;
      if (n == null || port == null || port <= 0 || port > 65535) return warning('TCP-порт шлюза не опубликован. WireGuard использует UDP, а не TCP.', 'No TCP gateway port is published. WireGuard uses UDP, not TCP.');
      final host = n.gatewayHost?.isNotEmpty == true ? n.gatewayHost! : n.host;
      if (host.isEmpty) return warning('Адрес шлюза не опубликован', 'No gateway address is published');
      final watch = Stopwatch()..start();
      final socket = await Socket.connect(host, port, timeout: const Duration(seconds: 4));
      socket.destroy();
      return DiagnosticResult(DiagnosticState.ok, tr('Узел ответил по TCP/$port за ${watch.elapsedMilliseconds} мс', 'Node TCP/$port responded in ${watch.elapsedMilliseconds} ms'));
    }
    return <DiagnosticStep>[
      step('Интернет', 'Internet', () async {
        final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
        try {
          final request = await client.getUrl(Uri.https('www.gstatic.com', '/generate_204'));
          request.followRedirects = false;
          final response = await request.close().timeout(const Duration(seconds: 4));
          await response.drain<void>().timeout(const Duration(seconds: 4));
          if (response.statusCode == 204) return DiagnosticResult(DiagnosticState.ok, tr('Независимый HTTPS-сервис доступен', 'An independent HTTPS service is reachable'));
          return warning('HTTPS-проверка перенаправлена или ограничена. Возможен портал входа Wi-Fi.', 'The HTTPS probe was redirected or restricted. A Wi-Fi sign-in portal may be present.', retryTip);
        } finally { client.close(force: true); }
      }),
      step('API сервиса', 'Service API', () async {
        final healthy = await api.health();
        return DiagnosticResult(healthy ? DiagnosticState.ok : DiagnosticState.failed, healthy ? tr('API ответил на проверку здоровья', 'The API health check succeeded') : tr('API не подтвердил работоспособность', 'The API did not confirm healthy status'), tip: healthy ? null : retryTip);
      }),
      step('Авторизация и токен', 'Authentication and token', () async {
        await api.me();
        return DiagnosticResult(DiagnosticState.ok, tr('Сервер подтвердил текущую авторизацию', 'The server accepted the current authenticated session'));
      }),
      step('Доступность VPN-ноды', 'VPN node reachability', nodeTcp),
      step('Доступность туннеля', 'Tunnel availability', () async {
        if (await tunnelStage() != TunnelStage.connected) return warning('Локальный VPN-движок не подтверждает подключение', 'The local VPN engine does not report a connection', tr('Подключите VPN и повторите проверку.', 'Connect the VPN and retry.'));
        final status = await api.status();
        if (!status.connected) return warning('Движок запущен, но серверная VPN-сессия закрыта', 'The engine is running, but the server-side VPN session is closed', retryTip);
        final actual = InternetAddress.tryParse(await exitIp() ?? '');
        final expected = await expectedIps();
        if (actual == null || expected.isEmpty || !expected.contains(actual.address)) return warning('Сессия открыта, но прохождение проверочного трафика через ноду не подтверждено', 'The session is open, but probe traffic through the node is not verified', tr('Проверьте раздельное туннелирование и результат проверки маршрута ниже.', 'Review split tunneling and the routing check below.'));
        return DiagnosticResult(DiagnosticState.ok, tr('Движок, серверная сессия и выход через ноду подтверждены', 'The engine, server session and exit through the node are verified'));
      }),
      step('DNS внутри туннеля', 'DNS inside the tunnel', () async {
        if (await tunnelStage() != TunnelStage.connected) return warning('Не проверено: VPN отключён', 'Not checked: the VPN is disconnected');
        final addresses = await InternetAddress.lookup('example.com');
        if (addresses.isEmpty) return DiagnosticResult(DiagnosticState.failed, tr('DNS не вернул адрес', 'DNS returned no address'), tip: tr('Переподключитесь и проверьте настройки DNS.', 'Reconnect and review DNS settings.'));
        return warning('DNS отвечает. Системный API не доказывает маршрут DNS через VPN: возможны кэш или обход туннеля.', 'DNS responds. The system API cannot prove the DNS path through the VPN: caching or bypass is possible.', tr('Проверьте DNS-настройки туннеля; этот результат не является проверкой отсутствия DNS-утечек.', 'Review tunnel DNS settings; this is not a DNS-leak verification.'));
      }),
      step('Внешний IP и маршрутизация', 'Exit IP and routing', () async {
        if (await tunnelStage() != TunnelStage.connected) return warning('Не проверено: VPN отключён', 'Not checked: the VPN is disconnected');
        final actual = InternetAddress.tryParse(await exitIp() ?? '');
        final expected = await expectedIps();
        if (actual == null || expected.isEmpty) return warning('Недостаточно данных для сравнения внешнего IP с нодой', 'Insufficient data to compare the exit IP with the node');
        final matches = expected.contains(actual.address);
        return DiagnosticResult(matches ? DiagnosticState.ok : DiagnosticState.warning, matches ? tr('Внешний IP совпадает с нодой: ${actual.address}', 'Exit IP matches the node: ${actual.address}') : tr('Проверочный трафик выходит не через выбранную ноду: ${actual.address}', 'Probe traffic does not exit through the selected node: ${actual.address}'), tip: matches ? null : tr('При раздельном туннелировании это может быть ожидаемо. Иначе переподключите VPN.', 'Split tunneling may intentionally cause this. Otherwise reconnect the VPN.'));
      }),
      step('Проверка порта провайдера', 'ISP port check', () async {
        final result = await nodeTcp();
        if (result.state != DiagnosticState.ok) return result;
        if (await tunnelStage() == TunnelStage.connected) return warning('${result.detail}. Прямой путь провайдера не проверен при активном VPN.', '${result.detail}. The direct ISP path was not tested while the VPN is active.');
        return DiagnosticResult(DiagnosticState.ok, '${result.detail}. ${tr('Проверен только этот TCP-порт; UDP и остальные порты не проверялись.', 'Only this TCP port was tested; UDP and other ports were not checked.')}');
      }),
      DiagnosticStep(tr('Общее состояние', 'Overall health'), () async {
        final state = summarizeDiagnostics(observed);
        return DiagnosticResult(state, state == DiagnosticState.ok ? tr('Все выполненные проверки успешны', 'All completed checks succeeded') : state == DiagnosticState.failed ? tr('Обнаружены ошибки — выполните рекомендации выше', 'Errors were detected — follow the advice above') : tr('Есть ограничения проверки или предупреждения — подробности выше', 'Some checks are limited or raised warnings — see details above'));
      }),
    ];
  }
}

class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({super.key, required this.runner, this.russian = false});
  final DiagnosticsRunner runner;
  final bool russian;
  @override State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}
class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  int _run = 0;
  bool _running = false;
  late List<DiagnosticStep> _steps;
  final Map<int, DiagnosticResult> _results = {};
  @override void initState() { super.initState(); _steps = widget.runner.build(russian: widget.russian); unawaited(_start()); }
  Future<void> _start() async {
    final id = ++_run;
    final scope = '${widget.runner.api.baseUrl}|${widget.runner.api.authRevision.value}';
    _steps = widget.runner.build(russian: widget.russian);
    setState(() { _results.clear(); _running = true; });
    for (var i = 0; i < _steps.length; i++) {
      if (!mounted || id != _run) return;
      if (scope != '${widget.runner.api.baseUrl}|${widget.runner.api.authRevision.value}') { setState(() { _results.clear(); _running = false; }); return; }
      setState(() => _results[i] = DiagnosticResult(DiagnosticState.running, widget.russian ? 'Проверка…' : 'Checking…'));
      DiagnosticResult result;
      try { result = await _steps[i].probe().timeout(const Duration(seconds: 10)); }
      catch (_) { result = DiagnosticResult(DiagnosticState.failed, widget.russian ? 'Проверка не завершена' : 'The check did not complete'); }
      if (!mounted || id != _run) return;
      if (scope != '${widget.runner.api.baseUrl}|${widget.runner.api.authRevision.value}') { setState(() { _results.clear(); _running = false; }); return; }
      setState(() => _results[i] = result);
    }
    if (mounted && id == _run) setState(() => _running = false);
  }
  @override void dispose() { _run++; super.dispose(); }
  String _label(DiagnosticState state) => switch (state) {
    DiagnosticState.ok => widget.russian ? '✓ Работает' : '✓ Working',
    DiagnosticState.warning => widget.russian ? '⚠ Внимание' : '⚠ Attention',
    DiagnosticState.failed => widget.russian ? '✕ Ошибка' : '✕ Failed',
    DiagnosticState.running => widget.russian ? '⟳ Проверка…' : '⟳ Checking…',
  };
  Color _color(DiagnosticState state) => switch (state) {
    DiagnosticState.ok => GlukColors.connected, DiagnosticState.warning => GlukColors.amber,
    DiagnosticState.failed => GlukColors.danger, DiagnosticState.running => GlukColors.violetLight,
  };
  @override Widget build(BuildContext context) => Scaffold(
    backgroundColor: GlukColors.bg,
    appBar: AppBar(title: Text(widget.russian ? 'Диагностика' : 'Diagnostics')),
    body: ListView(padding: const EdgeInsets.all(16), children: <Widget>[
      Text(widget.russian ? 'Проверки не меняют настройки VPN и не показывают токены. Неподтверждённые результаты отмечаются предупреждением.' : 'Checks do not change VPN settings or expose tokens. Unverified results are marked as warnings.', style: const TextStyle(color: GlukColors.text2)),
      const SizedBox(height: 16),
      for (var i = 0; i < _steps.length; i++) Card(
        color: GlukColors.cell,
        child: Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Text('${i + 1}. ${_steps[i].name}', style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 5),
          if (_results[i] case final DiagnosticResult result) ...<Widget>[
            Text(_label(result.state), style: TextStyle(color: _color(result.state), fontWeight: FontWeight.w600)),
            const SizedBox(height: 4), Text(result.detail),
            if (result.tip != null) Padding(padding: const EdgeInsets.only(top: 7), child: Text(result.tip!, style: const TextStyle(color: GlukColors.text2))),
          ] else Text(widget.russian ? 'Ожидание' : 'Waiting', style: const TextStyle(color: GlukColors.text2)),
        ])),
      ),
      const SizedBox(height: 12),
      FilledButton.icon(onPressed: _running ? null : _start, icon: const Icon(Icons.refresh_rounded), label: Text(widget.russian ? 'Повторить проверку' : 'Run checks again')),
      if (_running) TextButton(onPressed: () { _run++; setState(() => _running = false); }, child: Text(widget.russian ? 'Остановить проверку' : 'Stop checks')),
    ]),
  );
}
