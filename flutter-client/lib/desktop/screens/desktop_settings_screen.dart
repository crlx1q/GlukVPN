import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../config.dart';
import '../../models/models.dart';
import '../../platform/tunnel_backend.dart';
import '../../state/auth_controller.dart';
import '../../theme/tokens.dart';
import '../../utils/format.dart';
import '../../widgets/common.dart';
import '../../widgets/glass.dart';
import '../i18n/desktop_strings.dart';
import '../logic/connection_phase.dart';
import '../services/app_inventory.dart';
import '../services/autostart_service.dart';
import '../state/desktop_settings.dart';
import '../state/desktop_vpn_controller.dart';
import '../theme/desktop_theme.dart';

/// Settings (requirement 13).
///
/// Sections, in the order the user meets them:
///
///  1. **Quick start** - a highlighted card, because "start hidden in the tray
///     and connect on its own" is how this client is meant to be used, not an
///     option buried three screens down.
///  2. General - language and a *single* animation switch. The old pair
///     (Animations + Reduce motion) did nearly the same thing and only made the
///     screen harder to read; motion now also stands down by itself on battery.
///  3. VPN - kill switch, DNS, lifecycle.
///  4. Split tunneling.
///  5. Advanced - ported from the browser extension: always-direct routes, MTU,
///     protocol and channel.
///  6. Diagnostics - available in every build now, not just internal ones.
///  7. Account - profile, subscription and the real device list.
class DesktopSettingsScreen extends StatefulWidget {
  const DesktopSettingsScreen({
    super.key,
    required this.settings,
    required this.vpn,
    required this.auth,
    required this.strings,
    required this.onLanguageChanged,
  });

  final SettingsStore settings;
  final DesktopVpnController vpn;
  final AuthController auth;
  final DesktopStrings strings;
  final ValueChanged<String> onLanguageChanged;

  @override
  State<DesktopSettingsScreen> createState() => _DesktopSettingsScreenState();
}

class _DesktopSettingsScreenState extends State<DesktopSettingsScreen> {
  static const AutostartService _autostart = AutostartService();

  String? _notice;

  // Devices, loaded from GET /api/devices.
  List<DeviceInfo>? _devices;
  int _maxDevices = 0;
  bool _devicesLoading = false;
  String? _devicesError;

  bool _testingGateway = false;
  bool _restoringNetwork = false;

  DesktopSettings get _value => widget.settings.value;

  bool get _ru => widget.strings.isRussian;

  @override
  void initState() {
    super.initState();
    unawaited(_loadDevices());
  }

  Future<void> _patch(
    DesktopSettings Function(DesktopSettings s) mutate,
  ) async {
    await widget.settings.update(mutate);
    if (mounted) setState(() {});
  }

  Future<void> _loadDevices() async {
    if (_devicesLoading) return;
    setState(() {
      _devicesLoading = true;
      _devicesError = null;
    });
    try {
      final DevicesResult result = await widget.vpn.api.devices();
      if (!mounted) return;
      setState(() {
        _devices = result.devices;
        _maxDevices = result.maxDevices;
        _devicesLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _devicesLoading = false;
        _devicesError = _ru
            ? 'Не удалось загрузить устройства'
            : 'Could not load devices';
      });
    }
  }

