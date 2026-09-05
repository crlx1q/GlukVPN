import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../config.dart';
import '../i18n/app_strings.dart';
import '../services/api_client.dart';
import '../services/link_opener.dart';
import '../services/register_api.dart';
import '../theme/tokens.dart';
import '../widgets/glass.dart';
import '../widgets/logo.dart';
import '../widgets/page_background.dart';

/// Sign-up on the phone, in the same three steps the website uses.
///
///   1. email + password
///   2. the six-digit code from the email
///   3. the Telegram bot, where a shared contact finishes the account
///
/// The order is not decoration. A code proves the address exists, and addresses
/// are free and infinite. A phone number handed over through Telegram's own
/// "share contact" button is not.
///
/// ROUND 11, two corrections to how round 10 shipped this:
///
///  * **It looked like a different app.** Sign-in renders over the wave
///    backdrop with a 56 px mark; this screen used a flat `pageBg` Scaffold and
///    a 48 px one. Same widgets, different room. Both now use [_AuthShell],
///    which *is* the sign-in layout, so the two cannot drift apart again.
///  * **The Telegram step asked for two copy-paste operations.** It handed over
///    a link and a code and left the user to move them somewhere by hand. The
///    link now opens the bot directly, with the deep link already carrying the
///    code; copying is what happens when the launch fails, not the design.
///
/// There is still no captcha here. Turnstile has no Flutter widget, and
/// shipping a WebView for one checkbox would be worse than the problem: the
/// server treats a missing token the way it does for the desktop client, and
/// the rate limits on `/api/auth/register/*` still apply.
enum _RegStep { form, code, telegram, done, closed }

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final RegisterApi _api = RegisterApi();
  final GlobalKey<FormState> _form = GlobalKey<FormState>();

  final TextEditingController _email = TextEditingController();
  final TextEditingController _password = TextEditingController();
  final TextEditingController _password2 = TextEditingController();
  final TextEditingController _code = TextEditingController();

  _RegStep _step = _RegStep.form;
  bool _busy = false;
  bool _obscure = true;
  String? _error;
  String? _notice;
  String _closedReason = '';
  int _codeTtl = 5;
  bool _mailDelivered = true;

  TelegramHandoff? _handoff;
  String _username = '';

  Timer? _poll;
  int _polls = 0;
  bool _resendCooling = false;

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  @override
  void dispose() {
    _poll?.cancel();
    _email.dispose();
    _password.dispose();
    _password2.dispose();
    _code.dispose();
    _api.close();
    super.dispose();
  }

  Future<void> _loadConfig() async {
    final RegisterConfig config = await _api.config();
    if (!mounted) return;
    final AppStrings s = context.strings;
    setState(() {
      _codeTtl = config.codeTtlMinutes;
      if (config.open) return;
      _step = _RegStep.closed;
      // Name the reason. "Closed" without a why is what makes people email
      // support to ask whether it is them or us.
      _closedReason =
          config.selfRegistration ? s.signUpClosedTelegram : s.signUpClosed;
    });
  }

  void _fail(Object error) {
    if (!mounted) return;
    final String message = error is ApiException
        ? (error.code == 'registration_disabled'
            ? (context.strings.isRussian
                ? 'Регистрация временно отключена из-за технических работ. Попробуйте позже.'
                : 'Registration is temporarily disabled for maintenance. Please try again later.')
            : error.message)
        : context.strings.somethingWentWrong;
    setState(() {
      _error = message;
      _busy = false;
    });
  }

  // --- step 1 ---------------------------------------------------------------

  Future<void> _start() async {
    if (_busy) return;
    if (!(_form.currentState?.validate() ?? false)) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      final bool delivered = await _api.start(
        email: _email.text.trim(),
        password: _password.text,
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _mailDelivered = delivered;
        _step = _RegStep.code;
      });
    } catch (error) {
      _fail(error);
    }
  }

  // --- step 2 ---------------------------------------------------------------

  Future<void> _verify() async {
    if (_busy) return;
    final String code = _code.text.replaceAll(RegExp(r'[^0-9]'), '');
    if (code.length != 6) {
      setState(() => _error = context.strings.codeIsSixDigits);
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      final TelegramHandoff handoff = await _api.verifyEmail(
        email: _email.text.trim(),
        code: code,
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _handoff = handoff;
        _step = _RegStep.telegram;
      });
      _startPolling();
      // ROUND 11: straight into the bot. The deep link already carries the
      // code, so there is nothing left for the user to transcribe.
      await _openBot();
    } catch (error) {
      _fail(error);
    }
  }

  Future<void> _resend() async {
    if (_resendCooling) return;
    setState(() {
      _resendCooling = true;
      _error = null;
    });
    try {
      await _api.resend(_email.text.trim());
      if (!mounted) return;
      setState(() => _notice = context.strings.emailCodeSent);
    } catch (error) {
      _fail(error);
    }
    // Server-side the route is rate limited anyway; this only stops the button
    // from inviting a burst that would earn a 429.
    Timer(const Duration(seconds: 30), () {
      if (mounted) setState(() => _resendCooling = false);
    });
  }

  // --- step 3 ---------------------------------------------------------------

  Future<void> _openBot() async {
    final String url = _handoff?.url ?? '';
    if (url.isEmpty || !mounted) return;
    await LinkOpener.openOrCopy(
      context,
      url,
      failureMessage: context.strings.telegramCannotOpen,
    );
  }

  /// The bot talks to the server, not to this app, so the only thing the phone
  /// can do is ask whether it happened yet. Bounded on purpose: a screen left
  /// open overnight must not poll the API forever.
  void _startPolling() {
    _poll?.cancel();
    _polls = 0;
    _poll = Timer.periodic(const Duration(seconds: 3), (Timer timer) async {
      if (!mounted) return timer.cancel();
      if (_polls > 200) {
        timer.cancel();
        setState(() => _notice = context.strings.stoppedChecking);
        return;
      }
      _polls += 1;
      try {
        final String? username = await _api.pollStatus(_email.text.trim());
        if (username == null || !mounted) return;
        timer.cancel();
        setState(() {
          _username = username;
          _step = _RegStep.done;
        });
      } catch (_) {
        // One failed poll means nothing - the user is in Telegram, not here.
      }
    });
  }

  void _copy(String value, String said) {
    if (value.isEmpty) return;
    Clipboard.setData(ClipboardData(text: value));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(said)));
  }

  // --- validation -----------------------------------------------------------

  String? _validateEmail(String? value) {
    final AppStrings s = context.strings;
    final String text = (value ?? '').trim();
    if (text.isEmpty) return s.enterEmail;
    final int at = text.indexOf('@');
    final bool ok = at > 0 &&
        text.length > at + 3 &&
        text.indexOf('.', at) > at + 1 &&
        !text.contains(' ');
    return ok ? null : s.enterValidEmail;
  }

  String? _validatePassword(String? value) {
    final String text = value ?? '';
    if (text.length < AppConfig.minPasswordLength) {
      return context.strings.atLeastChars(AppConfig.minPasswordLength);
    }
    return null;
  }

  String? _validateRepeat(String? value) =>
      (value ?? '') == _password.text ? null : context.strings.passwordsDoNotMatch;

  @override
  Widget build(BuildContext context) {
    final AppStrings s = context.strings;
    return _AuthShell(
      title: s.createAccountTitle,
      subtitle:
          _step == _RegStep.closed ? s.signUpClosed : s.registerSubtitle,
      progress: switch (_step) {
        _RegStep.form => 1,
        _RegStep.code => 2,
        _RegStep.telegram => 3,
        _RegStep.done => 3,
        _RegStep.closed => 0,
      },
      error: _error,
      notice: _notice,
      onDismissError: () => setState(() => _error = null),
      children: switch (_step) {
        _RegStep.form => _formStep(context, s),
        _RegStep.code => _codeStep(context, s),
        _RegStep.telegram => _telegramStep(context, s),
        _RegStep.done => _doneStep(context, s),
        _RegStep.closed => _closedStep(context, s),
      },
    );
  }

  List<Widget> _formStep(BuildContext context, AppStrings s) {
    final TextTheme text = Theme.of(context).textTheme;
    return <Widget>[
      Form(
        key: _form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            TextFormField(
              controller: _email,
              autocorrect: false,
              enableSuggestions: false,
              keyboardType: TextInputType.emailAddress,
              textInputAction: TextInputAction.next,
              style: text.bodyLarge,
              decoration: InputDecoration(
                labelText: s.email,
                prefixIcon: const Icon(Icons.alternate_email_rounded),
              ),
              validator: _validateEmail,
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _password,
              obscureText: _obscure,
              autocorrect: false,
              enableSuggestions: false,
              textInputAction: TextInputAction.next,
              style: text.bodyLarge,
              decoration: InputDecoration(
                labelText: s.password,
                prefixIcon: const Icon(Icons.lock_outline_rounded),
                suffixIcon: IconButton(
                  icon: Icon(_obscure
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined),
                  tooltip: _obscure ? s.showPassword : s.hidePassword,
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
              validator: _validatePassword,
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _password2,
              obscureText: _obscure,
              autocorrect: false,
              enableSuggestions: false,
              textInputAction: TextInputAction.done,
              style: text.bodyLarge,
              decoration: InputDecoration(
                labelText: s.repeatPassword,
                prefixIcon: const Icon(Icons.lock_reset_rounded),
              ),
              validator: _validateRepeat,
              onFieldSubmitted: (_) => _start(),
            ),
          ],
        ),
      ),
      const SizedBox(height: 22),
      PrimaryPillButton(
        label: s.continueLabel,
        busy: _busy,
        onPressed: _busy ? null : _start,
      ),
      const SizedBox(height: 14),
      _Hint(s.termsNotice),
      const SizedBox(height: 6),
      _Hint(s.registrationAlwaysProd),
    ];
  }

  List<Widget> _codeStep(BuildContext context, AppStrings s) {
    final TextTheme text = Theme.of(context).textTheme;
    return <Widget>[
      Text(s.weSentACodeTo, style: text.bodyMedium),
      const SizedBox(height: 2),
      Text(_email.text.trim(), style: text.titleMedium),
      const SizedBox(height: 4),
      Text(s.codeValidFor(_codeTtl), style: text.bodySmall),
      if (!_mailDelivered) ...<Widget>[
        const SizedBox(height: 12),
        InlineNotice(message: s.mailNotDelivered, tone: GlukColors.amber),
      ],
      const SizedBox(height: 18),
      TextFormField(
        controller: _code,
        keyboardType: TextInputType.number,
        textInputAction: TextInputAction.done,
        maxLength: 6,
        style: text.bodyLarge,
        decoration: InputDecoration(
          labelText: s.codeFromEmail,
          counterText: '',
          prefixIcon: const Icon(Icons.pin_rounded),
        ),
        onFieldSubmitted: (_) => _verify(),
      ),
      const SizedBox(height: 18),
      PrimaryPillButton(
        label: s.confirm,
        busy: _busy,
        onPressed: _busy ? null : _verify,
      ),
      const SizedBox(height: 8),
      Center(
        child: TextButton(
          onPressed: _resendCooling ? null : _resend,
          child: Text(_resendCooling ? s.resendIn(30) : s.resend),
        ),
      ),
    ];
  }

  List<Widget> _telegramStep(BuildContext context, AppStrings s) {
    final TextTheme text = Theme.of(context).textTheme;
    final TelegramHandoff handoff =
        _handoff ?? const TelegramHandoff(url: '', code: '');
    final String handle =
        handoff.botHandle.isEmpty ? '@glukvpnbot' : handoff.botHandle;

    return <Widget>[
      Text(s.emailConfirmed, style: text.titleMedium),
      const SizedBox(height: 6),
      Text(s.openBotAndShareContact(handle), style: text.bodyMedium),
      const SizedBox(height: 20),
      PrimaryPillButton(
        label: s.openTelegram,
        icon: Icons.open_in_new_rounded,
        onPressed: handoff.url.isEmpty ? null : _openBot,
      ),
      if (handoff.code.isNotEmpty) ...<Widget>[
        const SizedBox(height: 16),
        Text(s.telegramFallbackHint, style: text.bodySmall),
        const SizedBox(height: 8),
        _CopyRow(
          label: s.codeForBot,
          value: handoff.code,
          onCopy: () => _copy(handoff.code, s.copied),
        ),
      ],
      const SizedBox(height: 20),
      Row(
        children: <Widget>[
          const SizedBox(
            width: 15,
            height: 15,
            child: CircularProgressIndicator(strokeWidth: 1.8),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(s.waitingForConfirmation, style: text.bodySmall),
          ),
        ],
      ),
    ];
  }

  List<Widget> _doneStep(BuildContext context, AppStrings s) {
    final TextTheme text = Theme.of(context).textTheme;
    return <Widget>[
      const Icon(Icons.check_circle_rounded,
          size: 42, color: GlukColors.connected),
      const SizedBox(height: 14),
      Text(s.accountReady, style: text.headlineSmall),
      const SizedBox(height: 10),
      if (_username.isNotEmpty)
        _CopyRow(
          label: s.yourUsername,
          value: _username,
          onCopy: () => _copy(_username, s.copied),
        ),
      const SizedBox(height: 10),
      Text(s.signInWithEither, style: text.bodySmall),
      const SizedBox(height: 22),
      PrimaryPillButton(
        label: s.goToSignIn,
        onPressed: () => Navigator.of(context).pop(),
      ),
    ];
  }

  List<Widget> _closedStep(BuildContext context, AppStrings s) {
    return <Widget>[
      InlineNotice(message: _closedReason, tone: GlukColors.amber),
      const SizedBox(height: 20),
      PrimaryPillButton(
        label: s.back,
        onPressed: () => Navigator.of(context).pop(),
      ),
    ];
  }
}

