import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../config.dart';
import '../services/api_client.dart';
import '../services/register_api.dart';
import '../theme/tokens.dart';
import '../widgets/glass.dart';
import '../widgets/logo.dart';

/// ROUND 10 (4.1): sign-up on the phone, in the same three steps the website
/// uses.
///
///   1. email + password
///   2. the six-digit code from the email
///   3. the Telegram bot, where a shared contact finishes the account
///
/// The order is not decoration. A code proves the address exists, and addresses
/// are free and infinite. A phone number handed over through Telegram's own
/// "share contact" button is not. Until now the phone had no sign-up at all and
/// pointed people at the website; that is exactly the kind of gap that makes an
/// app feel like a shell around a browser.
///
/// There is no captcha here. Turnstile has no Flutter widget, and shipping a
/// WebView for one checkbox would be worse than the problem: the server treats
/// a missing token the same way it does for the desktop client, and the rate
/// limits on `/api/auth/register/*` still apply.
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
    setState(() {
      _codeTtl = config.codeTtlMinutes;
      if (config.open) return;
      _step = _RegStep.closed;
      _closedReason = config.selfRegistration
          ? 'Telegram confirmation is unavailable right now, so sign-up is '
              'closed. Message us and we will open access by hand.'
          : 'Sign-up is closed at the moment. Message us and we will open '
              'access by hand.';
    });
  }

  void _fail(Object error) {
    final String message = error is ApiException
        ? error.message
        : 'Something went wrong. Please try again.';
    if (!mounted) return;
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
      setState(() => _error = 'The code is 6 digits.');
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
      setState(() => _notice = 'A new code has been sent.');
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
        setState(() => _notice = 'Stopped checking. Reopen this screen if you '
            'already confirmed in Telegram.');
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
    final String text = (value ?? '').trim();
    if (text.isEmpty) return 'Enter your email address';
    final int at = text.indexOf('@');
    final bool ok = at > 0 &&
        text.length > at + 3 &&
        text.indexOf('.', at) > at + 1 &&
        !text.contains(' ');
    return ok ? null : 'Enter a valid email address';
  }

  String? _validatePassword(String? value) {
    final String text = value ?? '';
    if (text.length < AppConfig.minPasswordLength) {
      return 'At least ${AppConfig.minPasswordLength} characters';
    }
    return null;
  }

  String? _validateRepeat(String? value) {
    if ((value ?? '') != _password.text) return 'The passwords do not match';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return _AuthScaffold(
      title: 'Create an account',
      subtitle: _step == _RegStep.closed
          ? 'Sign-up is not available right now.'
          : 'Email and password, a code from the email, then a confirmation '
              'in Telegram \u2014 three steps.',
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
        _RegStep.form => _formStep(context),
        _RegStep.code => _codeStep(context),
        _RegStep.telegram => _telegramStep(context),
        _RegStep.done => _doneStep(context),
        _RegStep.closed => _closedStep(context),
      },
    );
  }

  List<Widget> _formStep(BuildContext context) {
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
              decoration: const InputDecoration(
                labelText: 'Email',
                prefixIcon: Icon(Icons.alternate_email_rounded),
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
              decoration: InputDecoration(
                labelText: 'Password',
                prefixIcon: const Icon(Icons.lock_outline_rounded),
                suffixIcon: IconButton(
                  icon: Icon(_obscure
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined),
                  tooltip: _obscure ? 'Show password' : 'Hide password',
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
              decoration: const InputDecoration(
                labelText: 'Repeat the password',
                prefixIcon: Icon(Icons.lock_reset_rounded),
              ),
              validator: _validateRepeat,
              onFieldSubmitted: (_) => _start(),
            ),
          ],
        ),
      ),
      const SizedBox(height: 20),
      PrimaryPillButton(
        label: 'Continue',
        busy: _busy,
        onPressed: _busy ? null : _start,
      ),
      const SizedBox(height: 14),
      _Hint(
        'The account is always created on the main GlukVPN servers, even if '
        'this build is pointed at beta.',
      ),
    ];
  }

  List<Widget> _codeStep(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return <Widget>[
      Text('We sent a 6-digit code to', style: text.bodyMedium),
      const SizedBox(height: 2),
      Text(_email.text.trim(), style: text.titleMedium),
      const SizedBox(height: 4),
      Text('It is valid for $_codeTtl minutes.', style: text.bodySmall),
      if (!_mailDelivered) ...<Widget>[
        const SizedBox(height: 12),
        const InlineNotice(
          message: 'The email could not be sent. Try Resend, or write to '
              'support if it keeps failing.',
        ),
      ],
      const SizedBox(height: 18),
      TextFormField(
        controller: _code,
        keyboardType: TextInputType.number,
        textInputAction: TextInputAction.done,
        maxLength: 6,
        decoration: const InputDecoration(
          labelText: 'Code from the email',
          counterText: '',
          prefixIcon: Icon(Icons.pin_rounded),
        ),
        onFieldSubmitted: (_) => _verify(),
      ),
      const SizedBox(height: 18),
      PrimaryPillButton(
        label: 'Confirm',
        busy: _busy,
        onPressed: _busy ? null : _verify,
      ),
      const SizedBox(height: 8),
      Align(
        alignment: Alignment.center,
        child: TextButton(
          onPressed: _resendCooling ? null : _resend,
          child: Text(_resendCooling ? 'Code sent \u2014 wait 30 s' : 'Resend'),
        ),
      ),
    ];
  }

  List<Widget> _telegramStep(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final TelegramHandoff handoff =
        _handoff ?? const TelegramHandoff(url: '', code: '');
    final String handle =
        handoff.botHandle.isEmpty ? '@glukvpnbot' : handoff.botHandle;

    return <Widget>[
      Text('Email confirmed.', style: text.titleMedium),
      const SizedBox(height: 6),
      Text(
        'Last step: open $handle in Telegram and press the button that shares '
        'your contact. That is what tells one real person apart from a hundred '
        'throwaway addresses.',
        style: text.bodyMedium,
      ),
      const SizedBox(height: 16),
      if (handoff.url.isNotEmpty)
        _CopyRow(
          label: 'Link to the bot',
          value: handoff.url,
          onCopy: () => _copy(handoff.url, 'Link copied'),
        ),
      if (handoff.code.isNotEmpty) ...<Widget>[
        const SizedBox(height: 10),
        _CopyRow(
          label: 'Code for the bot',
          value: handoff.code,
          onCopy: () => _copy(handoff.code, 'Code copied'),
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
            child: Text(
              'Waiting for the confirmation. This screen updates by itself.',
              style: text.bodySmall,
            ),
          ),
        ],
      ),
    ];
  }

  List<Widget> _doneStep(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return <Widget>[
      const Icon(Icons.check_circle_rounded,
          size: 42, color: GlukColors.connected),
      const SizedBox(height: 14),
      Text('The account is ready', style: text.headlineSmall),
      const SizedBox(height: 6),
      if (_username.isNotEmpty)
        _CopyRow(
          label: 'Your username',
          value: _username,
          onCopy: () => _copy(_username, 'Username copied'),
        ),
      const SizedBox(height: 8),
      Text(
        'Sign in with this username or with your email address \u2014 either '
        'one works.',
        style: text.bodySmall,
      ),
      const SizedBox(height: 20),
      PrimaryPillButton(
        label: 'Go to sign in',
        onPressed: () => Navigator.of(context).pop(),
      ),
    ];
  }

  List<Widget> _closedStep(BuildContext context) {
    return <Widget>[
      InlineNotice(message: _closedReason),
      const SizedBox(height: 18),
      PrimaryPillButton(
        label: 'Back',
        onPressed: () => Navigator.of(context).pop(),
      ),
    ];
  }
}

