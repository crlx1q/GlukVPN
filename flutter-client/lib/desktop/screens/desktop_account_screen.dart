import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../state/auth_controller.dart';
import '../../theme/tokens.dart';
import '../../utils/format.dart';
// Shared with the phone: one definition of what a device looks like.
import '../../widgets/device_icon.dart';
import '../../widgets/glass.dart';
import '../i18n/desktop_strings.dart';
import '../state/desktop_vpn_controller.dart';
import '../theme/desktop_theme.dart';

/// Account, on its own screen (round 6, requirement 11).
///
/// It used to be the seventh section of Settings, which was wrong for two
/// reasons: the account is not a setting, and burying the device list under six
/// other sections meant nobody found it. The browser extension already treats
/// this as its own view (`#view-profile`), so the desktop client now matches -
/// same information, same grouping, same words.
class DesktopAccountScreen extends StatefulWidget {
  const DesktopAccountScreen({
    super.key,
    required this.auth,
    required this.vpn,
    required this.strings,
  });

  final AuthController auth;
  final DesktopVpnController vpn;
  final DesktopStrings strings;

  @override
  State<DesktopAccountScreen> createState() => _DesktopAccountScreenState();
}

/// Mirrors the extension's `#seg-devices` filter.
enum _DeviceFilter { all, active, revoked }

class _DesktopAccountScreenState extends State<DesktopAccountScreen> {
  List<DeviceInfo>? _devices;
  int _maxDevices = 0;
  bool _loading = false;
  String? _error;
  String? _notice;
  String? _busyDeviceId;
  _DeviceFilter _filter = _DeviceFilter.all;
  bool _showAll = false;

  bool get _ru => widget.strings.isRussian;

