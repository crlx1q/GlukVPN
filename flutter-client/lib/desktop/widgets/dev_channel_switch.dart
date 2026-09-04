import 'dart:async';

import 'package:flutter/material.dart';

import '../../config.dart';
import '../../models/models.dart';
import '../../services/api_client.dart';
import '../../theme/tokens.dart';
import '../i18n/desktop_strings.dart';

/// The version line at the bottom of Settings, and the channel card under it.
///
/// Ordinary users must never see a channel switch. Pointing a normal install at
/// beta hands them a control plane full of test data and half-finished nodes,
/// and nothing on screen would explain why their VPN suddenly behaves oddly.
///
/// ROUND 11: it used to hide behind five clicks on the version number. That was
/// the wrong control. A secret gesture is not a permission - it let a normal
/// user uncover a switch the beta plane would then refuse them, while an admin
/// had to know the trick to reach something they are entitled to. The rule is
/// now the same one the phone and the browser extension use: admins and
/// flagged testers see it, nobody else does.
///
/// ROUND 26: the shared "channel card" all three clients draw.
///
///  * two segmented pills, PROD and BETA, each with a reachability dot and the
///    version of that control plane underneath;
///  * the target is probed (`GET /api/version`, 1.5 s) *before* anything moves.
///    A beta that is switched off used to sign the tester out and leave the
///    app pointed at a dead host; now it says so and the session stays;
///  * switching is refused while a tunnel is up or changing: the peer on the
///    node belongs to the session that is about to be signed out.
///
/// The switch is deliberately symmetric: it stays reachable while beta is
/// active. A one-way door would mean the only way back to prod is a reinstall.
class DevChannelFooter extends StatefulWidget {
  const DevChannelFooter({
    super.key,
    required this.strings,
    required this.api,
    required this.onChannelChanged,
    this.canSwitch = false,
    this.locked = false,
    this.alwaysVisible = false,
  });

  final DesktopStrings strings;

  /// Used only for the unauthenticated `/api/version` probes.
  final ApiClient api;

  /// The signed-in account may switch channels (`AuthUser.canUseBetaChannel`:
  /// administrators and flagged testers). This is the only thing that reveals
  /// the card in a shipped build.
  final bool canSwitch;

  /// A tunnel is up or in transition. The pills go inert and the card says
  /// "Disconnect the VPN first".
  final bool locked;

  /// Escape hatch for internal builds and tests; not used in production.
  final bool alwaysVisible;

  /// Called right after the channel changed, with the channel that was picked.
  ///
  /// The session belongs to exactly one control plane - a prod refresh token is
  /// meaningless on beta - so the caller signs out. Leaving the old session in
  /// place produces 401s that look like a broken account.
  ///
  /// ROUND 9 (1.3): the channel is passed out rather than read back from
  /// AppConfig, because the caller also has to write it to settings.json. An
  /// in-memory override alone was lost on restart, which is how a tester ended
  /// up back on production without noticing.
  final Future<void> Function(AppChannel channel) onChannelChanged;

  @override
  State<DevChannelFooter> createState() => _DevChannelFooterState();
}

class _DevChannelFooterState extends State<DevChannelFooter> {
  /// What each control plane answered, once it has been asked. A key that is
  /// present with a null value means "asked, unreachable".
  final Map<AppChannel, ChannelVersion?> _versions =
      <AppChannel, ChannelVersion?>{};

  /// The pill whose control plane is being probed right now.
  AppChannel? _probing;
  bool _switching = false;
  String? _error;

  bool get _visible =>
      widget.canSwitch || widget.alwaysVisible || AppConfig.internalBuild;

  bool get _busy => _probing != null || _switching;

  List<AppChannel> get _channels => <AppChannel>[
        AppChannel.prod,
        if (AppConfig.betaChannelAvailable) AppChannel.beta,
      ];

  @override
  void initState() {
    super.initState();
    if (_visible) unawaited(_probeAll());
  }

  /// Fills in the dots and versions under the pills. Concurrent: the two
  /// probes have nothing to do with each other.
  Future<void> _probeAll() async {
    await Future.wait<void>(_channels.map(_probe));
  }

  Future<ChannelVersion?> _probe(AppChannel channel) async {
    final ChannelVersion? version =
        await widget.api.probeChannel(AppConfig.baseUrlFor(channel));
    if (mounted) setState(() => _versions[channel] = version);
    return version;
  }