/// ROUND 10 (4.1): password recovery, the other half of the sign-in screen that
/// only existed on the website.
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
          : 'Something went wrong. Please try again.';
      _busy = false;
    });
  }

  Future<void> _request() async {
    if (_busy) return;
    final String id = _identifier.text.trim();
    if (id.length < 3) {
      setState(() => _error = 'Enter your username or email');
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
      setState(() => _error = 'The code is 6 digits.');
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
    return _AuthScaffold(
      title: 'Recover access',
      subtitle: 'We send a code to your email or to Telegram \u2014 whichever '
          'is easier.',
      progress: switch (_step) {
        _RecStep.request => 1,
        _RecStep.reset => 2,
        _RecStep.done => 2,
      },
      steps: 2,
      error: _error,
      onDismissError: () => setState(() => _error = null),
      children: switch (_step) {
        _RecStep.request => _requestStep(context),
        _RecStep.reset => _resetStep(context),
        _RecStep.done => _doneStep(context),
      },
    );
  }

  List<Widget> _requestStep(BuildContext context) {
    return <Widget>[
      TextFormField(
        controller: _identifier,
        autocorrect: false,
        enableSuggestions: false,
        keyboardType: TextInputType.emailAddress,
        textInputAction: TextInputAction.done,
        decoration: const InputDecoration(
          labelText: 'Username or email',
          prefixIcon: Icon(Icons.person_outline_rounded),
        ),
        onFieldSubmitted: (_) => _request(),
      ),
      const SizedBox(height: 14),
      _ChannelChoice(
        value: _channel,
        onChanged: (String next) => setState(() => _channel = next),
      ),
      const SizedBox(height: 20),
      PrimaryPillButton(
        label: 'Send the code',
        busy: _busy,
        onPressed: _busy ? null : _request,
      ),
      const SizedBox(height: 14),
      _Hint(
        'The code goes to the account on the channel this build is using '
        '(${AppConfig.activeChannel.label}). A password belongs to the account '
        'you actually sign in to.',
      ),
    ];
  }

  List<Widget> _resetStep(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return <Widget>[
      Text(
        _sentTo == 'telegram'
            ? 'The code was sent to Telegram.'
            : 'The code was sent by email.',
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
              decoration: const InputDecoration(
                labelText: 'Code',
                counterText: '',
                prefixIcon: Icon(Icons.pin_rounded),
              ),
            ),
            const SizedBox(height: 8),
            TextFormField(
              controller: _password,
              obscureText: _obscure,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: 'New password',
                prefixIcon: const Icon(Icons.lock_outline_rounded),
                suffixIcon: IconButton(
                  icon: Icon(_obscure
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined),
                  tooltip: _obscure ? 'Show password' : 'Hide password',
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
              validator: (String? value) {
                if ((value ?? '').length < AppConfig.minPasswordLength) {
                  return 'At least ${AppConfig.minPasswordLength} characters';
                }
                return null;
              },
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _password2,
              obscureText: _obscure,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: 'Repeat the password',
                prefixIcon: Icon(Icons.lock_reset_rounded),
              ),
              validator: (String? value) =>
                  (value ?? '') == _password.text ? null : 'The passwords do not match',
              onFieldSubmitted: (_) => _reset(),
            ),
          ],
        ),
      ),
      const SizedBox(height: 20),
      PrimaryPillButton(
        label: 'Save the password',
        busy: _busy,
        onPressed: _busy ? null : _reset,
      ),
    ];
  }

  List<Widget> _doneStep(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return <Widget>[
      const Icon(Icons.check_circle_rounded,
          size: 42, color: GlukColors.connected),
      const SizedBox(height: 14),
      Text('The password is changed', style: text.headlineSmall),
      const SizedBox(height: 6),
      Text(
        'Every other session was signed out, so anybody who had the old '
        'password is out too.',
        style: text.bodySmall,
      ),
      const SizedBox(height: 20),
      PrimaryPillButton(
        label: 'Go to sign in',
        onPressed: () => Navigator.of(context).pop(),
      ),
    ];
  }
}

