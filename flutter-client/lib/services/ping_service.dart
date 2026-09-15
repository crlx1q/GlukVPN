import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_ping/dart_ping.dart';
import 'package:http/http.dart' as http;

import '../config.dart';

/// Where a latency sample came from.
///
/// The UI shows this, so the number is never presented as something it is not:
/// an ICMP round-trip through the tunnel and an HTTPS round-trip to the control
/// plane are very different measurements.
enum PingSource {
  /// ICMP echo to the node itself - its in-tunnel gateway on the WireGuard
  /// engine, its own latency host on the desktop: real network latency.
  tunnelGateway,

  /// HTTPS round-trip to the control API: used when ICMP is filtered.
  controlApi,

  /// Время TCP-хендшейка до открытого порта узла: SYN → SYN-ACK — это
  /// ровно один round-trip. Используется, когда ICMP режется — на
  /// Windows и в мобильных сетях это правило, а не исключение.
  tcpHandshake,

  /// Nothing answered.
  none,
}

class PingSample {
  const PingSample({required this.source, this.milliseconds});

  const PingSample.empty() : source = PingSource.none, milliseconds = null;

  final PingSource source;
  final int? milliseconds;

  bool get ok => milliseconds != null;

  /// Short label for the UI, so the reading is always honest about its origin.
  String get sourceLabel {
    switch (source) {
      case PingSource.tunnelGateway:
        return 'tunnel';
      case PingSource.controlApi:
        return 'api';
      case PingSource.tcpHandshake:
        return 'tcp';
      case PingSource.none:
        return '--';
    }
  }

  @override
  String toString() => 'PingSample(${milliseconds ?? '-'} ms via $sourceLabel)';
}

/// Live latency measurement for the Home screen.
class PingService {
  PingService({http.Client? httpClient}) : _http = httpClient ?? http.Client();

  final http.Client _http;

  /// Takes one sample, preferring the real round-trip to the node.
  ///
  /// [host] has to be the far end of the tunnel: the node's WireGuard address
  /// (e.g. 10.8.0.1) on the phone, the node's own latency host on the desktop.
  /// It must never be the address of our own TUN adapter - the desktop passed
  /// 172.19.0.1 here, and every connection, healthy or dead, reported 1 ms
  /// because the echo never left the machine.
  ///
  /// The node still has to answer ICMP, and a VLESS tunnel carries TCP and UDP
  /// but not ICMP; whenever the echo goes unanswered the HTTPS fallback is used
  /// and labelled as such instead of inventing a tunnel number.
  ///
  /// [apiBaseUrl] overrides the host used by that fallback. The app can be
  /// pointed at either control plane at runtime, so the fallback has to follow
  /// the active channel instead of the compile-time default.
  Future<PingSample> measure({String? host, String? apiBaseUrl}) async {
    if (host != null && host.isNotEmpty) {
      final int? icmp = await _icmpRtt(host);
      if (icmp != null) {
        return PingSample(source: PingSource.tunnelGateway, milliseconds: icmp);
      }
    }
    final int? https = await _httpRtt(apiBaseUrl ?? AppConfig.apiBaseUrl);
    if (https != null) {
      return PingSample(source: PingSource.controlApi, milliseconds: https);
    }
    return const PingSample.empty();
  }

  /// ICMP round-trip to one host, with **no** HTTPS fallback.
  ///
  /// The server list needs each node's own latency. Falling back to the control
  /// API here would quietly report the same number on every row, which is worse
  /// than an empty reading. The source label is not surfaced in the list, only
  /// the millisecond value and the signal level derived from it.
  Future<PingSample> probeHost(
    String host, {
    List<int> tcpPorts = const <int>[443, 80],
  }) async {
    if (host.isEmpty) return const PingSample.empty();
    final int? icmp = await _icmpRtt(host);
    if (icmp != null) {
      return PingSample(source: PingSource.tunnelGateway, milliseconds: icmp);
    }
    // ICMP молчит — это ещё не ответ про сервер. На Windows и в
    // мобильных сетях эхо режут целиком: список серверов оставался
    // вообще без цифр, а деления стояли на «среднем по умолчанию».
    final int? tcp = await _tcpRtt(host, tcpPorts);
    if (tcp == null) return const PingSample.empty();
    return PingSample(source: PingSource.tcpHandshake, milliseconds: tcp);
  }

