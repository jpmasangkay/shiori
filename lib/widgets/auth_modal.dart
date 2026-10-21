import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../services/api_service.dart';
import '../theme.dart';

/// Shows the unified Cloud Sync Login / Registration modal.
void showAuthModal(BuildContext context) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => const _AuthModal(),
  );
}

class _AuthModal extends StatefulWidget {
  const _AuthModal();

  @override
  State<_AuthModal> createState() => _AuthModalState();
}

class _AuthModalState extends State<_AuthModal> {
  bool _isRegister = false;
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _nameController = TextEditingController();
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final email = _emailController.text.trim();
    final pass = _passwordController.text;
    final name = _nameController.text.trim();

    if (email.isEmpty || pass.isEmpty) {
      setState(() => _error = 'Please fill in email and password.');
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
    });

    try {
      if (_isRegister) {
        await ApiService.instance.register(email, pass, displayName: name);
      } else {
        await ApiService.instance.login(email, pass);
      }
      if (mounted) Navigator.pop(context);
    } catch (err) {
      if (mounted) {
        setState(() {
          _error = err.toString().replaceFirst('Exception: ', '');
          _submitting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 16, 20, bottomInset + 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(color: AppColors.read, borderRadius: BorderRadius.circular(2)),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: .15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.cloud_sync_rounded, color: AppColors.primary, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _isRegister ? 'Create Cloud Account' : 'Sign In to Cloud Sync',
                      style: GoogleFonts.inter(fontSize: 17, fontWeight: FontWeight.w700),
                    ),
                    Text(
                      'Bookmarks & reading history are saved in the cloud database. Access them anywhere across devices without manual backups.',
                      style: GoogleFonts.inter(fontSize: 10, color: AppColors.muted, height: 1.3),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          if (_error != null)
            Container(
              padding: const EdgeInsets.all(10),
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: Colors.red.withValues(alpha: .15),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.red.shade400),
              ),
              child: Text(_error!, style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
            ),
          if (_isRegister) ...[
            TextField(
              controller: _nameController,
              decoration: InputDecoration(
                labelText: 'Display Name (optional)',
                filled: true,
                fillColor: AppColors.surfaceHigh,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
              ),
            ),
            const SizedBox(height: 10),
          ],
          TextField(
            controller: _emailController,
            keyboardType: TextInputType.emailAddress,
            decoration: InputDecoration(
              labelText: 'Email Address',
              filled: true,
              fillColor: AppColors.surfaceHigh,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _passwordController,
            obscureText: true,
            decoration: InputDecoration(
              labelText: 'Password',
              filled: true,
              fillColor: AppColors.surfaceHigh,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
            ),
          ),
          const SizedBox(height: 18),
          FilledButton(
            onPressed: _submitting ? null : _submit,
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: AppColors.onPrimary,
              padding: const EdgeInsets.symmetric(vertical: 13),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            child: _submitting
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : Text(
                    _isRegister ? 'Create Account & Sync' : 'Sign In & Sync Now',
                    style: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w600),
                  ),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: () => setState(() {
              _isRegister = !_isRegister;
              _error = null;
            }),
            child: Text(
              _isRegister ? 'Already have an account? Sign In' : "Don't have an account? Create one",
              style: GoogleFonts.inter(fontSize: 12, color: AppColors.primary),
            ),
          ),
        ],
      ),
    );
  }
}
