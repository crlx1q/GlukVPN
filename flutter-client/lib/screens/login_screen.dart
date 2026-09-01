import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../config.dart';
import '../state/auth_controller.dart';
import '../theme/tokens.dart';
import '../widgets/glass.dart';
import '../widgets/logo.dart';
import '../widgets/social_icons.dart';
import 'register_screen.dart';

/// Sign-in, rendered on top of the onboarding backdrop (see
/// `onboarding_screen.dart`) so the planet stays behind the card instead of the
/// screen jumping to a flat form.
///
/// One field for both identities: the control plane accepts a username or an
/// email address on `POST /api/auth/login`, so the form does not ask the user
/// to know which one they signed up with.
///
/// ROUND 10 (4.1): sign-up and password recovery now live in the app. They
/// used to be a sentence pointing at the website, which is the same as not
/// having them at all. The three-step flow (email, code, Telegram) is in
/// `register_screen.dart` and talks to the production control plane whatever
/// channel this build is on - beta has no accounts to create.
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
      // The layout is final on the first frame - onboarding fades this in over
      // the map instead of centring it and then lifting it into place. The only
      // thing that moves is the keyboard inset, which is added to the bottom so
      // the password field is never left under the keyboard.
      padding: EdgeInsets.fromLTRB(
        24,
        16,
        24,
        28 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
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
            const SizedBox(height: 12),
            Center(
              child: Wrap(
                alignment: WrapAlignment.center,
                children: <Widget>[
                  if (AppConfig.selfRegistrationEnabled)
                    TextButton(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (BuildContext context) =>
                              const RegisterScreen(),
                        ),
                      ),
                      child: const Text('Create an account'),
                    ),
                  TextButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (BuildContext context) =>
                            const RecoverScreen(),
                      ),
                    ),
                    child: const Text('Forgot your password?'),
                  ),
                ],
              ),
            ),
            // Nothing about channels, builds or deployments appears here. Sign
            // in is a product screen; the PROD/BETA switch and the version
            // readouts live in Settings, behind an internal-build flag.
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
