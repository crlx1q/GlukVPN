import 'package:flutter/material.dart';

import '../../services/api_client.dart';
import '../../state/auth_controller.dart';
import '../../theme/tokens.dart';
import '../../widgets/common.dart';
import '../../widgets/glass.dart';
import '../../widgets/logo.dart';
import '../i18n/desktop_strings.dart';
import '../widgets/window_title_bar.dart';

/// Desktop sign-in.
///
/// Requirement 4: exactly the same account system as mobile — username OR
/// email plus password. There is no separate desktop account and no place to
/// type an API URL.
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

class _DesktopLoginScreenState extends State<DesktopLoginScreen> {
  final TextEditingController _identifier = TextEditingController();
  final TextEditingController _password = TextEditingController();
  final FocusNode _identifierFocus = FocusNode();
  final FocusNode _passwordFocus = FocusNode();

  bool _busy = false;
  bool _obscure = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _identifierFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _identifier.dispose();
    _password.dispose();
    _identifierFocus.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;

    final identifier = _identifier.text.trim();
    final password = _password.text;

    if (identifier.isEmpty || password.isEmpty) {
      setState(() => _error = widget.strings.loginHint);
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      await widget.auth.login(identifier: identifier, password: password);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = _messageFor(e));
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _messageFor(ApiException e) {
    if (e.isNetwork) {
      return widget.strings.isRussian
          ? 'Нет связи с сервером. Проверьте интернет.'
          : 'Cannot reach the server. Check your internet connection.';
    }
    if (e.isRateLimited) {
      final wait = e.retryAfterSec;
      if (widget.strings.isRussian) {
        return wait == null
            ? 'Слишком много попыток. Попробуйте позже.'
            : 'Слишком много попыток. Повторите через $wait с.';
      }
      return wait == null
          ? 'Too many attempts. Please try again later.'
          : 'Too many attempts. Try again in $wait s.';
    }
    if (e.isUnauthorized) {
      return widget.strings.isRussian
          ? 'Неверный логин или пароль.'
          : 'Wrong username or password.';
    }
    return e.message;
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.strings;

    return ColoredBox(
      color: GlukColors.pageBg,
      child: Column(
        children: <Widget>[
          const WindowTitleBar(showMaximize: false),
          Expanded(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 32,
                ),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 380),
                  child: GlassPanel(
                    radius: 22,
                    padding: const EdgeInsets.all(28),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        const Center(child: GlukLogo(size: 56, radius: 16)),
                        const SizedBox(height: 18),
                        Center(
                          child: Text(
                            s.signIn,
                            style: const TextStyle(
                              color: GlukColors.text0,
                              fontSize: 19,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Center(
                          child: Text(
                            s.loginHint,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: GlukColors.text2,
                              fontSize: 12,
                            ),
                          ),
                        ),
                        const SizedBox(height: 24),
                        _Field(
                          controller: _identifier,
                          focusNode: _identifierFocus,
                          label: s.identifier,
                          icon: Icons.person_outline_rounded,
                          enabled: !_busy,
                          onSubmitted: (_) => _passwordFocus.requestFocus(),
                        ),
                        const SizedBox(height: 12),
                        _Field(
                          controller: _password,
                          focusNode: _passwordFocus,
                          label: s.password,
                          icon: Icons.lock_outline_rounded,
                          enabled: !_busy,
                          obscure: _obscure,
                          onSubmitted: (_) => _submit(),
                          trailing: IconButton(
                            splashRadius: 18,
                            icon: Icon(
                              _obscure
                                  ? Icons.visibility_outlined
                                  : Icons.visibility_off_outlined,
                              size: 17,
                              color: GlukColors.text2,
                            ),
                            onPressed: () =>
                                setState(() => _obscure = !_obscure),
                          ),
                        ),
                        if (_error != null) ...<Widget>[
                          const SizedBox(height: 14),
                          InlineNotice(
                            message: _error!,
                            tone: NoticeTone.danger,
                          ),
                        ],
                        const SizedBox(height: 22),
                        PrimaryPillButton(
                          label: _busy ? s.signingIn : s.signIn,
                          busy: _busy,
                          onPressed: _busy ? null : _submit,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

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
      style: const TextStyle(color: GlukColors.text0, fontSize: 14),
      cursorColor: GlukColors.violetLight,
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: GlukColors.text2, fontSize: 13),
        prefixIcon: Icon(icon, size: 18, color: GlukColors.text2),
        suffixIcon: trailing,
        filled: true,
        fillColor: Colors.white.withOpacity(0.04),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: GlukColors.stroke),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: GlukColors.stroke),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: GlukColors.violet, width: 1.4),
        ),
      ),
    );
  }
}
