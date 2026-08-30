import 'package:flutter/material.dart';

import '../../config.dart';
import '../../platform/tunnel_backend.dart';
import '../../state/auth_controller.dart';
import '../../theme/tokens.dart';
import '../../utils/format.dart';
import '../../widgets/common.dart';
import '../../widgets/glass.dart';
import '../i18n/desktop_strings.dart';
import '../services/app_inventory.dart';
import '../services/autostart_service.dart';
import '../state/desktop_settings.dart';
import '../state/desktop_vpn_controller.dart';
import '../logic/connection_phase.dart';

/// Settings (requirement 13).
///
/// Four sections: General, VPN, Split tunneling, Account. Diagnostics are
/// deliberately only compiled into internal builds.
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

  DesktopSettings get _value => widget.settings.value;

  Future<void> _patch(
    DesktopSettings Function(DesktopSettings s) mutate,
  ) async {
    await widget.settings.update(mutate);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.strings;

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

        _Section(
          title: s.sectionGeneral,
          children: <Widget>[
            _SwitchTile(
              label: s.startWithWindows,
              value: _value.startWithWindows,
              onChanged: (bool v) async {
                await _patch((DesktopSettings x) =>
                    x.copyWith(startWithWindows: v));
                _autostart.apply(
                  startWithWindows: v,
                  startMinimized: _value.startMinimized,
                );
              },
            ),
            _SwitchTile(
              label: s.startMinimized,
              value: _value.startMinimized,
              enabled: _value.startWithWindows,
              onChanged: (bool v) async {
                await _patch(
                    (DesktopSettings x) => x.copyWith(startMinimized: v));
                _autostart.apply(
                  startWithWindows: _value.startWithWindows,
                  startMinimized: v,
                );
              },
            ),
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
              value: _value.animationsEnabled,
              onChanged: (bool v) => _patch(
                (DesktopSettings x) => x.copyWith(animationsEnabled: v),
              ),
            ),
            _SwitchTile(
              label: s.reduceMotion,
              value: _value.reduceMotion,
              onChanged: (bool v) =>
                  _patch((DesktopSettings x) => x.copyWith(reduceMotion: v)),
            ),
          ],
        ),

        _Section(
          title: s.sectionVpn,
          children: <Widget>[
            _SwitchTile(
              label: s.autoConnect,
              value: _value.autoConnect,
              onChanged: (bool v) =>
                  _patch((DesktopSettings x) => x.copyWith(autoConnect: v)),
            ),
            _SwitchTile(
              label: s.killSwitch,
              subtitle: s.killSwitchHint,
              value: _value.killSwitch,
              onChanged: (bool v) async {
                await _patch(
                    (DesktopSettings x) => x.copyWith(killSwitch: v));
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
                final list = raw
                    .split(RegExp(r'[,\s]+'))
                    .map((String e) => e.trim())
                    .where((String e) => e.isNotEmpty)
                    .toList();
                _patch((DesktopSettings x) => x.copyWith(dns: list));
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
            // MTU is an advanced knob; only internal builds expose it so a
            // normal user cannot silently break their own path MTU.
            if (AppConfig.internalBuild)
              _TextTile(
                label: s.mtu,
                value: _value.mtu?.toString() ?? '',
                hint: '1420',
                onSubmitted: (String raw) {
                  final parsed = int.tryParse(raw.trim());
                  _patch(
                    (DesktopSettings x) => parsed == null
                        ? x.copyWith(clearMtu: true)
                        : x.copyWith(mtu: parsed),
                  );
                },
              ),
          ],
        ),

        _SplitSection(
          strings: s,
          settings: widget.settings,
          vpn: widget.vpn,
          onChanged: () => setState(() {}),
          onNotice: (String? message) => setState(() => _notice = message),
        ),

        _Section(
          title: s.sectionAccount,
          children: <Widget>[
            _InfoTile(
              label: widget.auth.user?.username ?? '—',
              value: widget.auth.user?.publicIdLabel ?? '',
            ),
            _InfoTile(
              label: s.plan,
              value: widget.auth.subscription?.status ?? s.free,
            ),
            if (widget.auth.subscription?.expiresAt != null)
              _InfoTile(
                label: s.expires,
                value: formatDateTime(widget.auth.subscription!.expiresAt!),
              ),
            Padding(
              padding: const EdgeInsets.only(top: 12),
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
    final selected = value.splitApps
        .map((String e) => e.toLowerCase())
        .toSet();

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
                  final checked =
                      selected.contains(app.exePath.toLowerCase());
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
                      app.running ? '${app.fileName} · ${s.running}'
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
                      ),
                    ),
                  ],
                ],
              ),
            ),
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
              style: const TextStyle(color: GlukColors.text2, fontSize: 11),
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
          Text(
            value,
            style: const TextStyle(
              color: GlukColors.text0,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
