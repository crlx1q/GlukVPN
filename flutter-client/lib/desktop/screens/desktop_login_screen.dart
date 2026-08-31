import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../config.dart';
import '../../services/api_client.dart';
import '../../state/auth_controller.dart';
import '../../theme/tokens.dart';
import '../../widgets/dotted_world.dart';
import '../../widgets/glass.dart';
import '../../widgets/logo.dart';
import '../../widgets/social_icons.dart';
import '../i18n/desktop_strings.dart';
import '../theme/desktop_theme.dart';
import '../widgets/window_title_bar.dart';

/// Sign-in, rebuilt as a two-column composition.
///
/// The single centred card was the weakest screen in the client: it wasted a
/// 1080 px window on a 380 px box and said nothing about the product. This is
/// the layout the user asked for, and the one every serious desktop client uses
/// (Cloudflare's dashboard being the reference they sent): the form on the
/// left, a full-height brand panel on the right.
///
/// The right panel is not a picture. It is the same [DottedWorld] painter the
/// home screen uses, running as a slowly rotating globe with live orbital
/// arcs, so the first frame the user ever sees is already the product's own
/// world - and it costs one animation controller.
///
/// The form itself is a copy of the mobile sign-in flow, deliberately: same
/// identifier-or-email field, same validation rules, same "or continue with"
/// row, plus the extension's "sign in on the website" path. One account, three
/// clients, one way in.
class DesktopLoginScreen extends StatefulWidget {
  const DesktopLoginScreen({
    super.key,
    required this.auth,
    required this.strings,
  });

  final AuthController auth;
  final DesktopStrings strings;

  @override
  State<DesktopLoginScreen> createState() => _DesktopLoginScreenState();
}