/// Password recovery, the other half of the sign-in screen that only existed
/// on the website until round 10.
enum _RecStep { request, reset, done }

class RecoverScreen extends StatefulWidget {
  const RecoverScreen({super.key});

  @override
  State<RecoverScreen> createState() => _RecoverScreenState();
}

class _RecoverScreenState extends State<RecoverScreen> {
  final RegisterApi _api = RegisterApi();
  final GlobalKey<FormState> _form = GlobalKey<FormState>();

  final TextEditingController _identifier = TextEditingController();
  final TextEditingController _code = TextEditingController();
  final TextEditingController _password = TextEditingController();
  final TextEditingController _password2 = TextEditingController();

  _RecStep _step = _RecStep.request;
  String _channel = 'email';
  String _sentTo = '';
  bool _busy = false;
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
    _identifier.dispose();
    _code.dispose();
    _password.dispose();
    _password2.dispose();
    _api.close();
    super.dispose();
  }

  void _fail(Object error) {
    if (!mounted) return;
    setState(() {
      _error = error is ApiException
          ? error.message
          : context.strings.somethingWentWrong;
      _busy = false;
    });
  }

  Future<void> _request() async {
    if (_busy) return;
    final String id = _identifier.text.trim();
    if (id.length < 3) {
      setState(() => _error = context.strings.enterUsernameOrEmail);
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final String used =
          await _api.forgotPassword(identifier: id, channel: _channel);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _sentTo = used;
        _step = _RecStep.reset;
      });
    } catch (error) {
      _fail(error);
    }
  }

  Future<void> _reset() async {
    if (_busy) return;
    if (!(_form.currentState?.validate() ?? false)) return;
    final String code = _code.text.replaceAll(RegExp(r'[^0-9]'), '');
    if (code.length != 6) {
      setState(() => _error = context.strings.codeIsSixDigits);
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _api.resetPassword(
        identifier: _identifier.text.trim(),
        code: code,
        password: _password.text,
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _step = _RecStep.done;
      });
    } catch (error) {
      _fail(error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppStrings s = context.strings;
    return _AuthShell(
      title: s.recoverTitle,
      subtitle: s.recoverSubtitle,
      progress: switch (_step) {
        _RecStep.request => 1,
        _RecStep.reset => 2,
        _RecStep.done => 2,
      },
      steps: 2,
      error: _error,
      onDismissError: () => setState(() => _error = null),
      children: switch (_step) {
        _RecStep.request => _requestStep(context, s),
        _RecStep.reset => _resetStep(context, s),
        _RecStep.done => _doneStep(context, s),
      },
    );
  }

  List<Widget> _requestStep(BuildContext context, AppStrings s) {
    final TextTheme text = Theme.of(context).textTheme;
    return <Widget>[
      TextFormField(
        controller: _identifier,
        autocorrect: false,
        enableSuggestions: false,
        keyboardType: TextInputType.emailAddress,
        textInputAction: TextInputAction.done,
        style: text.bodyLarge,
        decoration: InputDecoration(
          labelText: s.usernameOrEmail,
          prefixIcon: const Icon(Icons.person_outline_rounded),
        ),
        onFieldSubmitted: (_) => _request(),
      ),
      const SizedBox(height: 16),
      Text(s.whereToSendCode, style: text.labelMedium),
      const SizedBox(height: 8),
      _ChannelChoice(
        value: _channel,
        onChanged: (String next) => setState(() => _channel = next),
      ),
      const SizedBox(height: 22),
      PrimaryPillButton(
        label: s.sendTheCode,
        busy: _busy,
        onPressed: _busy ? null : _request,
      ),
    ];
  }

  List<Widget> _resetStep(BuildContext context, AppStrings s) {
    final TextTheme text = Theme.of(context).textTheme;
    return <Widget>[
      Text(
        _sentTo == 'telegram' ? s.codeSentByTelegram : s.codeSentByEmail,
        style: text.bodyMedium,
      ),
      const SizedBox(height: 18),
      Form(
        key: _form,
        child: Column(
          children: <Widget>[
            TextFormField(
              controller: _code,
              keyboardType: TextInputType.number,
              maxLength: 6,
              style: text.bodyLarge,
              decoration: InputDecoration(
                labelText: s.code,
                counterText: '',
                prefixIcon: const Icon(Icons.pin_rounded),
              ),
            ),
            const SizedBox(height: 8),
            TextFormField(
              controller: _password,
              obscureText: _obscure,
              autocorrect: false,
              enableSuggestions: false,
              style: text.bodyLarge,
              decoration: InputDecoration(
                labelText: s.newPassword,
                prefixIcon: const Icon(Icons.lock_outline_rounded),
                suffixIcon: IconButton(
                  icon: Icon(_obscure
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined),
                  tooltip: _obscure ? s.showPassword : s.hidePassword,
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
              validator: (String? value) =>
                  (value ?? '').length < AppConfig.minPasswordLength
                      ? s.atLeastChars(AppConfig.minPasswordLength)
                      : null,
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _password2,
              obscureText: _obscure,
              autocorrect: false,
              enableSuggestions: false,
              style: text.bodyLarge,
              decoration: InputDecoration(
                labelText: s.repeatPassword,
                prefixIcon: const Icon(Icons.lock_reset_rounded),
              ),
              validator: (String? value) => (value ?? '') == _password.text
                  ? null
                  : s.passwordsDoNotMatch,
              onFieldSubmitted: (_) => _reset(),
            ),
          ],
        ),
      ),
      const SizedBox(height: 22),
      PrimaryPillButton(
        label: s.savePasswordLabel,
        busy: _busy,
        onPressed: _busy ? null : _reset,
      ),
    ];
  }

  List<Widget> _doneStep(BuildContext context, AppStrings s) {
    final TextTheme text = Theme.of(context).textTheme;
    return <Widget>[
      const Icon(Icons.check_circle_rounded,
          size: 42, color: GlukColors.connected),
      const SizedBox(height: 14),
      Text(s.passwordChanged, style: text.headlineSmall),
      const SizedBox(height: 6),
      Text(s.passwordChangedBody, style: text.bodySmall),
      const SizedBox(height: 22),
      PrimaryPillButton(
        label: s.goToSignIn,
        onPressed: () => Navigator.of(context).pop(),
      ),
    ];
  }
}

// --- shared chrome ----------------------------------------------------------

/// The sign-in layout, reused verbatim.
///
/// Every measurement here is copied from `LoginView`: the wave backdrop, the
/// 24/16/24/28 padding, the 56 px mark, `headlineMedium` over `bodyMedium`, and
/// the same keyboard-inset handling. That is the whole point of the widget -
/// registration and recovery are not new screens, they are the same screen with
/// different fields, and they should be indistinguishable until the form
/// starts.
class _AuthShell extends StatelessWidget {
  const _AuthShell({
    required this.title,
    required this.subtitle,
    required this.progress,
    required this.children,
    this.steps = 3,
    this.error,
    this.notice,
    this.onDismissError,
  });

  final String title;
  final String subtitle;
  final int progress;
  final int steps;
  final List<Widget> children;
  final String? error;
  final String? notice;
  final VoidCallback? onDismissError;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;

    return Scaffold(
      backgroundColor: GlukColors.pageBg,
      body: PageBackground(
        child: SafeArea(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              24,
              16,
              24,
              28 + MediaQuery.viewInsetsOf(context).bottom,
            ),
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                CircleIconButton(
                  icon: Icons.arrow_back_rounded,
                  tooltip: context.strings.back,
                  onTap: () => Navigator.of(context).maybePop(),
                ),
                const SizedBox(height: 26),
                const GlukLogo(size: 56),
                const SizedBox(height: 18),
                Text(title, style: text.headlineMedium),
                const SizedBox(height: 6),
                Text(subtitle, style: text.bodyMedium),
                if (progress > 0) ...<Widget>[
                  const SizedBox(height: 18),
                  _StepDots(at: progress, of: steps),
                ],
                const SizedBox(height: 24),
                if (error != null) ...<Widget>[
                  InkWell(
                    onTap: onDismissError,
                    child: InlineNotice(message: error!),
                  ),
                  const SizedBox(height: 14),
                ],
                if (notice != null) ...<Widget>[
                  InlineNotice(message: notice!, tone: GlukColors.violetLight),
                  const SizedBox(height: 14),
                ],
                ...children,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StepDots extends StatelessWidget {
  const _StepDots({required this.at, required this.of});

  final int at;
  final int of;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        for (int i = 1; i <= of; i++) ...<Widget>[
          Expanded(
            child: Container(
              height: 4,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(999),
                color: i <= at
                    ? GlukColors.violetLight
                    : Colors.white.withOpacity(0.10),
              ),
            ),
          ),
          if (i != of) const SizedBox(width: 6),
        ],
      ],
    );
  }
}

/// A value worth copying, with the button next to it. Codes and usernames are
/// exactly the things people fat-finger when they have to retype them.
class _CopyRow extends StatelessWidget {
  const _CopyRow({
    required this.label,
    required this.value,
    required this.onCopy,
  });

  final String label;
  final String value;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return GlassPanel(
      radius: GlukSizes.cellRadius,
      padding: const EdgeInsets.fromLTRB(14, 11, 6, 11),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(label.toUpperCase(), style: text.labelMedium),
                const SizedBox(height: 3),
                Text(
                  value,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodyMedium?.copyWith(color: GlukColors.text0),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.copy_rounded, size: 17),
            color: GlukColors.text2,
            tooltip: context.strings.copy,
            onPressed: onCopy,
          ),
        ],
      ),
    );
  }
}