  Future<void> _revokeDevice(DeviceInfo device) async {
    try {
      await widget.vpn.api.revokeDevice(device.id);
      setState(() {
        _notice = _ru
            ? 'Устройство отключено. Статистика сохранена.'
            : 'Device removed. Its history is kept.';
      });
      await _loadDevices();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _notice = _ru ? 'Не удалось отключить устройство' : 'Could not remove it';
      });
    }
  }

  Future<void> _copyDiagnostics() async {
    await Clipboard.setData(ClipboardData(text: widget.vpn.diagnosticsDump()));
    if (!mounted) return;
    setState(() {
      _notice = _ru
          ? 'Журнал скопирован в буфер обмена'
          : 'Diagnostics copied to the clipboard';
    });
  }

  /// ROUND 5: the way out of "the whole PC has no internet".
  ///
  /// The kill switch was armed when the tunnel went up and only released when
  /// it was shut down cleanly. A tunnel that died on its own left the WFP
  /// block-all filters in place, and the only cure was `net stop
  /// GlukVpnTunnel` from an admin prompt. Requirement 2 says the user never
  /// touches a terminal, so it is a button now.
  Future<void> _restoreInternet() async {
    setState(() => _restoringNetwork = true);
    final bool ok = await widget.vpn.releaseNetworkLocks(reason: 'settings');
    if (!mounted) return;
    setState(() {
      _restoringNetwork = false;
      _notice = ok
          ? (_ru
              ? 'Сетевые фильтры сняты, интернет должен работать'
              : 'Network filters released, internet should be back')
          : (_ru
              ? 'Не удалось снять фильтры. Перезагрузите ПК.'
              : 'Could not release the filters. Reboot the PC.');
    });
  }

  Future<void> _testGateway() async {
    setState(() => _testingGateway = true);
    await widget.vpn.measureNodePings();
    if (!mounted) return;
    final int? ping = widget.vpn.currentPingMs;
    setState(() {
      _testingGateway = false;
      _notice = ping == null
          ? (_ru ? 'Сервер не ответил на проверку' : 'The server did not answer')
          : (_ru
              ? 'Сервер отвечает за ${formatPing(ping)}'
              : 'Server responds in ${formatPing(ping)}');
    });
  }

  @override
  Widget build(BuildContext context) {
    final DesktopStrings s = widget.strings;
    final bool ru = _ru;

    return ListView(
      padding: const EdgeInsets.all(GlukSizes.pagePadding),
      children: <Widget>[
        Text(
          s.settings,
          style: const TextStyle(
            color: GlukColors.text0,
            fontSize: 20,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 18),

        if (_notice != null) ...<Widget>[
          InlineNotice(message: _notice!, tone: NoticeTone.info),
          const SizedBox(height: 14),
        ],

        // ---- 1. Quick start (primary) ------------------------------------
        _HeroSection(
          title: ru ? 'Быстрый старт' : 'Quick start',
          subtitle: ru
              ? 'GlukVPN стартует вместе с Windows, прячется в трей и сам '
                  'поднимает туннель. Открыл окно — уже подключено.'
              : 'GlukVPN starts with Windows, stays in the tray and brings the '
                  'tunnel up on its own. By the time you open the window it is '
                  'already connected.',
          children: <Widget>[
            _SwitchTile(
              label: s.startWithWindows,
              value: _value.startWithWindows,
              onChanged: (bool v) async {
                await _patch(
                    (DesktopSettings x) => x.copyWith(startWithWindows: v));
                _autostart.apply(
                  startWithWindows: v,
                  startMinimized: _value.startMinimized,
                );
              },
            ),
            _SwitchTile(
              label: s.startMinimized,
              subtitle: ru
                  ? 'Окно не появляется — только значок в трее'
                  : 'No window on launch, just the tray icon',
              value: _value.startMinimized,
              onChanged: (bool v) async {
                await _patch(
                    (DesktopSettings x) => x.copyWith(startMinimized: v));
                _autostart.apply(
                  startWithWindows: _value.startWithWindows,
                  startMinimized: v,
                );
              },
            ),
            _SwitchTile(
              label: s.autoConnect,
              subtitle: ru
                  ? 'Подключаться к лучшему серверу сразу после запуска'
                  : 'Connect to the best server right after launch',
              value: _value.autoConnect,
              onChanged: (bool v) =>
                  _patch((DesktopSettings x) => x.copyWith(autoConnect: v)),
            ),
          ],
        ),

        // ---- 2. General ---------------------------------------------------
        _Section(
          title: s.sectionGeneral,
          children: <Widget>[
            _ChoiceTile<String>(
              label: s.language,
              value: _value.language,
              options: <String, String>{
                'system': s.languageSystem,
                'ru': 'Русский',
                'en': 'English',
              },
              onChanged: (String v) async {
                await _patch((DesktopSettings x) => x.copyWith(language: v));
                widget.onLanguageChanged(v);
              },
            ),
            _SwitchTile(
              label: s.animations,
              subtitle: ru
                  ? 'Глобус, пульсация кнопки и переходы между экранами'
                  : 'Globe, button pulse and screen transitions',
              value: _value.animationsEnabled,
              onChanged: (bool v) => _patch(
                (DesktopSettings x) => x.copyWith(animationsEnabled: v),
              ),
            ),
            _SwitchTile(
              label: ru
                  ? 'Экономить заряд: выключать анимации от батареи'
                  : 'Save power: no animations on battery',
              subtitle: ru
                  ? 'Само сработает, если ноутбук отключили от сети или '
                      'включён режим энергосбережения. На VPN не влияет.'
                  : 'Kicks in when the laptop is unplugged or Windows battery '
                      'saver is on. Never affects the VPN.',
              value: _value.pauseAnimationsOnBattery,
              onChanged: (bool v) => _patch(
                (DesktopSettings x) =>
                    x.copyWith(pauseAnimationsOnBattery: v),
              ),
            ),
          ],
        ),

        // ---- 3. VPN -------------------------------------------------------
        _Section(
          title: s.sectionVpn,
          children: <Widget>[
            _SwitchTile(
              label: s.killSwitch,
              subtitle: s.killSwitchHint,
              value: _value.killSwitch,
              onChanged: (bool v) async {
                await _patch((DesktopSettings x) => x.copyWith(killSwitch: v));
                if (widget.vpn.phase.isConnected) {
                  setState(() => _notice = s.splitReconnectNeeded);
                }
              },
            ),
            _TextTile(
              label: s.dns,
              subtitle: s.dnsHint,
              value: _value.dns.join(', '),
              hint: '1.1.1.1, 1.0.0.1',
              onSubmitted: (String raw) {
                _patch((DesktopSettings x) => x.copyWith(dns: _list(raw)));
              },
            ),
            _SwitchTile(
              label: s.keepTunnelWithoutUi,
              subtitle: s.keepTunnelHint,
              value: _value.keepTunnelWithoutUi,
              onChanged: (bool v) => _patch(
                (DesktopSettings x) => x.copyWith(keepTunnelWithoutUi: v),
              ),
            ),
            _SwitchTile(
              label: s.disconnectOnExit,
              value: _value.disconnectOnExit,
              onChanged: (bool v) => _patch(
                (DesktopSettings x) => x.copyWith(disconnectOnExit: v),
              ),
            ),
          ],
        ),

        // ---- 4. Split tunnelling -----------------------------------------
        _SplitSection(
          strings: s,
          settings: widget.settings,
          vpn: widget.vpn,
          onChanged: () => setState(() {}),
          onNotice: (String? message) => setState(() => _notice = message),
        ),

        // ---- 5. Advanced (from the browser extension) --------------------
        _Section(
          title: ru ? 'Расширенные настройки' : 'Advanced',
          children: <Widget>[
            _TextTile(
              label: ru ? 'Всегда напрямую' : 'Always direct',
              subtitle: ru
                  ? 'Домены и подсети, которые никогда не идут через VPN. '
                      'Через запятую.'
                  : 'Hosts and subnets that never travel through the tunnel. '
                      'Comma separated.',
              value: _value.bypassRoutes.join(', '),
              hint: 'gluk.tech, 192.168.0.0/16',
              onSubmitted: (String raw) {
                _patch(
                  (DesktopSettings x) => x.copyWith(bypassRoutes: _list(raw)),
                );
                if (widget.vpn.phase.isConnected) {
                  setState(() => _notice = s.splitReconnectNeeded);
                }
              },
            ),
            _TextTile(
              label: s.mtu,
              subtitle: ru
                  ? 'Пусто — как отдаёт сервер. Допустимо 1280–1500.'
                  : 'Empty means whatever the server hands us. 1280-1500.',
              value: _value.mtu?.toString() ?? '',
              hint: '1420',
              onSubmitted: (String raw) {
                final int? parsed = int.tryParse(raw.trim());
                _patch(
                  (DesktopSettings x) => parsed == null
                      ? x.copyWith(clearMtu: true)
                      : x.copyWith(mtu: parsed),
                );
              },
            ),
            _InfoTile(
              label: ru ? 'Протокол' : 'Protocol',
              value: 'WireGuard · NT',
            ),
            _InfoTile(
              label: ru ? 'Сетевой адаптер' : 'Network adapter',
              value: AppConfig.desktopAdapterName,
            ),
            // ROUND 5: admins only.
            //
            // The beta control plane refuses non-admin accounts and has no
            // registration, so naming the channel to an ordinary user only ever
            // raised questions it could not answer. Non-admins see PROD and
            // nothing about channels at all.
            if (widget.auth.user?.isAdmin ?? false)
              _InfoTile(
                label: ru ? 'Канал' : 'Channel',
                value: AppConfig.activeChannel.label,
              ),

            // The extension's "for developers" disclosure, read-only.
            //
            // The extension lets you retype the API host because a browser
            // extension has no installer to fix a wrong value. Here the same
            // information is shown but never editable: an editable endpoint on
            // a desktop VPN client is a phishing vector, and the brief is
            // explicit that no user-facing API URL field may exist.
            _InfoTile(
              label: ru ? 'Сервер управления' : 'Control API',
              value: AppConfig.activeBaseUrl,
            ),
            _InfoTile(
              label: ru ? 'Личный кабинет' : 'Web dashboard',
              value: 'vpn.gluk.tech',
            ),
            _InfoTile(
              label: ru ? 'Служба' : 'Service',
              value: AppConfig.tunnelServiceName,
            ),
            _ActionTile(
              label: ru ? 'Проверить сервер' : 'Test the server',
              subtitle: ru
                  ? 'Измеряет задержку до выбранного узла'
                  : 'Measures latency to the selected node',
              buttonLabel: ru ? 'Проверить' : 'Test',
              busy: _testingGateway,
              onPressed: _testGateway,
            ),

            // `#btn-reset` in the extension. Only the advanced block is reset:
            // wiping the account or the language would be a surprise, not a
            // reset.
            _ActionTile(
              label: ru ? 'Сбросить расширенные' : 'Reset advanced',
              subtitle: ru
                  ? 'Вернёт «Всегда напрямую», MTU и список приложений к значениям по умолчанию'
                  : 'Restores always-direct routes, MTU and the app list to defaults',
              buttonLabel: ru ? 'Сбросить' : 'Reset',
              onPressed: () async {
                _patch(
                  (DesktopSettings x) => x.copyWith(
                    bypassRoutes: const <String>[],
                    splitApps: const <String>[],
                    clearMtu: true,
                  ),
                );
                if (!mounted) return;
                setState(() {
                  _notice = ru
                      ? 'Расширенные настройки сброшены'
                      : 'Advanced settings restored';
                });
              },
            ),
          ],
        ),

        // ---- 6. Diagnostics (every build) --------------------------------
        _Section(
          title: ru ? 'Диагностика' : 'Diagnostics',
          children: <Widget>[
            _InfoTile(
              label: ru ? 'Служба туннеля' : 'Tunnel service',
              value: widget.vpn.serviceReady
                  ? (ru ? 'работает' : 'running')
                  : (widget.vpn.serviceProblem ?? s.dash),
            ),
            _InfoTile(
              label: ru ? 'Серверов доступно' : 'Servers available',
              value: '${widget.vpn.userVisibleNodes.length}',
            ),
            _ActionTile(
              label: ru ? 'Журнал работы' : 'Activity log',
              subtitle: ru
                  ? 'Полный отчёт для поддержки: состояние, узлы, последние '
                      'события. Ключи и пароли в него не попадают.'
                  : 'Full support report: state, nodes, recent events. Never '
                      'contains keys or passwords.',
              buttonLabel: ru ? 'Копировать' : 'Copy',
              onPressed: _copyDiagnostics,
            ),
            _ActionTile(
              label: ru ? 'Восстановить интернет' : 'Restore internet access',
              subtitle: ru
                  ? 'Снимает kill switch и маршруты, если туннель упал и сеть '
                      'осталась заблокированной'
                  : 'Releases the kill switch and routes if a dead tunnel left '
                      'the network blocked',
              buttonLabel: ru ? 'Снять блокировку' : 'Release',
              busy: _restoringNetwork,
              onPressed: _restoreInternet,
            ),
            if (!widget.vpn.serviceReady)
              _ActionTile(
                label: ru ? 'Восстановить службу' : 'Repair the service',
                subtitle: ru
                    ? 'Переустановит и запустит службу туннеля'
                    : 'Reinstalls and starts the tunnel service',
                buttonLabel: ru ? 'Восстановить' : 'Repair',
                busy: widget.vpn.serviceRepairing,
                onPressed: () => widget.vpn.repairService(),
              ),
          ],
        ),

        // ---- 7. Account ---------------------------------------------------
        _Section(
          title: s.sectionAccount,
          children: <Widget>[
            _ProfileCard(auth: widget.auth, strings: s),
            const SizedBox(height: 6),
            _InfoTile(
              label: s.plan,
              value: widget.auth.subscription?.status ?? s.free,
            ),
            if (widget.auth.subscription?.expiresAt != null)
              _InfoTile(
                label: s.expires,
                value: formatDateTime(widget.auth.subscription!.expiresAt!),
              ),
            if (widget.auth.user != null)
              _InfoTile(
                label: ru ? 'Одновременных сессий' : 'Concurrent sessions',
                value: '${widget.auth.user!.maxConcurrentSessions}',
              ),
            const SizedBox(height: 10),
            _DevicesBlock(
              devices: _devices,
              maxDevices: _maxDevices,
              loading: _devicesLoading,
              error: _devicesError,
              ru: ru,
              refreshTooltip: s.refresh,
              onRefresh: _loadDevices,
              onRevoke: _revokeDevice,
            ),
            Padding(
              padding: const EdgeInsets.only(top: 14),
              child: PrimaryPillButton(
                label: s.logout,
                onPressed: () async {
                  await widget.vpn.disconnect(userInitiated: false);
                  await widget.auth.logout();
                },
              ),
            ),
          ],
        ),

        const SizedBox(height: 24),
        Center(
          child: Text(
            'GlukVPN Desktop · ${AppConfig.activeChannel.label}',
            style: const TextStyle(color: GlukColors.text2, fontSize: 11),
          ),
        ),
        const SizedBox(height: 12),
      ],
    );
  }

  static List<String> _list(String raw) => raw
      .split(RegExp(r'[,\s]+'))
      .map((String e) => e.trim())
      .where((String e) => e.isNotEmpty)
      .toList();
}

