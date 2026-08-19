import 'dart:async';

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
  Future<PingSample> measure({String? gatewayIp}) async {
    if (gatewayIp != null && gatewayIp.isNotEmpty) {
      final int? icmp = await _icmpRtt(gatewayIp);
      if (icmp != null) {
        return PingSample(source: PingSource.tunnelGateway, milliseconds: icmp);
      }
    }
    final int? https = await _httpRtt();
    if (https != null) {
      return PingSample(source: PingSource.controlApi, milliseconds: https);
    }
    return const PingSample.empty();
  }

  Future<int?> _icmpRtt(String host) async {
    try {
      final Ping ping = Ping(host, count: 1, timeout: 2);
      await for (final PingData event in ping.stream) {
        final PingResponse? response = event.response;
        final Duration? time = response?.time;
        if (time != null) return time.inMilliseconds;
        if (event.error != null) return null;
      }
    } catch (_) {
      // ICMP unavailable on this device or network: fall through to HTTPS.
    }
    return null;
  }

  Future<int?> _httpRtt() async {
    final Stopwatch watch = Stopwatch()..start();
    try {
      final http.Response response = await _http
          .get(Uri.parse('${AppConfig.apiBaseUrl}/api/health'))
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