// --- shared chrome ----------------------------------------------------------

/// One frame for both flows: back arrow, mark, title, step dots, error slot.
/// Written once so registration and recovery cannot drift apart visually the
/// way the two website pages did before round 9 merged them.
class _AuthScaffold extends StatelessWidget {
  const _AuthScaffold({
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
      body: SafeArea(
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
                tooltip: 'Back',
                onTap: () => Navigator.of(context).maybePop(),
              ),
              const SizedBox(height: 22),
              const GlukLogo(size: 48),
              const SizedBox(height: 16),
              Text(title, style: text.headlineMedium),
              const SizedBox(height: 6),
              Text(subtitle, style: text.bodyMedium),
              if (progress > 0) ...<Widget>[
                const SizedBox(height: 16),
                _StepDots(at: progress, of: steps),
              ],
              const SizedBox(height: 22),
              if (error != null) ...<Widget>[
                InkWell(
                  onTap: onDismissError,
                  child: InlineNotice(message: error!),
                ),
                const SizedBox(height: 14),
              ],
              if (notice != null) ...<Widget>[
                _Hint(notice!),
                const SizedBox(height: 14),
              ],
              ...children,
            ],
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

/// A value worth copying, with the button next to it. Codes and links are
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
            tooltip: 'Copy',
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
    return Row(
      children: <Widget>[
        Expanded(
          child: _ChoiceChip(
            label: 'Email',
            icon: Icons.mail_outline_rounded,
            selected: value == 'email',
            onTap: () => onChanged('email'),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _ChoiceChip(
            label: 'Telegram',
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
      color: selected ? GlukColors.violet.withOpacity(0.18) : null,
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
  Widget build(BuildContext context) {
    return Text(text, style: Theme.of(context).textTheme.bodySmall);
  }
}