class _ChannelChoice extends StatelessWidget {
  const _ChannelChoice({required this.value, required this.onChanged});

  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final AppStrings s = context.strings;
    return Row(
      children: <Widget>[
        Expanded(
          child: _ChoiceChip(
            label: s.email,
            icon: Icons.mail_outline_rounded,
            selected: value == 'email',
            onTap: () => onChanged('email'),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _ChoiceChip(
            label: s.telegram,
            icon: Icons.send_rounded,
            selected: value == 'telegram',
            onTap: () => onChanged('telegram'),
          ),
        ),
      ],
    );
  }
}

class _ChoiceChip extends StatelessWidget {
  const _ChoiceChip({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return GlassPanel(
      radius: 999,
      onTap: onTap,
      color: selected ? GlukColors.violet.withOpacity(0.18) : GlukColors.cell,
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Icon(
            icon,
            size: 16,
            color: selected ? GlukColors.violetLight : GlukColors.text2,
          ),
          const SizedBox(width: 8),
          Text(
            label,
            style: text.titleMedium?.copyWith(
              color: selected ? GlukColors.text0 : GlukColors.text2,
            ),
          ),
        ],
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint(this.text);

  final String text;

  @override
  Widget build(BuildContext context) =>
      Text(text, style: Theme.of(context).textTheme.bodySmall);
}
