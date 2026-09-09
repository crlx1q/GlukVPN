import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../services/link_opener.dart';
import '../state/auth_controller.dart';
import '../theme/tokens.dart';
import 'glass.dart';

/// «Безопасность аккаунта» — одна карточка для телефона и для ПК.
///
/// До этого смена пароля, почты и перепривязка Telegram были только на
/// сайте: в приложениях человек видел свой аккаунт, но не мог ничего с
/// ним сделать. Эндпоинты одни и те же, поэтому и экран один.
///
/// Номер телефона приходит с сервера уже замаскированным (`+7 *** *** 4729`):
/// клиент его целиком не получает вообще — владелец себя узнаёт, а человек
/// за соседним столом — нет.
class AccountSecurityCard extends StatefulWidget {
  const AccountSecurityCard({
    super.key,
    required this.auth,
    required this.russian,
  });

  final AuthController auth;
  final bool russian;

  @override
  State<AccountSecurityCard> createState() => _AccountSecurityCardState();
}

enum _Pane { none, password, email, telegram }

class _AccountSecurityCardState extends State<AccountSecurityCard> {
  final TextEditingController _current = TextEditingController();
  final TextEditingController _fresh = TextEditingController();
  final TextEditingController _repeat = TextEditingController();
  final TextEditingController _address = TextEditingController();
  final TextEditingController _code = TextEditingController();

  _Pane _pane = _Pane.none;
  bool _busy = false;
  bool _awaitingCode = false;
  String? _message;
  bool _failed = false;

  bool _linked = false;
  String? _telegramName;
  String? _phone;
  String? _botCode;

  bool get _ru => widget.russian;

  String _t(String ru, String en) => _ru ? ru : en;

  @override
  void initState() {
    super.initState();
    _loadTelegram();
  }

