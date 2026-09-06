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
  /// ICMP echo to the node's address inside the tunnel: real tunnel latency.
  tunnelGateway,

  /// HTTPS round-trip to the control API: used when ICMP is filtered.
  controlApi,

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

  /// Takes one sample, preferring the real tunnel round-trip.
  ///
  /// [gatewayIp] is the node's WireGuard address (e.g. 10.8.0.1). Note that the
  /// node's firewall must accept ICMP on the wg interface for this to answer;
  /// otherwise the HTTPS fallback is used and labelled as such.
  ///
  /// [apiBaseUrl] overrides the host used by that fallback. The app can be
  /// pointed at either control plane at runtime, so the fallback has to follow
  /// the active channel instead of the compile-time default.
  Future<PingSample> measure({String? gatewayIp, String? apiBaseUrl}) async {
    if (gatewayIp != null && gatewayIp.isNotEmpty) {
      final int? icmp = await _icmpRtt(gatewayIp);
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
  Future<PingSample> probeHost(String host) async {
    if (host.isEmpty) return const PingSample.empty();
    final int? icmp = await _icmpRtt(host);
    if (icmp == null) return const PingSample.empty();
    return PingSample(source: PingSource.tunnelGateway, milliseconds: icmp);
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