  /// Six rows is about one screen of list before the page starts scrolling for
  /// no good reason. The extension paginates for the same reason.
  static const int _collapsedCount = 6;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final DevicesResult result = await widget.vpn.api.devices();
      if (!mounted) return;
      setState(() {
        _devices = result.devices;
        _maxDevices = result.maxDevices;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = _ru
            ? 'Не удалось загрузить устройства'
            : 'Could not load devices';
      });
    }
  }

  /// Signs a device out. ROUND 6: this deletes the row instead of leaving a
  /// tombstone, which is why the button says "Выйти" and not "Отозвать" - the
  /// user asked for exactly that, and 48 dead rows against a limit of 3 was the
  /// bug it fixes.
  Future<void> _signOutDevice(DeviceInfo device) async {
    if (_busyDeviceId != null) return;
    setState(() {
      _busyDeviceId = device.id;
      _notice = null;
    });
    try {
      await widget.vpn.api.removeDevice(device.id);
      if (!mounted) return;
      setState(() {
        _busyDeviceId = null;
        _notice = device.isCurrent
            ? (_ru
                ? 'Это устройство отключено. Сессия здесь тоже закрыта.'
                : 'This device was signed out. The session here is closed too.')
            : (_ru
                ? 'Устройство вышло из аккаунта и удалено из списка.'
                : 'The device signed out and was removed from the list.');
      });
      await _load();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busyDeviceId = null;
        _notice = _ru
            ? 'Не удалось отключить устройство'
            : 'Could not sign that device out';
      });
    }
  }

  Future<void> _confirmSignOutDevice(DeviceInfo device) async {
    final bool ok = await _confirm(
      title: _ru ? 'Выйти на этом устройстве?' : 'Sign this device out?',
      body: _ru
          ? 'Устройство «${device.deviceName}» выйдет из аккаунта и исчезнет из '
              'списка. Если это ваш телефон, войти можно будет снова в любой момент.'
          : '"${device.deviceName}" will be signed out and removed from the '
              'list. You can sign back in on it at any time.',
      confirmLabel: _ru ? 'Выйти' : 'Sign out',
    );
    if (ok) await _signOutDevice(device);
  }

  Future<bool> _confirm({
    required String title,
    required String body,
    required String confirmLabel,
  }) async {
    final bool? answer = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        backgroundColor: DesktopTokens.cardRaised,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(DesktopTokens.innerRadius),
        ),
        title: Text(
          title,
          style: const TextStyle(
            color: GlukColors.text0,
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
        ),
        content: Text(
          body,
          style: const TextStyle(color: GlukColors.text1, fontSize: 12.5),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(
              _ru ? 'Отмена' : 'Cancel',
              style: const TextStyle(color: GlukColors.text2),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(
              confirmLabel,
              style: const TextStyle(color: GlukColors.danger),
            ),
          ),
        ],
      ),
    );
    return answer ?? false;
  }

  Future<void> _signOutHere() async {
    final bool ok = await _confirm(
      title: _ru ? 'Выйти из аккаунта?' : 'Sign out?',
      body: _ru
          ? 'Туннель будет отключён, а это устройство удалено из списка. '
              'Подписка и статистика останутся на аккаунте.'
          : 'The tunnel will be disconnected and this device removed from the '
              'list. Your subscription and history stay on the account.',
      confirmLabel: _ru ? 'Выйти' : 'Sign out',
    );
    if (!ok) return;
    await widget.vpn.disconnect(userInitiated: false);
    await widget.auth.logout();
  }

  @override
  Widget build(BuildContext context) {
    final DesktopStrings s = widget.strings;

    return AnimatedBuilder(
      animation: widget.auth,
      builder: (BuildContext context, Widget? _) {
        final List<DeviceInfo> all = _ordered(_devices ?? const <DeviceInfo>[]);
        final int activeCount = all.where((DeviceInfo d) => d.isActive).length;
        final int revokedCount = all.length - activeCount;
        final List<DeviceInfo> filtered = all.where(_matchesFilter).toList();
        final bool truncated =
            !_showAll && filtered.length > _collapsedCount;
        final List<DeviceInfo> shown = truncated
            ? filtered.sublist(0, _collapsedCount)
            : filtered;

        return ListView(
          padding: const EdgeInsets.fromLTRB(
            DesktopTokens.pagePadding,
            4,
            DesktopTokens.pagePadding,
            DesktopTokens.pagePadding,
          ),
          children: <Widget>[
            Text(
              s.sectionAccount,
              style: const TextStyle(
                color: GlukColors.text0,
                fontSize: 19,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),

            _ProfileHeader(auth: widget.auth, ru: _ru),
            const SizedBox(height: 12),

            // The extension's `.prof-grid`: four facts, no prose.
            _FactsGrid(
              items: <_Fact>[
                _Fact(
                  label: s.plan,
                  value: widget.auth.subscription?.displayPlan ?? '—',
                ),
                _Fact(
                  label: s.expires,
                  value: widget.auth.subscription?.expiresAt == null
                      ? (_ru ? 'бессрочно' : 'unlimited')
                      : formatDateTime(widget.auth.subscription!.expiresAt!),
                ),
                _Fact(
                  label: _ru ? 'Устройства' : 'Devices',
                  value: _maxDevices > 0
                      ? '$activeCount / $_maxDevices'
                      : '$activeCount',
                ),
                _Fact(
                  label: _ru ? 'Сессий сразу' : 'Concurrent',
                  value: '${widget.auth.user?.maxConcurrentSessions ?? 1}',
                ),
              ],
            ),

            if (_notice != null) ...<Widget>[
              const SizedBox(height: 12),
              InlineNotice(message: _notice!),
            ],

            const SizedBox(height: 18),
            Row(
              children: <Widget>[
                Text(
                  _ru ? 'Устройства' : 'Devices',
                  style: const TextStyle(
                    color: GlukColors.text0,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                IconButton(
                  tooltip: s.refresh,
                  onPressed: _loading ? null : _load,
                  icon: const Icon(
                    Icons.refresh_rounded,
                    size: 17,
                    color: GlukColors.text2,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),

            _DeviceSegments(
              filter: _filter,
              ru: _ru,
              allCount: all.length,
              activeCount: activeCount,
              revokedCount: revokedCount,
              onChanged: (_DeviceFilter next) => setState(() {
                _filter = next;
                _showAll = false;
              }),
            ),
            const SizedBox(height: 10),

            if (_error != null)
              InlineNotice(message: _error!)
            else if (_loading && _devices == null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 18),
                child: Center(
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 1.8),
                  ),
                ),
              )
            else if (shown.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 14),
                child: Text(
                  _ru ? 'Здесь пока пусто' : 'Nothing here yet',
                  style: const TextStyle(
                    color: GlukColors.text2,
                    fontSize: 12.5,
                  ),
                ),
              )
            else
              ...shown.map(
                (DeviceInfo device) => _DeviceRow(
                  device: device,
                  ru: _ru,
                  busy: _busyDeviceId == device.id,
                  onSignOut: () => _confirmSignOutDevice(device),
                ),
              ),

            if (truncated)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () => setState(() => _showAll = true),
                  child: Text(
                    _ru
                        ? 'Показать все (${filtered.length})'
                        : 'Show all (${filtered.length})',
                    style: const TextStyle(
                      color: GlukColors.violetLight,
                      fontSize: 12,
                    ),
                  ),
                ),
              ),

            const SizedBox(height: 22),
            // ROUND 7: back to the pill it always was, just at desktop
            // density. Sign-out is rare, but it is the one action people open
            // this screen for, so hiding it in a quiet outline was a step back.
            PrimaryPillButton(
              label: s.logout,
              icon: Icons.logout_rounded,
              compact: true,
              onPressed: () {
                _signOutHere();
              },
            ),
            const SizedBox(height: 10),
            Text(
              _ru
                  ? 'При выходе устройство удаляется из списка — войдёте снова, '
                      'и оно появится заново.'
                  : 'Signing out removes this device from the list. It comes '
                      'back the next time you sign in.',
              style: const TextStyle(color: GlukColors.text2, fontSize: 11.5),
            ),
          ],
        );
      },
    );
  }

  bool _matchesFilter(DeviceInfo device) {
    switch (_filter) {
      case _DeviceFilter.all:
        return true;
      case _DeviceFilter.active:
        return device.isActive;
      case _DeviceFilter.revoked:
        return !device.isActive;
    }
  }

  /// This device first, then active by last-seen, revoked last - the extension's
  /// order, so the two clients cannot disagree about what "first" means.
  static List<DeviceInfo> _ordered(List<DeviceInfo> list) {
    int rank(DeviceInfo d) {
      if (d.isCurrent) return 0;
      if (!d.isActive) return 2;
      return 1;
    }

    final List<DeviceInfo> sorted = List<DeviceInfo>.of(list);
    sorted.sort((DeviceInfo a, DeviceInfo b) {
      final int byRank = rank(a).compareTo(rank(b));
      if (byRank != 0) return byRank;
      final DateTime? sa = a.lastSeen;
      final DateTime? sb = b.lastSeen;
      if (sa == null && sb == null) return 0;
      if (sa == null) return 1;
      if (sb == null) return -1;
      return sb.compareTo(sa);
    });
    return sorted;
  }
}

