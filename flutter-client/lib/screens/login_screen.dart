import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../config.dart';
import '../i18n/app_strings.dart';
import '../models/models.dart';
import '../services/link_opener.dart';
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
/// ROUND 11: **the Telegram button works now.** It used to be rendered with
/// `onTap: () {}` behind a disabled flag, which is a screenshot of a feature.
/// It runs the device-authorization grant that the desktop client and the
/// extension already share: the app asks for a request, opens the bot, and the
/// bot asks the user to allow or refuse it. Approving requires the Telegram
/// account that was linked at sign-up, so the code travelling in the deep link
/// authorises nothing by itself.
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

  /// True while the link flow is polling. Kept separate from `auth.busy` so the
  /// password button and the Telegram button cannot both claim the spinner.
  bool _linking = false;
  bool _linkCancelled = false;

  @override
  void dispose() {
    _identifier.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final AuthController auth = context.read<AuthController>();
    if (auth.busy || _linking) return;
    if (!(_form.currentState?.validate() ?? false)) return;
    FocusScope.of(context).unfocus();
    await auth.login(
      identifier: _identifier.text.trim(),
      password: _password.text,
    );
  }

  /// ROUND 11: sign in through the Telegram bot.
  ///
  /// The sheet is not decoration - it is the only place the user can see the
  /// code that the bot is about to show them, which is what lets them notice
  /// they are confirming somebody else's request. It also owns cancellation:
  /// closing it stops the poll instead of leaving it running for the link's
  /// full five minutes.
  Future<void> _signInWithTelegram() async {
    if (_linking) return;
    final AuthController auth = context.read<AuthController>();
    if (auth.busy) return;

    FocusScope.of(context).unfocus();
    setState(() {
      _linking = true;
      _linkCancelled = false;
    });

    LinkAuthStart? started;
    final NavigatorState navigator = Navigator.of(context);

    final Future<LinkSignInOutcome> flow = auth.signInWithLink(
      client: 'android',
      isCancelled: () => _linkCancelled,
      onStarted: (LinkAuthStart start) {
        started = start;
        if (!mounted) return;
        // Open the bot first, then show the sheet: the user is looking at
        // Telegram within a second, and the sheet is what they come back to.
        LinkOpener.openOrCopy(
          context,
          start.confirmUrl,
          failureMessage: context.strings.telegramCannotOpen,
        );
        showModalBottomSheet<void>(
          context: context,
          backgroundColor: Colors.transparent,
          isDismissible: true,
          builder: (BuildContext sheetContext) => _TelegramSheet(
            start: start,
            onOpenAgain: () => LinkOpener.openOrCopy(
              sheetContext,
              start.confirmUrl,
              failureMessage: sheetContext.strings.telegramCannotOpen,
            ),
          ),
        ).then((_) {
          // Dismissed by hand: stop polling. The request expires server-side
          // on its own, so there is nothing to clean up.
          if (mounted && _linking) _linkCancelled = true;
        });
      },
    );

    final LinkSignInOutcome outcome = await flow;
    if (!mounted) return;

    // Close the sheet if it is still up. On success AuthGate swaps the whole
    // screen out anyway, but a sheet left behind over the home screen would be
    // a very confusing way to arrive there.
    if (started != null && navigator.canPop()) navigator.pop();
    setState(() => _linking = false);

    if (outcome == LinkSignInOutcome.signedIn ||
        outcome == LinkSignInOutcome.cancelled) {
      return;
    }
    // Everything else already left a message on the controller, which the form
    // renders through InlineNotice.
  }

  /// Accepts either identity. An address is recognised by the `@`, everything
  /// else is treated as a username - the server does the authoritative lookup.
  String? _validateIdentifier(String? value) {
    final AppStrings s = context.strings;
    final String text = (value ?? '').trim();
    if (text.isEmpty) return s.enterUsernameOrEmail;
    if (text.contains('@')) {
      final int at = text.indexOf('@');
      final bool looksLikeEmail = at > 0 &&
          text.length > at + 3 &&
          text.indexOf('.', at) > at + 1 &&
          !text.contains(' ');
      return looksLikeEmail ? null : s.enterValidEmail;
    }
    if (text.length < AppConfig.minUsernameLength) {
      return s.atLeastChars(AppConfig.minUsernameLength);
    }
    if (text.length > AppConfig.maxUsernameLength) {
      return s.atMostChars(AppConfig.maxUsernameLength);
    }
    return null;
  }

  String? _validatePassword(String? value) {
    final AppStrings s = context.strings;
    final String text = value ?? '';
    if (text.isEmpty) return s.enterPassword;
    if (text.length < AppConfig.minPasswordLength) {
      return s.atLeastChars(AppConfig.minPasswordLength);
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final AppStrings s = context.strings;
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
                tooltip: s.back,
              ),
            const SizedBox(height: 26),
            const GlukLogo(size: 56),
            const SizedBox(height: 18),
            Text(s.welcomeBack, style: text.headlineMedium),
            const SizedBox(height: 6),
            Text(s.signInSubtitle, style: text.bodyMedium),
            const SizedBox(height: 24),
            TextFormField(
              controller: _identifier,
              autocorrect: false,
              enableSuggestions: false,
              keyboardType: TextInputType.emailAddress,
              textInputAction: TextInputAction.next,
              style: text.bodyLarge,
              decoration: InputDecoration(
                labelText: s.usernameOrEmail,
                prefixIcon: const Icon(Icons.person_outline_rounded),
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
                labelText: s.password,
                prefixIcon: const Icon(Icons.lock_outline_rounded),
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscure
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                  ),
                  onPressed: () => setState(() => _obscure = !_obscure),
                  tooltip: _obscure ? s.showPassword : s.hidePassword,
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
              label: s.signIn,
              busy: auth.busy && !_linking,
              onPressed: (auth.busy || _linking) ? null : _submit,
            ),
            const SizedBox(height: 22),
            _OrDivider(label: s.orContinueWith),
            const SizedBox(height: 16),
            Row(
              children: <Widget>[
                Expanded(
                  child: _SocialButton(
                    mark: const TelegramMark(size: 20),
                    label: s.telegram,
                    enabled: AppConfig.telegramSignInEnabled && !auth.busy,
                    busy: _linking,
                    onTap: _signInWithTelegram,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _SocialButton(
                    mark: const GoogleMark(size: 20),
                    label: s.google,
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
                      child: Text(s.createAccount),
                    ),
                  TextButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (BuildContext context) =>
                            const RecoverScreen(),
                      ),
                    ),
                    child: Text(s.forgotPassword),
                  ),
                ],
              ),
            ),
            // Nothing about channels, builds or deployments appears here. Sign
            // in is a product screen; the PROD/BETA switch and the version
            // readouts live in Settings, behind an admin-only check.
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