  Future<void> _select(AppChannel channel) async {
    final DesktopStrings s = widget.strings;
    if (_busy || channel == AppConfig.activeChannel) return;

    if (widget.locked) {
      setState(() => _error = s.channelDisconnectFirst);
      return;
    }
    // A build compiled without beta refuses the override outright.
    if (channel.isBeta && !AppConfig.betaChannelAvailable) {
      setState(() => _error = s.channelRefused);
      return;
    }

    setState(() {
      _probing = channel;
      _error = null;
    });

    // Ask first, move second. The session is untouched unless the target
    // control plane actually answers.
    final ChannelVersion? reachable = await _probe(channel);
    if (!mounted) return;
    if (reachable == null) {
      setState(() {
        _probing = null;
        _error =
            channel.isBeta ? s.channelBetaUnavailable : s.channelProdUnavailable;
      });
      return;
    }

    if (!AppConfig.setChannelOverride(channel)) {
      setState(() {
        _probing = null;
        _error = s.channelRefused;
      });
      return;
    }

    setState(() => _switching = true);
    try {
      await widget.onChannelChanged(channel);
    } finally {
      if (mounted) {
        setState(() {
          _switching = false;
          _probing = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final DesktopStrings s = widget.strings;
    final AppChannel active = AppConfig.activeChannel;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          'GlukVPN Desktop ${AppConfig.appVersion} \u00b7 ${active.label}',
          style: const TextStyle(color: GlukColors.text2, fontSize: 11),
        ),
        if (_visible) ...<Widget>[
          const SizedBox(height: 12),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: _card(context, s, active),
          ),
        ],
      ],
    );
  }

  Widget _card(BuildContext context, DesktopStrings s, AppChannel active) {
    final Color accent = active.isBeta ? GlukColors.amber : GlukColors.violet;
    final ChannelVersion? activeVersion = _versions[active];
    final String activeName = active.isBeta ? 'BETA' : 'PRODUCTION';
    final String statusLine =
        '${s.channelUsing}: $activeName \u00b7 ${activeVersion?.version ?? s.dash}';

    // One hint line, by priority: the error, the lock, the plain explanation.
    final String? error = _error;
    final String hint = error ??
        (widget.locked ? s.channelDisconnectFirst : s.channelHint);
    final Color hintColour = error != null
        ? GlukColors.danger
        : widget.locked
            ? GlukColors.amber
            : GlukColors.text2;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: accent.withOpacity(0.06),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: accent.withOpacity(0.24)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            s.channel,
            style: const TextStyle(
              color: GlukColors.text1,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              for (int i = 0; i < _channels.length; i++) ...<Widget>[
                if (i > 0) const SizedBox(width: 8),
                Expanded(
                  child: _ChannelPill(
                    channel: _channels[i],
                    active: _channels[i] == active,
                    version: _versions[_channels[i]],
                    probed: _versions.containsKey(_channels[i]),
                    probing: _probing == _channels[i],
                    enabled: !_busy && !widget.locked,
                    offLabel: s.channelOff,
                    onTap: () => _select(_channels[i]),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  statusLine,
                  style: TextStyle(
                    color: active.isBeta ? GlukColors.amber : GlukColors.text0,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (_switching)
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 1.6),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            hint,
            style: TextStyle(color: hintColour, fontSize: 10.5, height: 1.35),
          ),
        ],
      ),
    );
  }
}

/// One segment of the PROD / BETA control: the pill itself, then a dot and
/// that control plane's version (or "off") underneath.
///
/// Active PROD is filled violet, active BETA is filled amber - the colour the
/// whole product reserves for the beta badge - and the inactive one is drawn
/// as an outline, so the pair reads as a segmented control rather than two
/// buttons.
class _ChannelPill extends StatelessWidget {
  const _ChannelPill({
    required this.channel,
    required this.active,
    required this.version,
    required this.probed,
    required this.probing,
    required this.enabled,
    required this.offLabel,
    required this.onTap,
  });

  final AppChannel channel;
  final bool active;
  final ChannelVersion? version;

  /// False until the first probe has answered; the caption shows "…" then.
  final bool probed;
  final bool probing;
  final bool enabled;
  final String offLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final Color tint = channel.isBeta ? GlukColors.amber : GlukColors.violet;
    final bool reachable = version != null;
    final String caption = reachable
        ? version!.version
        : probed
            ? offLabel
            : '\u2026';

    final Widget label = probing
        ? SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(
              strokeWidth: 1.6,
              color: active ? GlukColors.text0 : tint,
            ),
          )
        : Text(
            channel.label,
            style: TextStyle(
              color: active ? GlukColors.text0 : GlukColors.text1,
              fontSize: 11.5,
              fontWeight: active ? FontWeight.w800 : FontWeight.w600,
              letterSpacing: 0.8,
            ),
          );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Opacity(
          opacity: enabled || active ? 1 : 0.55,
          child: InkWell(
            borderRadius: BorderRadius.circular(999),
            onTap: enabled ? onTap : null,
            child: Container(
              height: 30,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: active ? tint.withOpacity(0.85) : Colors.transparent,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: active ? tint : GlukColors.text2.withOpacity(0.55),
                  width: active ? 1 : 1.2,
                ),
              ),
              child: label,
            ),
          ),
        ),
        const SizedBox(height: 6),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: reachable ? GlukColors.connected : GlukColors.text2,
              ),
            ),
            const SizedBox(width: 5),
            Text(
              caption,
              style: TextStyle(
                color: reachable ? GlukColors.text1 : GlukColors.text2,
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ],
    );
  }
}