// ---------------------------------------------------------------------------
// Pieces
// ---------------------------------------------------------------------------

class _ProfileHeader extends StatelessWidget {
  const _ProfileHeader({required this.auth, required this.ru});

  final AuthController auth;
  final bool ru;

  @override
  Widget build(BuildContext context) {
    final AuthUser? user = auth.user;
    final String name = user?.username ?? (ru ? 'Аккаунт' : 'Account');
    final String initial =
        name.trim().isEmpty ? '?' : name.trim().substring(0, 1).toUpperCase();
    final bool active = auth.subscription?.isActive ?? false;
    final Color accent = active ? GlukColors.connected : GlukColors.violetLight;

    final String publicId = user?.publicIdLabel ?? '';
    final String? email = user?.email;
    final String? origin = user?.originLabel;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: DesktopTokens.cardDecoration(
        color: DesktopTokens.cardRaised,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            width: 56,
            height: 56,
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
                fontSize: 23,
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
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _Chip(
                      label: auth.subscription?.displayPlan ?? '—',
                      colour: GlukColors.violetLight,
                    ),
                    if (user?.isAdmin ?? false) ...<Widget>[
                      const SizedBox(width: 6),
                      _Chip(label: 'ADMIN', colour: GlukColors.amber),
                    ],
                  ],
                ),
                const SizedBox(height: 8),
                if (publicId.isNotEmpty)
                  _MetaLine(icon: Icons.badge_outlined, text: publicId),
                if (email != null)
                  _MetaLine(
                    icon: Icons.alternate_email_rounded,
                    text: email,
                  ),
                if (origin != null)
                  _MetaLine(icon: Icons.place_outlined, text: origin),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.colour});

  final String label;
  final Color colour;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: colour.withOpacity(0.14),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: colour.withOpacity(0.35)),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: colour,
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.4,
          ),
        ),
      );
}

class _MetaLine extends StatelessWidget {
  const _MetaLine({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
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
          ],
        ),
      );
}

class _Fact {
  const _Fact({required this.label, required this.value});

  final String label;
  final String value;
}

class _FactsGrid extends StatelessWidget {
  const _FactsGrid({required this.items});