// ---------------------------------------------------------------------------
// Account
// ---------------------------------------------------------------------------

class _ProfileCard extends StatelessWidget {
  const _ProfileCard({required this.auth, required this.strings});

  final AuthController auth;
  final DesktopStrings strings;

  @override
  Widget build(BuildContext context) {
    final bool ru = strings.isRussian;
    final AuthUser? user = auth.user;
    final String name = user?.username ?? (ru ? 'Аккаунт' : 'Account');
    final String initial =
        name.trim().isEmpty ? '?' : name.trim().substring(0, 1).toUpperCase();

    final bool active = auth.subscription?.isActive ?? false;
    final Color accent = active ? GlukColors.connected : GlukColors.violetLight;

    // Pulled into locals so the null checks below are plain and unambiguous.
    final String publicId = user?.publicIdLabel ?? '';
    final String? email = user?.email;
    final bool emailVerified = user?.emailVerified ?? false;
    final String? origin = user?.originLabel;
    final DateTime? created = user?.createdAt;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.all(14),
      decoration: DesktopTokens.cardDecoration(
        color: DesktopTokens.cardRaised,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            width: 52,
            height: 52,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: <Color>[
                  GlukColors.violet.withOpacity(0.85),
                  GlukColors.violet2.withOpacity(0.85),
                ],
              ),
              border: Border.all(color: accent.withOpacity(0.45), width: 1.5),
            ),
            child: Text(
              initial,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Flexible(
                      child: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: GlukColors.text0,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: accent.withOpacity(0.14),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(color: accent.withOpacity(0.35)),
                      ),
                      child: Text(
                        active
                            ? (ru ? 'Активна' : 'Active')
                            : (ru ? 'Бесплатный' : 'Free'),
                        style: TextStyle(
                          color: accent,
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.4,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                if (publicId.isNotEmpty)
                  _MetaLine(
                    icon: Icons.badge_outlined,
                    text: publicId,
                  ),
                if (email != null)
                  _MetaLine(
                    icon: Icons.alternate_email_rounded,
                    text: email,
                    trailing: emailVerified
                        ? Icons.verified_rounded
                        : Icons.error_outline_rounded,
                    trailingColor: emailVerified
                        ? GlukColors.connected
                        : GlukColors.amber,
                  ),
                if (origin != null)
                  _MetaLine(
                    icon: Icons.place_outlined,
                    text: origin,
                  ),
                if (created != null)
                  _MetaLine(
                    icon: Icons.schedule_rounded,
                    text: (ru ? 'С нами с ' : 'Member since ') +
                        formatDateTime(created),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MetaLine extends StatelessWidget {
  const _MetaLine({
    required this.icon,
    required this.text,
    this.trailing,
    this.trailingColor,
  });

  final IconData icon;
  final String text;
  final IconData? trailing;
  final Color? trailingColor;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        children: <Widget>[
          Icon(icon, size: 13, color: GlukColors.text2),
          const SizedBox(width: 7),
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: GlukColors.text1, fontSize: 12),
            ),
          ),
          if (trailing != null) ...<Widget>[
            const SizedBox(width: 6),
            Icon(trailing, size: 13, color: trailingColor),
          ],
        ],
      ),
    );
  }
}

