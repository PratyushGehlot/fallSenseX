import 'package:flutter/material.dart';
import 'package:fall_sense_x_mobile/services/auth_service.dart';
import '../theme/app_theme.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final AuthService _authService = AuthService();
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isLogin = true;
  bool _isLoading = false;
  bool _obscurePassword = true;

  Future<void> _handleSubmit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _isLoading = true);
    try {
      if (_isLogin) {
        await _authService.signIn(
          _emailController.text.trim(),
          _passwordController.text,
        );
      } else {
        await _authService.register(
          _emailController.text.trim(),
          _passwordController.text,
          _emailController.text.split('@')[0],
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString())),
        );
      }
    }
    if (mounted) setState(() => _isLoading = false);
  }

  Future<void> _handleForgotPassword() async {
    final email = _emailController.text.trim();
    if (email.isEmpty || !email.contains('@')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter your email address above first')),
      );
      return;
    }
    try {
      await _authService.sendPasswordReset(email);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Password reset email sent to $email')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Future<void> _handleGoogleSignIn() async {
    setState(() => _isLoading = true);
    try {
      await _authService.signInWithGoogle();
    } catch (e) {
      if (e != 'cancelled' && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
    if (mounted) setState(() => _isLoading = false);
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: SingleChildScrollView(
          child: Column(
            children: [
              // login_header.png (device photo + logo + tagline + "Welcome
              // Back" heading, cropped down to just that content) is shown
              // full-bleed with no side padding - the image's own edges are
              // a soft lavender-to-white gradient that almost exactly
              // matches AppColors.background, so as long as nothing sits
              // beside it (no gutter) there's no visible seam. It bakes in
              // the "Welcome Back / Sign in to monitor..." copy, so in
              // Create Account mode we add a small override line below
              // instead of re-rendering that text twice.
              Image.asset('assets/images/login_header.png', width: double.infinity, fit: BoxFit.fitWidth),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
                // The shared theme fills text fields with AppColors.card
                // (white) and draws no border - barely visible against
                // this page's near-white background, so this page alone
                // gets a slightly stronger outline to keep fields readable.
                child: Theme(
                  data: Theme.of(context).copyWith(
                    inputDecorationTheme: Theme.of(context).inputDecorationTheme.copyWith(
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: const BorderSide(color: Color(0xFFE0E4EA)),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: const BorderSide(color: Color(0xFFE0E4EA)),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: const BorderSide(color: AppColors.accent, width: 1.5),
                          ),
                        ),
                  ),
                  child: _buildForm(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildForm() {
    return Form(
      key: _formKey,
      child: Column(
        children: [
          if (!_isLogin) ...[
            const Text(
              'Create Account',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: AppColors.textPrimary),
            ),
            const SizedBox(height: 10),
          ],
          TextFormField(
            controller: _emailController,
            decoration: const InputDecoration(
              labelText: 'Email Address',
              prefixIcon: Icon(Icons.mail_outline),
            ),
            validator: (v) => v!.contains('@') ? null : 'Invalid email',
          ),
          const SizedBox(height: 10),
          TextFormField(
            controller: _passwordController,
            obscureText: _obscurePassword,
            decoration: InputDecoration(
              labelText: 'Password',
              prefixIcon: const Icon(Icons.lock_outline),
              suffixIcon: IconButton(
                icon: Icon(_obscurePassword ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
              ),
            ),
            validator: (v) => v!.length >= 6 ? null : 'Min 6 characters',
          ),
          if (_isLogin)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: _handleForgotPassword,
                style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(0, 28)),
                child: const Text('Forgot password?', style: TextStyle(fontSize: 12)),
              ),
            ),
          const SizedBox(height: 8),
          _isLoading
              ? const Padding(padding: EdgeInsets.symmetric(vertical: 6), child: CircularProgressIndicator())
              : SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _handleSubmit,
                    child: Text(_isLogin ? 'Sign In' : 'Create Account'),
                  ),
                ),
          const SizedBox(height: 10),
          Row(
            children: [
              const Expanded(child: Divider()),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text('or continue with', style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
              ),
              const Expanded(child: Divider()),
            ],
          ),
          const SizedBox(height: 10),
          // Built from the official Google "G" mark (signin-assets) inside
          // a button styled identically to the Sign In button above
          // (same padding/shape from the shared theme) so the two are the
          // same size - the bundled Google brand button image itself is a
          // fixed wide aspect ratio that can't match a full-width 48px
          // button without distorting it, so the logo glyph is composed
          // into our own button instead of rendering that asset directly.
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: _isLoading ? null : _handleGoogleSignIn,
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                side: const BorderSide(color: Color(0xFFE0E4EA)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Image.asset('assets/images/google_icon.png', width: 20, height: 20),
                  const SizedBox(width: 10),
                  Text(
                    _isLogin ? 'Sign in with Google' : 'Sign up with Google',
                    style: const TextStyle(fontWeight: FontWeight.w500, color: AppColors.textPrimary),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          TextButton(
            onPressed: () => setState(() => _isLogin = !_isLogin),
            style: TextButton.styleFrom(minimumSize: const Size(0, 28)),
            child: Text(
              _isLogin ? 'New to FallSense? Create an account' : 'Have an account? Sign In',
              style: const TextStyle(fontSize: 13),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: const [
              _TrustBadge(icon: Icons.bolt_outlined, label: 'AI-Powered'),
              _TrustBadge(icon: Icons.lock_outline, label: 'Privacy First'),
              _TrustBadge(icon: Icons.shield_outlined, label: '24/7 Protection'),
            ],
          ),
        ],
      ),
    );
  }
}

class _TrustBadge extends StatelessWidget {
  final IconData icon;
  final String label;
  const _TrustBadge({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        CircleAvatar(
          radius: 14,
          backgroundColor: AppColors.accentLight,
          child: Icon(icon, size: 14, color: AppColors.accent),
        ),
        const SizedBox(height: 3),
        Text(label, style: const TextStyle(fontSize: 10, color: AppColors.textSecondary)),
      ],
    );
  }
}
