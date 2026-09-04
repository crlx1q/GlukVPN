import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The ongoing Android notification that carries the Disconnect button.
///
/// Why it exists: the tunnel is raised by `wireguard_flutter`, whose own
/// foreground-service notification is built inside the package and cannot be
/// given an action. So GlukVPN posts its own ongoing notification, and that one
/// has the button. Everything the button does is real work done by
/// `VpnController`: the tunnel is stopped through the plugin and the session is
/// closed with POST /api/vpn/disconnect.
///
/// Every call is a no-op off Android, and every platform failure is swallowed
/// with a log line. A notification that cannot be drawn must never break a
/// connect, and unit tests must not need a platform to run against.
class TunnelNotifications {
  TunnelNotifications({
    MethodChannel? methods,
    EventChannel? events,
    bool? isAndroid,
  })  : _methods = methods ?? const MethodChannel(methodChannelName),
        _events = events ?? const EventChannel(eventChannelName),
        _android = isAndroid ??
            (!kIsWeb && defaultTargetPlatform == TargetPlatform.android);

  static const String methodChannelName = 'tech.gluk.glukvpn/tunnel';
  static const String eventChannelName = 'tech.gluk.glukvpn/tunnel_events';

  /// The single event the platform sends: the user pressed the button while
  /// this isolate was alive.
  static const String disconnectRequestedEvent = 'disconnect_requested';

  final MethodChannel _methods;
  final EventChannel _events;
  final bool _android;

  Stream<void>? _requests;

  /// True when this platform can draw the notification at all.
  bool get supported => _android;

  /// Fires every time Disconnect is pressed in the shade while the app runs.
  Stream<void> get disconnectRequests {
    if (!_android) return const Stream<void>.empty();
    return _requests ??= _events
        .receiveBroadcastStream()
        .where((Object? event) => event == disconnectRequestedEvent)
        .map<void>((Object? _) {})
        .handleError((Object error) {
      debugPrint('tunnel notification: event stream failed: $error');
    });
  }

  /// Draws or refreshes the notification for a live tunnel.
  ///
  /// [stoppingLabel] is stored on the platform side: the button has to answer
  /// instantly, and the receiver that repaints the notification runs without a
  /// Dart isolate, so it cannot ask for the copy at that point.
  Future<void> show({
    required String title,
    required String body,
    required String actionLabel,
    required String stoppingLabel,
    required String channelName,
  }) =>
      _invoke('show', <String, Object?>{
        'title': title,
        'body': body,
        'actionLabel': actionLabel,
        'stoppingLabel': stoppingLabel,
        'channelName': channelName,
      });

  /// Removes the notification.
  Future<void> hide() => _invoke('hide');

  /// Whether Disconnect was pressed while no isolate was listening.
  ///
  /// The platform records such a request instead of dropping it, and reading it
  /// back here is what keeps a cold start from showing a connected screen over
  /// a tunnel the user already stopped. Reading it also clears it.
  Future<bool> consumeStopRequest() async {
    if (!_android) return false;
    try {
      return await _methods.invokeMethod<bool>('consumeStopRequest') ?? false;
    } catch (error) {
      debugPrint('tunnel notification: consumeStopRequest failed: $error');
      return false;
    }
  }

  Future<void> _invoke(String method, [Map<String, Object?>? arguments]) async {
    if (!_android) return;
    try {
      await _methods.invokeMethod<void>(method, arguments);
    } catch (error) {
      // MissingPluginException on a host without the bridge, PlatformException
      // when the platform refuses. Neither is worth failing a connect over.
      debugPrint('tunnel notification: $method failed: $error');
    }
  }
}