/// The extension treats a revoked device as a first-class state
/// (`isRevokedDevice`) instead of quietly dropping it, so the user can see that
/// a device was removed rather than wonder where it went. `isActive` is the
/// model's own flag for exactly that.
bool _revoked(DeviceInfo device) => !device.isActive;

/// This device first, then active ones by last-seen, then revoked ones last -
/// the same order the extension's device list uses.
List<DeviceInfo> _orderedDevices(List<DeviceInfo> list) {
  int rank(DeviceInfo device) {
    if (device.isCurrent) return 0;
    if (_revoked(device)) return 2;
    return 1;
  }

  final List<DeviceInfo> sorted = List<DeviceInfo>.of(list);
  sorted.sort((DeviceInfo a, DeviceInfo b) {
    final int byRank = rank(a).compareTo(rank(b));
    if (byRank != 0) return byRank;

    final DateTime? seenA = a.lastSeen;
    final DateTime? seenB = b.lastSeen;
    if (seenA == null && seenB == null) return 0;
    if (seenA == null) return 1;
    if (seenB == null) return -1;
    return seenB.compareTo(seenA);
  });
  return sorted;
}

/// `.dev-badge` - THIS DEVICE / ACTIVE / REVOKED.
class _DeviceBadge extends StatelessWidget {
  const _DeviceBadge({required this.label, required this.colour});