/// What the user sees while the bot has the question.
///
/// The code is the point of this sheet. Telegram will show the same eight
/// characters, and a request whose code does not match is somebody else's -
/// which is the only way a person can catch a confirmation they did not start.
class _TelegramSheet extends StatelessWidget {
  const _TelegramSheet({required this.start, required this.onOpenAgain});

  final LinkAuthStart start;
  final VoidCallback onOpenAgain;

  @override
  Widget build(BuildContext context) {
    final AppStrings s = context.strings;
    final TextTheme text = Theme.of(context).textTheme;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        child: GlassPanel(
          radius: GlukSizes.trafficRadius,
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  const TelegramMark(size: 22),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(s.telegramSignInTitle, style: text.titleLarge),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(s.telegramSignInBody, style: text.bodyMedium),
              if (start.userCode.isNotEmpty) ...<Widget>[
                const SizedBox(height: 16),
                Text(s.confirmationCode.toUpperCase(),
                    style: text.labelMedium),
                const SizedBox(height: 4),
                Text(
                  start.userCode,
                  style: text.headlineSmall?.copyWith(
                    color: GlukColors.violetLight,
                    letterSpacing: 2,
                  ),
                ),
              ],
              const SizedBox(height: 18),
              Row(
                children: <Widget>[
                  const SizedBox(
                    width: 15,
                    height: 15,
                    child: CircularProgressIndicator(strokeWidth: 1.8),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(s.telegramWaiting, style: text.bodySmall),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              PrimaryPillButton(
                label: s.telegramOpenBot,
                icon: Icons.open_in_new_rounded,
                onPressed: onOpenAgain,
              ),
              const SizedBox(height: 6),
              Center(
                child: TextButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  child: Text(s.cancel),
                ),
              ),
            ],
          ),
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
    final TextTheme text = Theme.of(context).textTheme;
    return Row(
      children: <Widget>[
        const Expanded(child: Divider()),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(label, style: text.bodySmall),
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
    this.busy = false,
    this.onTap,
  });

  final Widget mark;
  final String label;
  final bool enabled;
  final bool busy;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final bool live = enabled && onTap != null && !busy;
    return Tooltip(
      message: label,
      child: Opacity(
        opacity: enabled ? 1 : 0.45,
        child: GlassPanel(
          radius: 999,
          padding: const EdgeInsets.symmetric(vertical: 13),
          onTap: live ? onTap : null,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              if (busy)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
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
