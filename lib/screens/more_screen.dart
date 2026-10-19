import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../services/api_service.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'display_sheet.dart';

class MoreScreen extends StatefulWidget {
  const MoreScreen({super.key});

  @override
  State<MoreScreen> createState() => _MoreScreenState();
}

class _MoreScreenState extends State<MoreScreen> {
  @override
  void initState() {
    super.initState();
    ApiService.instance.addListener(_onApiChange);
    ApiService.instance.checkHealth();
  }

  @override
  void dispose() {
    ApiService.instance.removeListener(_onApiChange);
    super.dispose();
  }

  void _onApiChange() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final api = ApiService.instance;
    final loggedIn = api.isLoggedIn;
    final user = api.currentUser;
    final mongo = api.isMongoConnected;

    return Column(
      children: [
        const AppTopBar(title: 'More', branded: true),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            children: [
              // User Account Card
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppColors.surfaceHigh),
                ),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 26,
                      backgroundColor: loggedIn ? AppColors.active : AppColors.surfaceHigh,
                      child: Icon(
                        loggedIn ? Icons.person_rounded : Icons.person_outline_rounded,
                        color: loggedIn ? AppColors.primary : AppColors.muted,
                        size: 28,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            loggedIn
                                ? (user?.displayName.isNotEmpty == true ? user!.displayName : user!.email)
                                : 'Guest User',
                            style: GoogleFonts.inter(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            loggedIn ? user!.email : 'Sign in to sync your library to MongoDB',
                            style: GoogleFonts.inter(fontSize: 11, color: AppColors.muted),
                          ),
                        ],
                      ),
                    ),
                    FilledButton(
                      onPressed: loggedIn ? _confirmLogout : _showAuthModal,
                      style: FilledButton.styleFrom(
                        backgroundColor: loggedIn ? AppColors.surfaceHigh : AppColors.primary,
                        foregroundColor: loggedIn ? AppColors.text : AppColors.onPrimary,
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      ),
                      child: Text(
                        loggedIn ? 'Sign Out' : 'Sign In',
                        style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 20),

              // Database & Connection Status
              _sectionHeader('DATABASE & CLOUD'),
              _settingTile(
                icon: Icons.storage_rounded,
                title: 'MongoDB Status',
                subtitle: mongo
                    ? 'Connected to database'
                    : 'Disconnected (configure MONGODB_URI in backend/.env)',
                trailing: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: mongo ? Colors.green.withValues(alpha: .2) : Colors.amber.withValues(alpha: .2),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: mongo ? Colors.green : Colors.amber),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: mongo ? Colors.greenAccent : Colors.amberAccent,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        mongo ? 'Connected' : 'Offline',
                        style: GoogleFonts.inter(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: mongo ? Colors.greenAccent : Colors.amberAccent,
                        ),
                      ),
                    ],
                  ),
                ),
                onTap: () => _showMongoInfoDialog(),
              ),
              _settingTile(
                icon: Icons.dns_rounded,
                title: 'Backend API URL',
                subtitle: api.baseUrl,
                onTap: () => _showApiUrlDialog(),
              ),

              const SizedBox(height: 20),

              // Appearance & Display Settings
              _sectionHeader('READER & DISPLAY'),
              _settingTile(
                icon: Icons.dashboard_customize_outlined,
                title: 'Display & Library Settings',
                subtitle: 'Columns, cover badges, and grid display modes',
                onTap: () => showDisplaySheet(context),
              ),

              const SizedBox(height: 20),

              // Source Attribution
              _sectionHeader('CATALOG SOURCE'),
              _settingTile(
                icon: Icons.public_rounded,
                title: 'MangaDex API',
                subtitle: 'Free Manga, Manhwa, and Manhua metadata & pages',
                trailing: const Icon(Icons.check_circle_outline_rounded, color: AppColors.primary, size: 20),
              ),

              const SizedBox(height: 32),
              Center(
                child: Text(
                  'Shiori v1.0.0 • Material 3 Dark',
                  style: GoogleFonts.inter(fontSize: 11, color: AppColors.read),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _sectionHeader(String text) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(
        text,
        style: GoogleFonts.inter(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.2,
          color: AppColors.muted,
        ),
      ),
    );
  }

  Widget _settingTile({
    required IconData icon,
    required String title,
    required String subtitle,
    Widget? trailing,
    VoidCallback? onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: ListTile(
          onTap: onTap,
          leading: Icon(icon, color: AppColors.primary, size: 22),
          title: Text(title, style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w500)),
          subtitle: Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.inter(fontSize: 11, color: AppColors.muted),
          ),
          trailing: trailing ?? (onTap != null ? const Icon(Icons.chevron_right_rounded, color: AppColors.muted) : null),
        ),
      ),
    );
  }

  void _confirmLogout() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Sign Out'),
        content: const Text('Are you sure you want to sign out? Your cloud library remains saved in MongoDB.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              ApiService.instance.logout();
            },
            style: FilledButton.styleFrom(backgroundColor: AppColors.primary),
            child: const Text('Sign Out', style: TextStyle(color: AppColors.onPrimary)),
          ),
        ],
      ),
    );
  }

  void _showAuthModal() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => const _AuthModal(),
    );
  }

  void _showMongoInfoDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Row(
          children: [
            Icon(Icons.storage_rounded, color: AppColors.primary),
            SizedBox(width: 10),
            Text('MongoDB Atlas Setup'),
          ],
        ),
        content: Text(
          'To connect your MongoDB database:\n\n'
          '1. Create a free cluster on MongoDB Atlas.\n'
          '2. Click "Connect" → "Drivers" and copy your connection string.\n'
          '3. Open backend/.env and set:\n'
          '   MONGODB_URI=mongodb+srv://<user>:<password>@cluster.mongodb.net/shiori\n'
          '4. Restart the backend server.\n\n'
          'Public MangaDex search, browsing, and reading work even without database connection.',
          style: GoogleFonts.inter(fontSize: 12, height: 1.5, color: AppColors.text),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Got it')),
        ],
      ),
    );
  }

  void _showApiUrlDialog() {
    final controller = TextEditingController(text: ApiService.instance.baseUrl);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Backend API URL'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Specify the host of your Node.js backend. If testing on Android emulator use http://10.0.2.2:3000/api.',
              style: GoogleFonts.inter(fontSize: 11, color: AppColors.muted),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              style: GoogleFonts.inter(fontSize: 13),
              decoration: InputDecoration(
                filled: true,
                fillColor: AppColors.surfaceHigh,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              ApiService.instance.setBaseUrl(controller.text);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }
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
              width: 32,
              height: 4,
              decoration: BoxDecoration(color: AppColors.read, borderRadius: BorderRadius.circular(2)),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            _isRegister ? 'Create Account' : 'Sign In',
            style: GoogleFonts.inter(fontSize: 18, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(
            'Sync your library, bookmarks, and reading history in MongoDB.',
            style: GoogleFonts.inter(fontSize: 11, color: AppColors.muted),
          ),
          const SizedBox(height: 16),
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
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: _submitting
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : Text(_isRegister ? 'Create Account' : 'Sign In', style: const TextStyle(fontWeight: FontWeight.w700)),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: () => setState(() {
              _isRegister = !_isRegister;
              _error = null;
            }),
            child: Text(
              _isRegister ? 'Already have an account? Sign In' : 'Need an account? Sign Up',
              style: GoogleFonts.inter(fontSize: 12, color: AppColors.primary),
            ),
          ),
        ],
      ),
    );
  }
}