  final String label;
  final Color colour;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: colour.withOpacity(0.13),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: colour.withOpacity(0.32)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: colour,
          fontSize: 9.5,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

/// `.link-btn` - a text action, not an icon. "Revoke" is destructive and has to
/// say so in words.
class _RevokeLink extends StatelessWidget {
  const _RevokeLink({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: onTap,
      style: TextButton.styleFrom(
        minimumSize: const Size(0, 30),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        foregroundColor: GlukColors.danger,
        textStyle: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(999),
        ),
      ),
      child: Text(label),
    );
  }
}

class _DevicesBlock extends StatelessWidget {
  const _DevicesBlock({
    required this.devices,
    required this.maxDevices,
    required this.loading,
    required this.error,
    required this.ru,
    required this.refreshTooltip,
    required this.onRefresh,
    required this.onRevoke,
  });

  final List<DeviceInfo>? devices;
  final int maxDevices;
  final bool loading;
  final String? error;
  final bool ru;
  final String refreshTooltip;
  final Future<void> Function() onRefresh;
  final Future<void> Function(DeviceInfo device) onRevoke;

  @override
  Widget build(BuildContext context) {
    final List<DeviceInfo> list = devices ?? const <DeviceInfo>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Text(
              ru ? 'Устройства' : 'Devices',
              style: const TextStyle(
                color: GlukColors.text1,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 8),
            if (devices != null)
              Text(
                maxDevices > 0
                    ? '${list.length} / $maxDevices'
                    : '${list.length}',
                style: const TextStyle(
                  color: GlukColors.text2,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            const Spacer(),
            if (loading)
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              CircleIconButton(
                icon: Icons.refresh_rounded,
                tooltip: refreshTooltip,
                size: 26,
                onTap: onRefresh,
              ),
          ],
        ),
        const SizedBox(height: 8),
        if (error != null)
          InlineNotice(message: error!, tone: NoticeTone.warning)
        else if (devices == null && loading)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              ru ? 'Загружаю…' : 'Loading…',
              style: const TextStyle(color: GlukColors.text2, fontSize: 12),
            ),
          )
        else if (list.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              ru ? 'Пока только это устройство' : 'Only this device so far',
              style: const TextStyle(color: GlukColors.text2, fontSize: 12),
            ),
          )
        else
          ..._orderedDevices(list).map(
            (DeviceInfo device) => _DeviceRow(
              device: device,
              ru: ru,
              // The API rejects revoking an already revoked device, and
              // revoking the machine you are sitting at would lock you out of
              // your own client. The extension hides the control in both
              // cases, so this does too.
              onRevoke: device.isCurrent || _revoked(device)
                  ? null
                  : () => onRevoke(device),
            ),
          ),
      ],
    );
  }
}