  @override
  void dispose() {
    _current.dispose();
    _fresh.dispose();
    _repeat.dispose();
    _address.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _loadTelegram() async {
    try {
      final Map<String, dynamic> json = await widget.auth.api.telegramStatus();
      if (!mounted) return;
      final Object? name = json['username'];
      final Object? mask = json['phoneMask'];
      final Object? tail = json['phoneTail'];
      setState(() {
        _linked = json['linked'] == true;
        _telegramName = name is String && name.isNotEmpty ? name : null;
        if (mask is String && mask.isNotEmpty) {
          _phone = mask;
        } else if (tail is String && tail.isNotEmpty) {
          _phone = '*** ' + tail;
        } else {
          _phone = null;
        }
      });
    } on ApiException {
      // Карточка без этих двух строк остаётся рабочей.
    }
  }

  void _say(String text, {bool failed = false}) {
    if (!mounted) return;
    setState(() {
      _message = text;
      _failed = failed;
    });
  }

  void _toggle(_Pane pane) {
    setState(() {
      _pane = _pane == pane ? _Pane.none : pane;
      _message = null;
      _failed = false;
    });
  }

  Future<void> _savePassword() async {
    final String fresh = _fresh.text;
    if (fresh.length < 8) {
      _say(
        _t('Новый пароль — минимум 8 символов.',
            'The new password must be at least 8 characters.'),
        failed: true,
      );
      return;
    }
    if (fresh != _repeat.text) {
      _say(
        _t('Пароли не совпадают.', 'The passwords do not match.'),
        failed: true,
      );
      return;
    }
    setState(() => _busy = true);
    try {
      final int revoked = await widget.auth.api.changePassword(
        currentPassword: _current.text,
        password: fresh,
      );
      _current.clear();
      _fresh.clear();
      _repeat.clear();
      _say(_t(
        'Пароль изменён. Остальные сессии завершены: $revoked.',
        'Password changed. Other sessions signed out: $revoked.',
      ));
    } on ApiException catch (error) {
      _say(error.message, failed: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveEmail() async {
    if (!_awaitingCode) {
      final String address = _address.text.trim();
      if (!address.contains('@')) {
        _say(
          _t('Нужен почтовый адрес.', 'An email address is required.'),
          failed: true,
        );
        return;
      }
      setState(() => _busy = true);
      try {
        await widget.auth.requestEmailChange(address);
        if (mounted) setState(() => _awaitingCode = true);
        _say(_t('Код отправлен на новый адрес.',
            'A code was sent to the new address.'));
      } on ApiException catch (error) {
        _say(error.message, failed: true);
      } finally {
        if (mounted) setState(() => _busy = false);
      }
      return;
    }

    final String code = _code.text.replaceAll(RegExp(r'\D+'), '');
    if (code.length != 6) {
      _say(
        _t('Код из шести цифр.', 'The code has six digits.'),
        failed: true,
      );
      return;
    }
    setState(() => _busy = true);
    try {
      await widget.auth.confirmEmailChange(code);
      _code.clear();
      _address.clear();
      if (mounted) setState(() => _awaitingCode = false);
      _say(_t('Адрес почты обновлён.', 'The email address is updated.'));
    } on ApiException catch (error) {
      _say(error.message, failed: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _startTelegram() async {
    setState(() => _busy = true);
    String? url;
    try {
      final Map<String, dynamic> json =
          await widget.auth.api.telegramLinkStart();
      final Object? link = json['url'];
      final Object? code = json['code'];
      url = link is String ? link : null;
      if (mounted) {
        setState(() => _botCode = code is String ? code : null);
      }
      _say(_t(
        'Откройте бота и нажмите «Поделиться контактом».',
        'Open the bot and press “Share contact”.',
      ));
    } on ApiException catch (error) {
      _say(error.message, failed: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }

    if (url == null || !mounted) return;
    await LinkOpener.openOrCopy(
      context,
      url,
      failureMessage: _t('Ссылка скопирована — откройте её в Telegram.',
          'The link is copied — open it in Telegram.'),
    );
    // Привязка заканчивается в боте, поэтому статус переспрашиваем потом.
    await Future<void>.delayed(const Duration(seconds: 6));
    if (mounted) await _loadTelegram();
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final String email = widget.auth.user?.email ?? '';
    final bool verified = widget.auth.user?.emailVerified ?? false;

    return GlassPanel(
      radius: GlukSizes.trafficRadius,
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            _t('БЕЗОПАСНОСТЬ АККАУНТА', 'ACCOUNT SECURITY'),
            style: text.labelMedium,
          ),
          const SizedBox(height: 10),
          _row(
            _t('Почта', 'Email'),
            email.isEmpty ? '\u2014' : email,
            hint: email.isEmpty
                ? null
                : (verified
                    ? _t('подтверждена', 'verified')
                    : _t('не подтверждена', 'unverified')),
            warn: email.isNotEmpty && !verified,
          ),
          _row(
            'Telegram',
            _linked
                ? (_telegramName == null ? _t('привязан', 'linked') : '@' + _telegramName!)
                : _t('не привязан', 'not linked'),
            warn: !_linked,
          ),
          _row(
            _t('Номер', 'Phone'),
            _phone ?? _t('нет номера', 'no number'),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              _tab(_t('Сменить пароль', 'Change password'), _Pane.password),
              _tab(_t('Сменить почту', 'Change email'), _Pane.email),
              _tab(
                _linked
                    ? _t('Перепривязать Telegram', 'Re-link Telegram')
                    : _t('Привязать Telegram', 'Link Telegram'),
                _Pane.telegram,
              ),
            ],
          ),
          if (_pane != _Pane.none) ...<Widget>[
            const SizedBox(height: 12),
            _form(text),
          ],
          if (_message != null) ...<Widget>[
            const SizedBox(height: 10),
            Text(
              _message!,
              style: text.bodySmall?.copyWith(
                color: _failed ? GlukColors.amber : GlukColors.connected,
              ),
            ),
          ],
          const SizedBox(height: 8),
          Text(
            _t('Забыли пароль — восстановление по почте живёт на экране входа.',
                'Forgot the password — email recovery lives on the sign-in screen.'),
            style: text.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _tab(String label, _Pane pane) => OutlinedButton(
        onPressed: _busy ? null : () => _toggle(pane),
        child: Text(label),
      );

  Widget _form(TextTheme text) {
    switch (_pane) {
      case _Pane.password:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _field(_current, _t('Текущий пароль', 'Current password'), secret: true),
            _field(_fresh, _t('Новый пароль', 'New password'), secret: true),
            _field(_repeat, _t('Повторите пароль', 'Repeat the password'),
                secret: true),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: _busy ? null : _savePassword,
              child: Text(_t('Сохранить пароль', 'Save password')),
            ),
            const SizedBox(height: 6),
            Text(
              _t('После смены все остальные сессии завершаются.',
                  'Every other session is signed out after the change.'),
              style: text.bodySmall,
            ),
          ],
        );
      case _Pane.email:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _field(_address, _t('Новая почта', 'New email')),
            if (_awaitingCode)
              _field(_code, _t('Код из письма', 'Code from the email')),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: _busy ? null : _saveEmail,
              child: Text(_awaitingCode
                  ? _t('Подтвердить', 'Confirm')
                  : _t('Прислать код', 'Send the code')),
            ),
          ],
        );
      case _Pane.telegram:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              _t('Бот попросит поделиться контактом — это и есть привязка.',
                  'The bot asks you to share the contact — that is the binding.'),
              style: text.bodySmall,
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: _busy ? null : _startTelegram,
              child: Text(_t('Открыть бота', 'Open the bot')),
            ),
            if (_botCode != null) ...<Widget>[
              const SizedBox(height: 6),
              Text(
                _t('Код для ручного ввода: ', 'Code to type by hand: ') + _botCode!,
                style: text.bodySmall?.copyWith(color: GlukColors.text0),
              ),
            ],
          ],
        );
      case _Pane.none:
        return const SizedBox.shrink();
    }
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    bool secret = false,
  }) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: TextField(
          controller: controller,
          obscureText: secret,
          enabled: !_busy,
          decoration: InputDecoration(labelText: label),
        ),
      );

  Widget _row(String label, String value, {String? hint, bool warn = false}) {
    final TextTheme text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(child: Text(label, style: text.bodySmall)),
          const SizedBox(width: 12),
          Expanded(
            flex: 2,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                Text(
                  value,
                  textAlign: TextAlign.right,
                  style: text.bodyMedium?.copyWith(color: GlukColors.text0),
                ),
                if (hint != null)
                  Text(
                    hint,
                    textAlign: TextAlign.right,
                    style: text.bodySmall?.copyWith(
                      color: warn ? GlukColors.amber : GlukColors.connected,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