  /// Время TCP-хендшейка до первого открытого порта из [ports].
  ///
  /// Два правила, без которых цифра врёт:
  ///
  /// 1. DNS решается до замера и в него не входит. Иначе первый узел
  ///    в списке всегда выглядел бы самым медленным.
  /// 2. Берём минимум из двух попыток: первый connect на свежем
  ///    сокете стоит дороже самой сети.
  ///
  /// Больше трёх портов не пробуем и таймаут держим коротким: замер
  /// идёт по всему флоту подряд, и десяток глухих узлов не должен
  /// растянуть его на минуты.
  Future<int?> _tcpRtt(String host, List<int> ports) async {
    final List<int> candidates = <int>[];
    for (final int port in ports) {
      if (port <= 0 || port >= 65536 || candidates.contains(port)) continue;
      candidates.add(port);
      if (candidates.length == 3) break;
    }
    if (candidates.isEmpty) return null;

    Object target = host;
    try {
      final List<InternetAddress> resolved = await InternetAddress.lookup(host)
          .timeout(const Duration(seconds: 3));
      if (resolved.isNotEmpty) target = resolved.first;
    } catch (_) {
      // Не разрешилось — пусть имя решает сам connect.
    }

    for (final int port in candidates) {
      int? best;
      for (int attempt = 0; attempt < 2; attempt++) {
        final Stopwatch watch = Stopwatch()..start();
        try {
          final Socket socket = await Socket.connect(
            target,
            port,
            timeout: const Duration(milliseconds: 1200),
          );
          watch.stop();
          socket.destroy();
          final int ms = watch.elapsedMilliseconds;
          if (best == null || ms < best) best = ms;
        } catch (_) {
          watch.stop();
          // Порт закрыт или отфильтрован — следующий кандидат.
          break;
        }
      }
      // Ноль миллисекунд бывает только у локальной петли; в UI нулёвой
      // пинг читается как «замера нет», поэтому поднимаем до 1 мс.
      if (best != null) return best == 0 ? 1 : best;
    }
    return null;
  }

  /// ICMP замер одного хоста.
  ///
  /// Здесь жили две самые шумные ошибки Windows в журнале
  /// (`FormatException: Unexpected extension byte` и `Missing extension
  /// byte`, 69 отчётов). Причина не в сети и не в API: русская
  /// консоль Windows печатает вывод `ping` в OEM-кодировке (866),
  /// а dart_ping по умолчанию разбирает его строгим UTF-8 — первый
  /// же байт «Обмен» ломает декодер.
  ///
  /// Исправляем точно это место: консоли задаём codepage 437
  /// (`chcp 437 && ping ...` внутри пакета) и декодируем её вывод с
  /// `allowMalformed`, чтобы один битый байт не ронял замер. Разбор
  /// JWT и ответов API остаётся строгим — там молчаливая терпимость
  /// к мусору была бы опасна.
  ///
  /// Второе: подписка теперь живёт до конца потока. Прежний
  /// `return` из `await for` по первому ответу отменял подписку, и всё,
  /// что процесс писал после этого (в том числе ошибки декодера),
  /// оставалось без обработчика и уходило в глобальный хук — то есть в
  /// телеметрию.
  Future<int?> _icmpRtt(String host) async {
    int? rtt;
    final Completer<void> finished = Completer<void>();
    StreamSubscription<PingData>? sub;
    try {
      final Ping ping = Ping(
        host,
        count: 1,
        timeout: 2,
        encoding: const Utf8Codec(allowMalformed: true),
        forceCodepage: Platform.isWindows,
      );
      sub = ping.stream.listen(
        (PingData event) {
          final Duration? time = event.response?.time;
          if (time != null) rtt ??= time.inMilliseconds;
        },
        onError: (Object _, StackTrace __) {
          if (!finished.isCompleted) finished.complete();
        },
        onDone: () {
          if (!finished.isCompleted) finished.complete();
        },
        cancelOnError: false,
      );
      // count: 1 — процесс закрывается сразу после ответа, но ждать
      // его бесконечно нельзя: без ответа возвращаемся к HTTPS.
      await finished.future.timeout(const Duration(seconds: 4), onTimeout: () {});
    } catch (_) {
      // ICMP unavailable on this device or network: fall through to HTTPS.
    } finally {
      await sub?.cancel();
    }
    return rtt;
  }

  Future<int?> _httpRtt(String baseUrl) async {
    final Stopwatch watch = Stopwatch()..start();
    try {
      final http.Response response = await _http
          .get(Uri.parse('$baseUrl/api/health'))
          .timeout(const Duration(seconds: 5));
      watch.stop();
      // Any answer at all, even an error status, is a valid RTT measurement.
      if (response.statusCode > 0) return watch.elapsedMilliseconds;
    } catch (_) {
      // Unreachable.
    }
    return null;
  }

  void close() => _http.close();
}