class _DeviceRow extends StatelessWidget {
  const _DeviceRow({
    required this.device,
    required this.ru,
    this.onRevoke,
  });

  final DeviceInfo device;
  final bool ru;
  final VoidCallback? onRevoke;

  IconData get _icon {
    final String platform = (device.platform ?? '').toLowerCase();
    if (platform.contains('windows') || platform.contains('desktop')) {
      return Icons.desktop_windows_rounded;
    }
    if (platform.contains('android') || platform.contains('ios')) {
      return Icons.smartphone_rounded;
    }
    if (platform.contains('chrome') ||
        platform.contains('browser') ||
        platform.contains('extension')) {
      return Icons.public_rounded;
    }
    return Icons.devices_other_rounded;
  }

  @override
  Widget build(BuildContext context) {
    final bool revoked = _revoked(device);

    final Color accent = revoked
        ? GlukColors.danger.withOpacity(0.7)
        : device.connected
            ? GlukColors.connected
            : GlukColors.text2;

    // Same content and separator as the extension's `.d-sub`: platform, then
    // one status fact - revoked, online (with the node), or last seen.
    final String? platform = device.platform;
    final String? node = device.connectedNodeName;
    final List<String> meta = <String>[
      if (platform != null && platform.isNotEmpty) platform,
      if (revoked)
        ru ? 'отозвано' : 'revoked'
      else if (device.connected)
        node == null || node.isEmpty
            ? (ru ? 'в сети' : 'online')
            : '${ru ? 'в сети' : 'online'} · $node'
      else if (device.lastSeen != null)
        (ru ? 'был(а) ' : 'seen ') + formatDateTime(device.lastSeen!)
      else
        ru ? 'нет данных' : 'no data',
    ];

    final String badgeLabel = revoked
        ? (ru ? 'ОТОЗВАНО' : 'REVOKED')
        : device.isCurrent
            ? (ru ? 'ЭТО УСТРОЙСТВО' : 'THIS DEVICE')
            : (ru ? 'АКТИВНО' : 'ACTIVE');
    final Color badgeColour = revoked
        ? GlukColors.danger
        : device.isCurrent
            ? GlukColors.violetLight
            : GlukColors.connected;

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.03),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: device.isCurrent
              ? GlukColors.violet.withOpacity(0.35)
              : DesktopTokens.cardBorder,
        ),
      ),
      child: Row(
        children: <Widget>[
          Icon(_icon, size: 17, color: accent),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  device.deviceName.isEmpty
                      ? (ru ? 'Без названия' : 'Unnamed')
                      : device.deviceName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: GlukColors.text0,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (meta.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 2),
                  Text(
                    meta.join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: GlukColors.text2,
                      fontSize: 11,
                    ),
                  ),
                ],
              ],
            ),
          ),
          _DeviceBadge(label: badgeLabel, colour: badgeColour),
          if (onRevoke != null) ...<Widget>[
            const SizedBox(width: 6),
            _RevokeLink(
              label: ru ? 'Отозвать' : 'Revoke',
              onTap: onRevoke!,
            ),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Split tunnelling
// ---------------------------------------------------------------------------

class _SplitSection extends StatefulWidget {
  const _SplitSection({
    required this.strings,
    required this.settings,
    required this.vpn,
    required this.onChanged,
    required this.onNotice,
  });

  final DesktopStrings strings;
  final SettingsStore settings;
  final DesktopVpnController vpn;
  final VoidCallback onChanged;
  final ValueChanged<String?> onNotice;

  @override
  State<_SplitSection> createState() => _SplitSectionState();
}

class _SplitSectionState extends State<_SplitSection> {
  List<InstalledApp>? _apps;
  bool _loading = false;

  Future<void> _loadApps() async {
    if (_loading) return;
    setState(() => _loading = true);
    final list = await const AppInventory().list();
    if (!mounted) return;
    setState(() {
      _apps = list;
      _loading = false;
    });
  }

  Future<void> _setMode(SplitMode mode) async {
    await widget.settings.update(
      (DesktopSettings s) => s.copyWith(splitMode: mode),
    );
    widget.onChanged();
    final problem = await widget.vpn.applySplitTunneling();
    widget.onNotice(
      problem == 'reconnect_required'
          ? widget.strings.splitReconnectNeeded
          : problem,
    );
    if (mode != SplitMode.allApps && _apps == null) {
      await _loadApps();
    }
  }

  Future<void> _toggleApp(InstalledApp app, bool selected) async {
    final current = List<String>.from(widget.settings.value.splitApps);
    final key = app.exePath;
    if (selected) {
      if (!current.contains(key)) current.add(key);
    } else {
      current.removeWhere((String e) => e.toLowerCase() == key.toLowerCase());
    }
    await widget.settings.update(
      (DesktopSettings s) => s.copyWith(splitApps: current),
    );
    widget.onChanged();
    setState(() {});
    final problem = await widget.vpn.applySplitTunneling();
    if (problem != null) {
      widget.onNotice(
        problem == 'reconnect_required'
            ? widget.strings.splitReconnectNeeded
            : problem,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.strings;
    final value = widget.settings.value;
    final selected =
        value.splitApps.map((String e) => e.toLowerCase()).toSet();

    return _Section(
      title: s.sectionSplit,
      children: <Widget>[
        _RadioTile<SplitMode>(
          label: s.splitAll,
          value: SplitMode.allApps,
          groupValue: value.splitMode,
          onChanged: _setMode,
        ),
        _RadioTile<SplitMode>(
          label: s.splitOnly,
          value: SplitMode.onlySelected,
          groupValue: value.splitMode,
          onChanged: _setMode,
        ),
        _RadioTile<SplitMode>(
          label: s.splitExclude,
          value: SplitMode.excludeSelected,
          groupValue: value.splitMode,
          onChanged: _setMode,
        ),
        if (value.splitMode != SplitMode.allApps) ...<Widget>[
          const SizedBox(height: 10),
          // Be honest about the engine's limits rather than pretending.
          InlineNotice(message: s.splitLimited, tone: NoticeTone.warning),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Text(
                s.splitPickApps,
                style: const TextStyle(
                  color: GlukColors.text1,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              if (_loading)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                CircleIconButton(
                  icon: Icons.refresh_rounded,
                  tooltip: s.refresh,
                  onTap: _loadApps,
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (_apps == null && !_loading)
            TextButton(
              onPressed: _loadApps,
              child: Text(s.splitPickApps),
            )
          else
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 260),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _apps?.length ?? 0,
                itemBuilder: (BuildContext context, int index) {
                  final app = _apps![index];
                  final checked = selected.contains(app.exePath.toLowerCase());
                  return CheckboxListTile(
                    dense: true,
                    value: checked,
                    onChanged: (bool? v) => _toggleApp(app, v ?? false),
                    controlAffinity: ListTileControlAffinity.leading,
                    activeColor: GlukColors.violet,
                    title: Text(
                      app.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: GlukColors.text0,
                        fontSize: 13,
                      ),
                    ),
                    subtitle: Text(
                      app.running
                          ? '${app.fileName} · ${s.running}'
                          : app.fileName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: app.running
                            ? GlukColors.connected
                            : GlukColors.text2,
                        fontSize: 11,
                      ),
                    ),
                  );
                },
              ),
            ),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Small reusable settings widgets
// ---------------------------------------------------------------------------

/// A section that matters more than the rest: violet frame, title, one-line
/// explanation, then the switches.
class _HeroSection extends StatelessWidget {
  const _HeroSection({
    required this.title,
    required this.subtitle,
    required this.children,
  });

  final String title;
  final String subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
        decoration: DesktopTokens.cardDecoration(
          color: Color.alphaBlend(
            GlukColors.violet.withOpacity(0.10),
            DesktopTokens.card,
          ),
          borderColor: GlukColors.violet.withOpacity(0.32),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Icon(
                  Icons.rocket_launch_rounded,
                  size: 17,
                  color: GlukColors.violetLight,
                ),
                const SizedBox(width: 9),
                Text(
                  title,
                  style: const TextStyle(
                    color: GlukColors.text0,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              subtitle,
              style: const TextStyle(
                color: GlukColors.text1,
                fontSize: 12,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 6),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Text(
              title.toUpperCase(),
              style: const TextStyle(
                color: GlukColors.text2,
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.3,
              ),
            ),
          ),
          GlassPanel(
            radius: 18,
            padding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 8,
            ),
            child: Column(children: children),
          ),
        ],
      ),
    );
  }
}

class _SwitchTile extends StatelessWidget {
  const _SwitchTile({
    required this.label,
    required this.value,
    required this.onChanged,
    this.subtitle,
    this.enabled = true,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;
  final String? subtitle;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    label,
                    style: const TextStyle(
                      color: GlukColors.text0,
                      fontSize: 13,
                    ),
                  ),
                  if (subtitle != null) ...<Widget>[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      style: const TextStyle(
                        color: GlukColors.text2,
                        fontSize: 11,
                        height: 1.3,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 10),
            Switch(
              value: value,
              activeColor: GlukColors.violetLight,
              activeTrackColor: GlukColors.violet.withOpacity(0.5),
              onChanged: enabled ? onChanged : null,
            ),
          ],
        ),
      ),
    );
  }
}

