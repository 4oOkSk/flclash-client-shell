import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/core.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class ClientGate extends ConsumerStatefulWidget {
  final Widget child;
  final Future<bool> Function()? sessionCheck;
  final Future<String> Function()? configSetup;

  const ClientGate({
    super.key,
    required this.child,
    this.sessionCheck,
    this.configSetup,
  });

  @override
  ConsumerState<ClientGate> createState() => _ClientGateState();
}

class _ClientGateState extends ConsumerState<ClientGate> {
  static const _loginRequiredMessage = 'client login required';
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _codeController = TextEditingController();
  bool? _hasSession;
  bool _submitting = false;
  bool _restoring = false;
  bool _restoreFailed = false;

  @override
  void initState() {
    super.initState();
    ref.listenManual(initProvider, (previous, initialized) {
      if (!initialized || _hasSession != null || _restoring) return;
      _restoring = true;
      unawaited(_loadState());
    }, fireImmediately: true);
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _loadState() async {
    try {
      final hasSession =
          await (widget.sessionCheck?.call() ??
              coreController.clientHasSession());
      if (!hasSession) {
        if (!mounted) return;
        setState(() {
          _hasSession = false;
          _restoreFailed = false;
        });
        return;
      }
      final message = await _setupClientConfig();
      if (!mounted) return;
      final needsLogin = message == _loginRequiredMessage;
      setState(() {
        // A network/config refresh failure does not invalidate the encrypted
        // local session. Enter the app and keep using the last successful cache;
        // only an explicit authentication failure returns to the login form.
        _hasSession = !needsLogin;
        _restoreFailed = false;
      });
      if (message.isNotEmpty && !needsLogin) {
        context.showSnackBar(message);
      }
    } catch (error) {
      commonPrint.log(
        'Client restore failed: ${error.runtimeType}',
        logLevel: LogLevel.warning,
      );
      if (!mounted) return;
      setState(() {
        _restoreFailed = true;
      });
    } finally {
      _restoring = false;
    }
  }

  void _retryRestore() {
    if (_restoring) return;
    setState(() {
      _hasSession = null;
      _restoreFailed = false;
    });
    _restoring = true;
    unawaited(_loadState());
  }

  Future<String> _setupClientConfig() async {
    if (widget.configSetup case final configSetup?) {
      return configSetup();
    }
    return ref.read(setupActionProvider.notifier).setupPrivateClientProfile();
  }

  Future<void> _submit() async {
    if (_submitting) return;
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    if (email.isEmpty || password.isEmpty) {
      final l10n = context.appLocalizations;
      context.showSnackBar('${l10n.account} / ${l10n.password}');
      return;
    }
    setState(() {
      _submitting = true;
    });
    try {
      final message = await coreController.clientLogin(
        endpoint: kClientApiBase,
        email: email,
        password: password,
        code: _codeController.text.trim(),
      );
      if (!mounted) return;
      if (message.isNotEmpty) {
        setState(() {
          _submitting = false;
          _hasSession = false;
        });
        context.showSnackBar(message);
        return;
      }
      final setupMessage = await _setupClientConfig();
      if (!mounted) return;
      final needsLogin = setupMessage == _loginRequiredMessage;
      setState(() {
        _submitting = false;
        _hasSession = !needsLogin;
      });
      if (setupMessage.isNotEmpty && !needsLogin) {
        context.showSnackBar(setupMessage);
      }
    } catch (error) {
      commonPrint.log(
        'Client login setup failed: ${error.runtimeType}',
        logLevel: LogLevel.warning,
      );
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _hasSession = false;
      });
      context.showSnackBar(context.appLocalizations.unknownNetworkError);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_hasSession == true) {
      return widget.child;
    }
    if (_restoreFailed) {
      final l10n = context.appLocalizations;
      return Scaffold(
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(
                    Icons.error_outline,
                    size: 56,
                    color: context.colorScheme.error,
                  ),
                  const SizedBox(height: 24),
                  Text(
                    l10n.restoreException,
                    textAlign: TextAlign.center,
                    style: context.textTheme.titleLarge,
                  ),
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    onPressed: _retryRestore,
                    icon: const Icon(Icons.refresh),
                    label: Text(l10n.restore),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }
    if (_hasSession == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final l10n = context.appLocalizations;
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(Icons.shield_outlined, size: 56),
                const SizedBox(height: 24),
                Text(
                  appName,
                  textAlign: TextAlign.center,
                  style: context.textTheme.headlineMedium,
                ),
                const SizedBox(height: 24),
                TextField(
                  controller: _emailController,
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.username],
                  decoration: InputDecoration(labelText: l10n.account),
                  onSubmitted: (_) => _submit(),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _passwordController,
                  obscureText: true,
                  autofillHints: const [AutofillHints.password],
                  decoration: InputDecoration(labelText: l10n.password),
                  onSubmitted: (_) => _submit(),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _codeController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: '2FA'),
                  onSubmitted: (_) => _submit(),
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: _submitting ? null : _submit,
                  icon: _submitting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.login),
                  label: Text(l10n.confirm),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
