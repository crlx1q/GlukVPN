import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/account_insights.dart';
import '../services/api_client.dart';

/// One request at a time; identity changes invalidate both data and old replies.
class AccountInsightsController extends ChangeNotifier {
  AccountInsightsController(this.api) { api.authRevision.addListener(accountChanged); }
  final ApiClient api;
  ActiveMapSnapshot? snapshot;
  Object? error;
  bool loading = false;
  bool _visible = false, _disposed = false, _inFlight = false, _pending = false;
  int _generation = 0;
  Timer? _timer;
  ServiceStatus get service => snapshot?.service ?? ServiceStatus.available;

  void setVisible(bool value) {
    if (_disposed || _visible == value) return;
    _visible = value;
    _generation++;
    _timer?.cancel(); _timer = null;
    if (value) { unawaited(refresh()); } else { _pending = false; loading = false; }
  }
  Future<void> refresh() async {
    if (_disposed || !_visible) return;
    if (_inFlight) { _pending = true; return; }
    if (!api.isAuthenticated) { snapshot = null; error = null; loading = false; notifyListeners(); return; }
    _timer?.cancel();
    _inFlight = true; _pending = false;
    final generation = _generation;
    loading = snapshot == null; notifyListeners();
    try {
      final next = await api.activeMap().timeout(const Duration(seconds: 15));
      if (_disposed || !_visible || generation != _generation || !api.isAuthenticated) return;
      snapshot = next; error = null;
    } catch (e) {
      if (!_disposed && generation == _generation) { snapshot = null; error = e; }
    } finally {
      _inFlight = false;
      if (!_disposed) {
        if (generation == _generation) { loading = false; notifyListeners(); }
        if (_visible && api.isAuthenticated) {
          if (_pending || generation != _generation) { _pending = false; scheduleMicrotask(refresh); }
          else { _timer = Timer(Duration(milliseconds: (snapshot?.pollAfterMs ?? 5000).clamp(3000, 60000).toInt()), refresh); }
        }
      }
    }
  }
  void accountChanged() {
    if (_disposed) return;
    _generation++; snapshot = null; error = null; loading = false;
    _timer?.cancel(); _timer = null;
    notifyListeners();
    if (_visible) unawaited(refresh());
  }
  @override void dispose() {
    _disposed = true; _generation++; _timer?.cancel();
    api.authRevision.removeListener(accountChanged);
    super.dispose();
  }
}
