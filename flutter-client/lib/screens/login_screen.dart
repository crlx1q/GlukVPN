import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../config.dart';
import '../state/auth_controller.dart';
import '../widgets/common.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _username = TextEditingController();
  final TextEditingController _password = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    FocusScope.of(context).unfocus();
    // The controller owns the error state, so nothing to handle here.
    await context.read<AuthController>().login(
          username: _username.text,
          password: _password.text,
        );
  }

  @override
  Widget build(BuildContext context) {
    final AuthController auth = context.watch<AuthController>();
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Icon(Icons.shield_outlined, size: 64, color: scheme.primary),
                    const SizedBox(height: 16),
                    const Text(
                      'GlukVPN',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Personal WireGuard test service',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 32),
                    if (auth.error != null)
                      MessageBanner(
                        message: auth.error!,
                        isError: true,
                        onDismiss: auth.clearError,
                      ),
                    TextFormField(
                      controller: _username,
                      autocorrect: false,
                      enableSuggestions: false,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        labelText: 'Username',
                        prefixIcon: Icon(Icons.person_outline),
                      ),
                      validator: (String? value) {
                        final String text = (value ?? '').trim();
                        if (text.length < AppConfig.minUsernameLength) {
                          return 'At least ${AppConfig.minUsernameLength} characters';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 14),
                    TextFormField(
                      controller: _password,
                      obscureText: _obscure,
                      autocorrect: false,
                      enableSuggestions: false,
                      textInputAction: TextInputAction.done,
                      onFieldSubmitted: (_) => _submit(),
                      decoration: InputDecoration(
                        labelText: 'Password',
                        prefixIcon: const Icon(Icons.lock_outline),
                        suffixIcon: IconButton(
                          icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility),
                          onPressed: () => setState(() => _obscure = !_obscure),
                          tooltip: _obscure ? 'Show password' : 'Hide password',
                        ),
                      ),
                      validator: (String? value) {
                        if ((value ?? '').length < AppConfig.minPasswordLength) {
                          return 'At least ${AppConfig.minPasswordLength} characters';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: auth.busy ? null : _submit,
                      child: auth.busy
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('SIGN IN'),
                    ),
                    const SizedBox(height: 26),
                    Text(
                      'Control API\n${AppConfig.apiBaseUrl}',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                    ),
                    if (!AppConfig.usesHttps)
                      Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: Text(
                          'This build talks to the API over plain HTTP. '
                          'Credentials would travel unencrypted.',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 11, color: scheme.error),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