/// A row that explains something and offers one button.
class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.label,
    required this.buttonLabel,
    required this.onPressed,
    this.subtitle,
    this.busy = false,
  });

  final String label;
  final String buttonLabel;
  final VoidCallback onPressed;
  final String? subtitle;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  label,
                  style: const TextStyle(
                    color: GlukColors.text0,
                    fontSize: 13,
                  ),
                ),
                if (subtitle != null) ...<Widget>[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    style: const TextStyle(
                      color: GlukColors.text2,
                      fontSize: 11,
                      height: 1.3,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          _SmallButton(
            label: buttonLabel,
            busy: busy,
            onTap: busy ? null : onPressed,
          ),
        ],
      ),
    );
  }
}

class _SmallButton extends StatelessWidget {
  const _SmallButton({
    required this.label,
    this.onTap,
    this.busy = false,
  });

  final String label;
  final VoidCallback? onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: onTap == null ? 0.5 : 1,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: GlukColors.violet.withOpacity(0.16),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: GlukColors.violet.withOpacity(0.42)),
          ),
          child: busy
              ? const SizedBox(
                  width: 13,
                  height: 13,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(
                  label,
                  style: const TextStyle(
                    color: GlukColors.violetLight,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
        ),
      ),
    );
  }
}

class _RadioTile<T> extends StatelessWidget {
  const _RadioTile({
    required this.label,
    required this.value,
    required this.groupValue,
    required this.onChanged,
  });