  final List<_Fact> items;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        // Two columns unless the window is genuinely narrow; four tiles in one
        // row turns the values into ellipses.
        final int columns = c.maxWidth >= 520 ? 4 : 2;
        final double gap = 10;
        final double width =
            (c.maxWidth - gap * (columns - 1)) / columns;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: items
              .map(
                (_Fact f) => SizedBox(
                  width: width,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 11,
                    ),
                    decoration: DesktopTokens.cardDecoration(
                      color: DesktopTokens.card,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          f.label.toUpperCase(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: GlukColors.text2,
                            fontSize: 9.5,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.6,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          f.value,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: GlukColors.text0,
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              )
              .toList(),
        );
      },
    );
  }
}

/// The extension's `#seg-devices`, with live counts so the filter is honest
/// about how much it is hiding.
class _DeviceSegments extends StatelessWidget {
  const _DeviceSegments({
    required this.filter,
    required this.ru,
    required this.allCount,
    required this.activeCount,
    required this.revokedCount,
    required this.onChanged,
  });

  final _DeviceFilter filter;
  final bool ru;
  final int allCount;
  final int activeCount;
  final int revokedCount;
  final ValueChanged<_DeviceFilter> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: DesktopTokens.card,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: DesktopTokens.hairline),
      ),
      child: Row(
        children: <Widget>[
          _seg(_DeviceFilter.all, ru ? 'Все' : 'All', allCount),
          _seg(_DeviceFilter.active, ru ? 'Активные' : 'Active', activeCount),
          _seg(_DeviceFilter.revoked, ru ? 'Вышли' : 'Signed out', revokedCount),
        ],
      ),
    );
  }

  Widget _seg(_DeviceFilter value, String label, int count) {
    final bool on = value == filter;
    return Expanded(
      child: Material(
        color: on ? GlukColors.violet.withOpacity(0.22) : Colors.transparent,
        borderRadius: BorderRadius.circular(999),
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: () => onChanged(value),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 7),
            child: Text(
              '$label · $count',
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: on ? GlukColors.text0 : GlukColors.text2,
                fontSize: 11.5,
                fontWeight: on ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DeviceRow extends StatelessWidget {
  const _DeviceRow({
    required this.device,
    required this.ru,
    required this.busy,
    required this.onSignOut,
  });

  final DeviceInfo device;
  final bool ru;
  final bool busy;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    final bool revoked = !device.isActive;
    final Color accent = revoked
        ? GlukColors.text2
        : (device.connected ? GlukColors.connected : GlukColors.violetLight);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      decoration: DesktopTokens.cardDecoration(color: DesktopTokens.card),
      child: Row(
        children: <Widget>[
          Icon(
            iconForDevicePlatform(device.platform),
            size: 18,
            color: accent,
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Flexible(
                      child: Text(
                        device.deviceName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: revoked ? GlukColors.text2 : GlukColors.text0,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (device.isCurrent) ...<Widget>[
                      const SizedBox(width: 7),
                      _Chip(
                        label: ru ? 'ЭТО УСТРОЙСТВО' : 'THIS DEVICE',
                        colour: GlukColors.violetLight,
                      ),
                    ] else if (revoked) ...<Widget>[
                      const SizedBox(width: 7),
                      _Chip(
                        label: ru ? 'ВЫШЕЛ' : 'SIGNED OUT',
                        colour: GlukColors.text2,
                      ),
                    ] else if (device.connected) ...<Widget>[
                      const SizedBox(width: 7),
                      _Chip(
                        label: ru ? 'В СЕТИ' : 'ONLINE',
                        colour: GlukColors.connected,
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  _subtitle(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: GlukColors.text2,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          if (!revoked)
            busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 1.6),
                  )
                : TextButton(
                    onPressed: onSignOut,
                    style: TextButton.styleFrom(
                      minimumSize: const Size(0, 30),
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                    ),
                    child: Text(
                      // Renamed from "Отозвать": the row is deleted now, and
                      // "revoke" described the old tombstone behaviour.
                      ru ? 'Выйти' : 'Sign out',
                      style: const TextStyle(
                        color: GlukColors.danger,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
        ],
      ),
    );
  }

  String _subtitle() {
    final List<String> parts = <String>[];
    final String platform = describeDevicePlatform(device.platform, ru: ru);
    if (platform.isNotEmpty) parts.add(platform);
    if (device.connected && device.connectedNodeName != null) {
      parts.add(device.connectedNodeName!);
    }
    final DateTime? seen = device.lastSeen;
    if (seen != null) {
      parts.add((ru ? 'был(а) ' : 'last seen ') + formatDateTime(seen));
    } else if (device.createdAt != null) {
      parts.add((ru ? 'добавлено ' : 'added ') + formatDateTime(device.createdAt!));
    }
    return parts.join(' · ');
  }
}

