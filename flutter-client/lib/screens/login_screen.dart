import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../config.dart';
import '../models/models.dart';
import '../state/auth_controller.dart';
import '../state/channel_controller.dart';
import '../theme/tokens.dart';
import '../widgets/glass.dart';
import '../widgets/logo.dart';
import '../widgets/social_icons.dart';

/// Sign-in, rendered on top of the onboarding backdrop (see
/// `onboarding_screen.dart`) so the planet stays behind the card instead of the
/// screen jumping to a flat form.
///
/// One field for both identities: the control plane accepts a username or an
/// email address on `POST /api/auth/login`, so the form does not ask the user
/// to know which one they signed up with.
///
/// Self-service registration is deliberately absent while verification is not
/// in place; the screen simply does not advertise it.
class LoginView extends StatefulWidget {
  const LoginView({super.key, this.onBack});

  final VoidCallback? onBack;

  @override
  State<LoginView> createState() => _LoginViewState();
}

class _LoginViewState extends State<LoginView> {
  final TextEditingController _identifier = TextEditingController();
  final TextEditingController _password = TextEditingController();
  final GlobalKey<FormState> _form = GlobalKey<FormState>();
  bool _obscure = true;

  @override
  void dispose() {
    _identifier.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final AuthController auth = context.read<AuthController>();
    if (auth.busy) return;
    if (!(_form.currentState?.validate() ?? false)) return;
    FocusScope.of(context).unfocus();
    await auth.login(
      identifier: _identifier.text.trim(),
      password: _password.text,
    );
  }

  /// Accepts either identity. An address is recognised by the `@`, everything
  /// else is treated as a username - the server does the authoritative lookup.
  String? _validateIdentifier(String? value) {
    final String text = (value ?? '').trim();
    if (text.isEmpty) return 'Enter your username or email';
    if (text.contains('@')) {
      final int at = text.indexOf('@');
      final bool looksLikeEmail = at > 0 &&
          text.length > at + 3 &&
          text.indexOf('.', at) > at + 1 &&
          !text.contains(' ');
      return looksLikeEmail ? null : 'Enter a valid email address';
    }
    if (text.length < AppConfig.minUsernameLength) {
      return 'At least ${AppConfig.minUsernameLength} characters';
    }
    if (text.length > AppConfig.maxUsernameLength) {
      return 'At most ${AppConfig.maxUsernameLength} characters';
    }
    return null;
  }

  String? _validatePassword(String? value) {
    final String text = value ?? '';
    if (text.isEmpty) return 'Enter your password';
    if (text.length < AppConfig.minPasswordLength) {
      return 'At least ${AppConfig.minPasswordLength} characters';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final AuthController auth = context.watch<AuthController>();

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 28),
      child: Form(
        key: _form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (widget.onBack != null)
              CircleIconButton(
                icon: Icons.arrow_back_rounded,
                onTap: widget.onBack!,
                tooltip: 'Back',
              ),
            const SizedBox(height: 26),
            const GlukLogo(size: 56),
            const SizedBox(height: 18),
            Text('Welcome back', style: text.headlineMedium),
            const SizedBox(height: 6),
            Text(
              'Sign in to pick a country and connect.',
              style: text.bodyMedium,
            ),
            const SizedBox(height: 24),
            TextFormField(
              controller: _identifier,
              autocorrect: false,
              enableSuggestions: false,
              keyboardType: TextInputType.emailAddress,
              textInputAction: TextInputAction.next,
              style: text.bodyLarge,
              decoration: const InputDecoration(
                labelText: 'Username or email',
                prefixIcon: Icon(Icons.person_outline_rounded),
              ),
              validator: _validateIdentifier,
              onChanged: (_) => auth.clearError(),
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _password,
              obscureText: _obscure,
              autocorrect: false,
              enableSuggestions: false,
              textInputAction: TextInputAction.done,
              style: text.bodyLarge,
              decoration: InputDecoration(
                labelText: 'Password',
                prefixIcon: const Icon(Icons.lock_outline_rounded),
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscure
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                  ),
                  onPressed: () => setState(() => _obscure = !_obscure),
                  tooltip: _obscure ? 'Show password' : 'Hide password',
                ),
              ),
              validator: _validatePassword,
              onFieldSubmitted: (_) => _submit(),
              onChanged: (_) => auth.clearError(),
            ),
            if (auth.error != null) ...<Widget>[
              const SizedBox(height: 16),
              InlineNotice(message: auth.error!),
            ],
            const SizedBox(height: 22),
            PrimaryPillButton(
              label: 'Sign In',
              busy: auth.busy,
              onPressed: auth.busy ? null : _submit,
            ),
            const SizedBox(height: 22),
            const _OrDivider(),
            const SizedBox(height: 16),
            Row(
              children: <Widget>[
                Expanded(
                  child: _SocialButton(
                    mark: const TelegramMark(size: 20),
                    label: 'Telegram',
                    enabled: AppConfig.telegramSignInEnabled,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _SocialButton(
                    mark: const GoogleMark(size: 20),
                    label: 'Google',
                    enabled: AppConfig.googleSignInEnabled,
                  ),
                ),
              ],
            ),
            // The channel indicator only exists in builds that are allowed to
            // switch control planes (the internal APK). A release build points
            // at one API and says nothing about it.
            if (AppConfig.betaChannelAvailable) ...<Widget>[
              const SizedBox(height: 18),
              const Center(child: _ChannelChip()),
            ],
          ],
        ),
      ),
    );
  }
}

/// Kept as a standalone screen for deep links and for tests that pump the
/// sign-in form on its own.
class LoginScreen extends StatelessWidget {
  const LoginScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: GlukColors.pageBg,
      body: SafeArea(child: LoginView()),
    );
  }
}

class _OrDivider extends StatelessWidget {
  const _OrDivider();

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return Row(
      children: <Widget>[
        const Expanded(child: Divider()),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text('or continue with', style: text.bodySmall),
        ),
        const Expanded(child: Divider()),
      ],
    );
  }
}

/// A provider button carrying the official mark. Disabled rather than hidden
/// so the screen does not reflow when the provider is switched on.
class _SocialButton extends StatelessWidget {
  const _SocialButton({
    required this.mark,
    required this.label,
    required this.enabled,
  });

  final Widget mark;
  final String label;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return Tooltip(
      message: label,
      child: Opacity(
        opacity: enabled ? 1 : 0.45,
        child: GlassPanel(
          radius: 999,
          padding: const EdgeInsets.symmetric(vertical: 13),
          onTap: enabled ? () {} : null,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              mark,
              const SizedBox(width: 8),
              Text(
                label,
                style: text.titleMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Which control plane this build is pointed at, and its version. Visible
/// before sign-in on purpose: on BETA you are looking at a different database
/// with different accounts, and that should never be a surprise.
class _ChannelChip extends StatelessWidget {
  const _ChannelChip();

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ChannelController channel = context.watch<ChannelController>();
    final ChannelVersion? version = channel.versionOf(channel.active);
    final Color tone =
        channel.active.isBeta ? GlukColors.amber : GlukColors.violetLight;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: tone.withOpacity(0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: tone.withOpacity(0.32)),
      ),
      child: Text(
        version?.label ?? '${channel.active.label} \u00b7 offline',
        style: text.labelSmall?.copyWith(color: tone),
      ),
    );
  }
}