class _DesktopLoginScreenState extends State<DesktopLoginScreen>
    with SingleTickerProviderStateMixin {
  final TextEditingController _identifier = TextEditingController();
  final TextEditingController _password = TextEditingController();
  final FocusNode _identifierFocus = FocusNode();
  final FocusNode _passwordFocus = FocusNode();

  late final AnimationController _spin;

  bool _obscure = true;

  /// Validation and transport errors raised here, as opposed to the controller's
  /// own error, which survives a screen rebuild.
  String? _localError;

  static const String _siteUrl = 'https://vpn.gluk.tech';

  bool get _ru => widget.strings.isRussian;

  @override
  void initState() {
    super.initState();
    _spin = AnimationController(
      vsync: this,
      duration: GlukMotion.globeSpin,
    )..repeat();
    _identifierFocus.requestFocus();
  }

  @override
  void dispose() {
    _spin.dispose();
    _identifier.dispose();
    _password.dispose();
    _identifierFocus.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  // ---- validation, mirroring lib/screens/login_screen.dart ----

  String? _validate() {
    final String id = _identifier.text.trim();
    final String password = _password.text;

    if (id.isEmpty) {
      return _ru ? 'Введите логин или email' : 'Enter your username or email';
    }
    if (id.contains('@')) {
      final bool looksLikeEmail = id.contains('.') &&
          id.indexOf('@') > 0 &&
          id.indexOf('@') < id.length - 1 &&
          !id.contains(' ');
      if (!looksLikeEmail) {
        return _ru ? 'Некорректный email' : 'Enter a valid email address';
      }
    } else if (id.length < AppConfig.minUsernameLength) {
      return _ru
          ? 'Минимум ${AppConfig.minUsernameLength} символа'
          : 'At least ${AppConfig.minUsernameLength} characters';
    } else if (id.length > AppConfig.maxUsernameLength) {
      return _ru
          ? 'Максимум ${AppConfig.maxUsernameLength} символов'
          : 'At most ${AppConfig.maxUsernameLength} characters';
    }

    if (password.length < AppConfig.minPasswordLength) {
      return _ru
          ? 'Пароль от ${AppConfig.minPasswordLength} символов'
          : 'At least ${AppConfig.minPasswordLength} characters';
    }
    return null;
  }

  Future<void> _submit() async {
    if (widget.auth.busy) return;

    final String? problem = _validate();
    if (problem != null) {
      setState(() => _localError = problem);
      return;
    }

    setState(() => _localError = null);
    widget.auth.clearError();

    try {
      await widget.auth.login(
        identifier: _identifier.text.trim(),
        password: _password.text,
      );
    } on ApiException catch (e) {
      if (mounted) setState(() => _localError = _messageFor(e));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _localError = _ru
            ? 'Не удалось войти. Повторите попытку.'
            : 'Sign-in failed. Please try again.';
      });
    }
  }

  /// Same mapping as before: a user never sees a status code.
  String _messageFor(ApiException e) {
    if (e.isNetwork) {
      return _ru
          ? 'Нет связи с сервером. Проверьте интернет.'
          : 'No connection to the server. Check your internet.';
    }
    if (e.isRateLimited) {
      final int? after = e.retryAfterSec;
      if (after != null) {
        return _ru
            ? 'Слишком много попыток. Повторите через $after с.'
            : 'Too many attempts. Try again in ${after}s.';
      }
      return _ru ? 'Слишком много попыток.' : 'Too many attempts.';
    }
    if (e.isUnauthorized) {
      return _ru ? 'Неверный логин или пароль.' : 'Wrong username or password.';
    }
    return e.message;
  }

  Future<void> _openSite() async {
    try {
      await launchUrl(Uri.parse(_siteUrl), mode: LaunchMode.externalApplication);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _localError =
            _ru ? 'Не удалось открыть браузер.' : 'Could not open the browser.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: GlukColors.pageBg,
      child: Column(
        children: <Widget>[
          const WindowTitleBar(showMaximize: false),
          Expanded(
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                // Below this width the brand panel would squeeze the form, so
                // the form takes the whole window instead.
                final bool wide = constraints.maxWidth >= 860;
                if (!wide) return _form();

                return Row(
                  children: <Widget>[
                    Expanded(flex: 55, child: _form()),
                    Expanded(flex: 45, child: _brandPanel()),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Left column
  // -------------------------------------------------------------------------

  Widget _form() {
    final DesktopStrings s = widget.strings;

    return AnimatedBuilder(
      animation: widget.auth,
      builder: (BuildContext context, Widget? _) {
        final bool busy = widget.auth.busy;
        final String? error = _localError ?? widget.auth.error;

        return Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 372),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      const GlukLogo(size: 40, radius: 12),
                      const SizedBox(width: 12),
                      Text(
                        'GlukVPN',
                        style: TextStyle(
                          color: GlukColors.text0,
                          fontSize: 19,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.2,
                          fontFamilyFallback: DesktopTokens.fontFallback,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 26),
                  Text(
                    s.signIn,
                    style: TextStyle(
                      color: GlukColors.text0,
                      fontSize: 26,
                      fontWeight: FontWeight.w700,
                      height: 1.15,
                      fontFamilyFallback: DesktopTokens.fontFallback,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    s.loginHint,
                    style: TextStyle(
                      color: GlukColors.text1,
                      fontSize: 13.5,
                      height: 1.35,
                      fontFamilyFallback: DesktopTokens.fontFallback,
                    ),
                  ),
                  const SizedBox(height: 22),

                  // Website first, exactly like the extension: the shortest
                  // path for an account that already has a browser session.
                  _OutlineButton(
                    icon: Icons.language_rounded,
                    label: _ru ? 'Войти через сайт' : 'Continue on the website',
                    onTap: busy ? null : _openSite,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _ru
                        ? 'Откроется vpn.gluk.tech. Логин и пароль оттуда работают и здесь.'
                        : 'Opens vpn.gluk.tech. The same credentials work here.',
                    style: TextStyle(
                      color: GlukColors.text2,
                      fontSize: 11.5,
                      height: 1.3,
                      fontFamilyFallback: DesktopTokens.fontFallback,
                    ),
                  ),

                  const SizedBox(height: 18),
                  _OrDivider(
                    label: _ru ? 'или по логину' : 'or with your account',
                  ),
                  const SizedBox(height: 18),

                  _Field(
                    controller: _identifier,
                    focusNode: _identifierFocus,
                    label: s.identifier,
                    icon: Icons.person_outline_rounded,
                    enabled: !busy,
                    onSubmitted: (_) => _passwordFocus.requestFocus(),
                  ),
                  const SizedBox(height: 12),
                  _Field(
                    controller: _password,
                    focusNode: _passwordFocus,
                    label: s.password,
                    icon: Icons.lock_outline_rounded,
                    obscure: _obscure,
                    enabled: !busy,
                    onSubmitted: (_) => _submit(),
                    trailing: IconButton(
                      onPressed: () => setState(() => _obscure = !_obscure),
                      icon: Icon(
                        _obscure
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                        size: 18,
                        color: GlukColors.text2,
                      ),
                      splashRadius: 18,
                      tooltip: _obscure
                          ? (_ru ? 'Показать' : 'Show')
                          : (_ru ? 'Скрыть' : 'Hide'),
                    ),
                  ),

                  if (error != null) ...<Widget>[
                    const SizedBox(height: 14),
                    InlineNotice(message: error),
                  ],

                  const SizedBox(height: 18),
                  PrimaryPillButton(
                    label: busy ? s.signingIn : s.signIn,
                    busy: busy,
                    onPressed: busy ? null : _submit,
                  ),

                  const SizedBox(height: 20),
                  _OrDivider(
                    label: _ru ? 'или продолжить с' : 'or continue with',
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: _SocialButton(
                          mark: const TelegramMark(size: 18),
                          label: 'Telegram',
                          enabled: AppConfig.telegramSignInEnabled && !busy,
                          soonLabel: _ru ? 'скоро' : 'soon',
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _SocialButton(
                          mark: const GoogleMark(size: 18),
                          label: 'Google',
                          enabled: AppConfig.googleSignInEnabled && !busy,
                          soonLabel: _ru ? 'скоро' : 'soon',
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 22),
                  Text(
                    _ru
                        ? 'Один аккаунт: Windows, Android и расширение для браузера.'
                        : 'One account: Windows, Android and the browser extension.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: GlukColors.text2,
                      fontSize: 11.5,
                      height: 1.35,
                      fontFamilyFallback: DesktopTokens.fontFallback,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  // -------------------------------------------------------------------------
  // Right column
  // -------------------------------------------------------------------------

  Widget _brandPanel() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 0, 14, 14),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(DesktopTokens.cardRadius),
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: <Color>[
              Color(0xFF3A1D8A),
              Color(0xFF6D28D9),
              Color(0xFF4C1D95),
            ],
            stops: <double>[0, 0.55, 1],
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(DesktopTokens.cardRadius),
          child: Stack(
            children: <Widget>[
              // The planet. Same painter as the home screen, so the login
              // screen and the map card cannot drift apart visually.
              Positioned.fill(
                child: AnimatedBuilder(
                  animation: _spin,
                  builder: (BuildContext context, Widget? _) {
                    return Opacity(
                      opacity: 0.9,
                      child: DottedWorld(
                        globeness: 1,
                        rotationDegrees: _spin.value * 360,
                        centreLatitude: 14,
                        globeAnchor: const Offset(0.5, 0.58),
                        zoom: 1.02,
                        dotOpacity: 0.72,
                        orbitalPhase: _spin.value,
                        pulse: _spin.value,
                        connected: true,
                      ),
                    );
                  },
                ),
              ),

              // Readability wash under the headline.
              const Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: <Color>[
                        Color(0x66120829),
                        Color(0x00000000),
                        Color(0x77100724),
                      ],
                      stops: <double>[0, 0.45, 1],
                    ),
                  ),
                ),
              ),

              Padding(
                padding: const EdgeInsets.fromLTRB(30, 34, 30, 30),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      _ru
                          ? 'Своя сеть,\nсвои правила'
                          : 'Your network,\nyour rules',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 27,
                        height: 1.15,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.2,
                        fontFamilyFallback: DesktopTokens.fontFallback,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      _ru
                          ? 'WireGuard, свои узлы и системный туннель Windows — без прокси в браузере.'
                          : 'WireGuard, our own nodes and a real Windows tunnel - not a browser proxy.',
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.78),
                        fontSize: 13,
                        height: 1.4,
                        fontFamilyFallback: DesktopTokens.fontFallback,
                      ),
                    ),
                    const Spacer(),
                    _PanelPoint(
                      icon: Icons.devices_rounded,
                      text: _ru
                          ? 'Телефон, компьютер и браузер в одном аккаунте'
                          : 'Phone, desktop and browser in one account',
                    ),
                    const SizedBox(height: 10),
                    _PanelPoint(
                      icon: Icons.speed_rounded,
                      text: _ru
                          ? 'Автовыбор узла по пингу и загрузке'
                          : 'Automatic node choice by ping and load',
                    ),
                    const SizedBox(height: 10),
                    _PanelPoint(
                      icon: Icons.shield_moon_rounded,
                      text: _ru
                          ? 'Kill switch и раздельное туннелирование'
                          : 'Kill switch and split tunnelling',
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Pieces
// ---------------------------------------------------------------------------

class _Field extends StatelessWidget {
  const _Field({
    required this.controller,
    required this.label,
    required this.icon,
    this.focusNode,
    this.obscure = false,
    this.enabled = true,
    this.trailing,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final String label;
  final IconData icon;
  final FocusNode? focusNode;
  final bool obscure;
  final bool enabled;
  final Widget? trailing;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      focusNode: focusNode,
      obscureText: obscure,
      enabled: enabled,
      onSubmitted: onSubmitted,
      style: TextStyle(
        color: GlukColors.text0,
        fontSize: 14,
        fontFamilyFallback: DesktopTokens.fontFallback,
      ),
      cursorColor: GlukColors.violetLight,
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(
          color: GlukColors.text1,
          fontSize: 13,
          fontFamilyFallback: DesktopTokens.fontFallback,
        ),
        floatingLabelStyle: TextStyle(
          color: GlukColors.violetLight,
          fontSize: 12.5,
          fontFamilyFallback: DesktopTokens.fontFallback,
        ),
        prefixIcon: Icon(icon, size: 18, color: GlukColors.text2),
        suffixIcon: trailing,
        filled: true,
        fillColor: const Color(0xFF120E1E),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: Color(0x14FFFFFF)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: Color(0x14FFFFFF)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: GlukColors.violet.withOpacity(0.75)),
        ),
      ),
    );
  }
}

class _OrDivider extends StatelessWidget {
  const _OrDivider({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final Widget line = Expanded(
      child: Container(height: 1, color: const Color(0x14FFFFFF)),
    );
    return Row(
      children: <Widget>[
        line,
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            label,
            style: TextStyle(
              color: GlukColors.text2,
              fontSize: 11.5,
              fontFamilyFallback: DesktopTokens.fontFallback,
            ),
          ),
        ),
        line,
      ],
    );
  }
}

/// Secondary action with a hairline outline, used for the website path.
class _OutlineButton extends StatelessWidget {
  const _OutlineButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF15112271).withOpacity(0.0),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          height: 46,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            color: const Color(0xFF141020),
            border: Border.all(color: const Color(0x1FFFFFFF)),
          ),
          alignment: Alignment.center,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Icon(icon, size: 17, color: GlukColors.violetLight),
              const SizedBox(width: 9),
              Text(
                label,
                style: TextStyle(
                  color: GlukColors.text0,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  fontFamilyFallback: DesktopTokens.fontFallback,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Telegram / Google, kept visible but disabled until the backend supports
/// them, so the layout matches the final design instead of jumping later.
class _SocialButton extends StatelessWidget {
  const _SocialButton({
    required this.mark,
    required this.label,
    required this.enabled,
    required this.soonLabel,
  });

  final Widget mark;
  final String label;
  final bool enabled;
  final String soonLabel;

  @override
  Widget build(BuildContext context) {
    final Widget body = Container(
      height: 44,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: const Color(0xFF120E1E),
        border: Border.all(color: const Color(0x14FFFFFF)),
      ),
      alignment: Alignment.center,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Opacity(opacity: enabled ? 1 : 0.45, child: mark),
          const SizedBox(width: 8),
          Text(
            label,
            style: TextStyle(
              color: enabled ? GlukColors.text0 : GlukColors.text2,
              fontSize: 13,
              fontWeight: FontWeight.w600,
              fontFamilyFallback: DesktopTokens.fontFallback,
            ),
          ),
        ],
      ),
    );

    if (enabled) return body;
    return Tooltip(message: soonLabel, child: body);
  }
}

class _PanelPoint extends StatelessWidget {
  const _PanelPoint({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Container(
          width: 26,
          height: 26,
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.14),
            borderRadius: BorderRadius.circular(9),
          ),
          alignment: Alignment.center,
          child: Icon(icon, size: 15, color: Colors.white),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              text,
              style: TextStyle(
                color: Colors.white.withOpacity(0.9),
                fontSize: 12.5,
                height: 1.3,
                fontFamilyFallback: DesktopTokens.fontFallback,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
