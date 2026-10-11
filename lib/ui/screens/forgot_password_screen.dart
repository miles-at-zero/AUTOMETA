import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../business/business_api.dart';
import '../../cloud/cloud_session.dart';
import '../../core/theme/design_tokens.dart';
import '../../core/utils/formatters.dart';
import '../widgets/autometa_widgets.dart';

/// Email-based recovery for an Autometa Cloud account.
///
/// The server's request endpoint deliberately returns the same response for
/// known and unknown addresses, and for mail-delivery success or failure. This
/// screen therefore never displays server-supplied delivery/account details.
class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({
    required this.serverUrl,
    this.initialEmail = '',
    this.emailController,
    super.key,
  });

  final String serverUrl;
  final String initialEmail;

  /// Optional shared sign-in controller; keeping it shared preserves edits even
  /// when the user uses the platform back gesture instead of the in-page link.
  final TextEditingController? emailController;

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  static const String _successMessage =
      "If an account exists for that email, you'll receive instructions to reset your password.";

  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  late final TextEditingController _email = widget.emailController ?? TextEditingController(text: widget.initialEmail);
  bool _busy = false;
  bool _submitted = false;
  String? _error;

  @override
  void dispose() {
    if (widget.emailController == null) _email.dispose();
    super.dispose();
  }

  String? _validateEmail(String? raw) {
    final String email = (raw ?? '').trim();
    if (email.isEmpty) return 'Enter your email address.';
    if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]{2,}$').hasMatch(email)) {
      return 'Enter a valid email address.';
    }
    return null;
  }

  Future<void> _submit() async {
    if (_busy || _submitted) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await context.read<CloudSession>().forgotPassword(widget.serverUrl, _email.text.trim());
      if (mounted) setState(() => _submitted = true);
    } on BusinessApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } on CloudException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Couldn\'t request a password reset. Check your connection and try again.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _backToSignIn() => Navigator.of(context).pop(_email.text.trim());

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Forgot password')),
      body: SafeArea(
        child: ListView(
          padding: EdgeInsets.all(AutometaSpacing.page(context)),
          children: <Widget>[
            ResponsiveWidth(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  if (_submitted) ...<Widget>[
                    Panel(
                      borderColor: AutometaColors.success,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          const Icon(Icons.mark_email_read_outlined, color: AutometaColors.success, size: 28),
                          const SizedBox(height: AutometaSpacing.md),
                          Text('Check your email', style: text.titleLarge),
                          const SizedBox(height: AutometaSpacing.sm),
                          Text(_successMessage, key: const Key('forgot.success'), style: text.bodyLarge),
                          const SizedBox(height: AutometaSpacing.md),
                          Text(
                            'Reset-email delivery depends on the Cloud server configuration. Reset links expire after one hour, work once, and signing in again is required on every device.',
                            style: text.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  ] else ...<Widget>[
                    Text('Reset your password', style: text.headlineSmall),
                    const SizedBox(height: AutometaSpacing.sm),
                    Text(
                      'Enter the email address associated with your Autometa Cloud account. We use the same confirmation either way to protect account privacy.',
                      style: text.bodyMedium,
                    ),
                    const SizedBox(height: AutometaSpacing.lg),
                    Form(
                      key: _formKey,
                      child: TextFormField(
                        key: const Key('forgot.email'),
                        controller: _email,
                        enabled: !_busy,
                        keyboardType: TextInputType.emailAddress,
                        textInputAction: TextInputAction.done,
                        autofillHints: const <String>[AutofillHints.email],
                        autocorrect: false,
                        validator: _validateEmail,
                        onFieldSubmitted: (_) => _submit(),
                        decoration: const InputDecoration(
                          labelText: 'Email address',
                          hintText: 'you@example.com',
                          prefixIcon: Icon(Icons.email_outlined),
                        ),
                      ),
                    ),
                    if (_error != null) ...<Widget>[
                      const SizedBox(height: AutometaSpacing.md),
                      Semantics(
                        liveRegion: true,
                        child: Panel(
                          borderColor: AutometaColors.danger,
                          padding: const EdgeInsets.all(AutometaSpacing.md),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              const Icon(Icons.error_outline, color: AutometaColors.danger),
                              const SizedBox(width: AutometaSpacing.sm),
                              Expanded(child: Text(_error!, key: const Key('forgot.error'))),
                            ],
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: AutometaSpacing.lg),
                    PrimaryAction(
                      key: const Key('forgot.submit'),
                      label: 'Send reset instructions',
                      icon: Icons.mark_email_read_outlined,
                      busy: _busy,
                      onPressed: _submit,
                    ),
                    const SizedBox(height: AutometaSpacing.md),
                    Text(
                      'Email delivery is configured by the Cloud server operator. If delivery is unavailable, no email can be sent; this request will still receive a privacy-preserving response.',
                      style: text.bodySmall,
                    ),
                  ],
                  const SizedBox(height: AutometaSpacing.lg),
                  TextButton.icon(
                    key: const Key('forgot.back'),
                    onPressed: _busy ? null : _backToSignIn,
                    icon: const Icon(Icons.arrow_back),
                    label: const Text('Back to Sign In'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