  final String label;
  final T value;
  final T groupValue;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final selected = value == groupValue;
    return InkWell(
      onTap: () => onChanged(value),
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: Row(
          children: <Widget>[
            Icon(
              selected
                  ? Icons.radio_button_checked_rounded
                  : Icons.radio_button_off_rounded,
              size: 18,
              color: selected ? GlukColors.violetLight : GlukColors.text2,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: selected ? GlukColors.text0 : GlukColors.text1,
                  fontSize: 13,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChoiceTile<T> extends StatelessWidget {
  const _ChoiceTile({
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final String label;
  final T value;
  final Map<T, String> options;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                color: GlukColors.text0,
                fontSize: 13,
              ),
            ),
          ),
          DropdownButton<T>(
            value: value,
            underline: const SizedBox.shrink(),
            dropdownColor: GlukColors.bg,
            style: const TextStyle(color: GlukColors.text0, fontSize: 13),
            items: options.entries
                .map(
                  (MapEntry<T, String> e) => DropdownMenuItem<T>(
                    value: e.key,
                    child: Text(e.value),
                  ),
                )
                .toList(),
            onChanged: (T? v) {
              if (v != null) onChanged(v);
            },
          ),
        ],
      ),
    );
  }
}

class _TextTile extends StatefulWidget {
  const _TextTile({
    required this.label,
    required this.value,
    required this.onSubmitted,
    this.subtitle,
    this.hint,
  });

  final String label;
  final String value;
  final ValueChanged<String> onSubmitted;
  final String? subtitle;
  final String? hint;

  @override
  State<_TextTile> createState() => _TextTileState();
}

class _TextTileState extends State<_TextTile> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.value);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            widget.label,
            style: const TextStyle(color: GlukColors.text0, fontSize: 13),
          ),
          if (widget.subtitle != null) ...<Widget>[
            const SizedBox(height: 2),
            Text(
              widget.subtitle!,
              style: const TextStyle(
                color: GlukColors.text2,
                fontSize: 11,
                height: 1.3,
              ),
            ),
          ],
          const SizedBox(height: 8),
          TextField(
            controller: _controller,
            onSubmitted: widget.onSubmitted,
            onTapOutside: (_) => widget.onSubmitted(_controller.text),
            style: const TextStyle(color: GlukColors.text0, fontSize: 13),
            cursorColor: GlukColors.violetLight,
            decoration: InputDecoration(
              isDense: true,
              hintText: widget.hint,
              hintStyle:
                  const TextStyle(color: GlukColors.text2, fontSize: 13),
              filled: true,
              fillColor: Colors.white.withOpacity(0.04),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 11,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(11),
                borderSide: BorderSide(color: GlukColors.stroke),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(11),
                borderSide: BorderSide(color: GlukColors.stroke),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(11),
                borderSide: const BorderSide(color: GlukColors.violet),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoTile extends StatelessWidget {
  const _InfoTile({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              label,
              style: const TextStyle(color: GlukColors.text1, fontSize: 13),
            ),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              value,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
              style: const TextStyle(
                color: GlukColors.text0,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
