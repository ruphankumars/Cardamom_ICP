import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import '../services/auth_provider.dart';
import '../theme/app_theme.dart';
import 'face_login_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _isLoading = false;
  bool _isFaceLoginLoading = false;
  String? _errorMessage;

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _handleLogin() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    final authProvider = context.read<AuthProvider>();
    final success = await authProvider.login(
      _usernameController.text.trim(),
      _passwordController.text,
    );

    if (!mounted) return;

    if (success) {
      if (authProvider.mustChangePassword) {
        Navigator.of(context).pushReplacementNamed('/change_password');
      } else {
        final role = authProvider.role;
        Navigator.of(context).pushReplacementNamed(
          role == 'client' ? '/client_dashboard' : '/admin_dashboard',
        );
      }
    } else {
      setState(() {
        _isLoading = false;
        // Get the actual error message from AuthProvider
        _errorMessage = authProvider.lastError ?? 'Invalid username or password';
      });
    }
  }

  Future<void> _handleFaceLogin() async {
    if (_isFaceLoginLoading) return;
    setState(() => _isFaceLoginLoading = true);

    try {
      // The FaceLoginScreen handles everything: camera → scan → match → login
      // → navigate to dashboard. If the user presses back, we return here.
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const FaceLoginScreen()),
      );
    } finally {
      if (mounted) setState(() => _isFaceLoginLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final authProvider = Provider.of<AuthProvider>(context);
    final screenWidth = MediaQuery.of(context).size.width;
    final isMobile = screenWidth < 600;
    
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [AppTheme.titaniumLight, AppTheme.titaniumMid],
          ),
        ),
        child: Center(
          child: SingleChildScrollView(
            padding: EdgeInsets.all(isMobile ? 16.0 : 24.0),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: isMobile ? 340 : 420),
              child: Container(
                decoration: BoxDecoration(
                  // Titanium gradient card with bevel shadow
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [AppTheme.titaniumLight, AppTheme.titaniumMid, AppTheme.titaniumDark],
                  ),
                  borderRadius: BorderRadius.circular(isMobile ? 24 : 32),
                  border: Border.all(color: Colors.white.withOpacity(0.3), width: 0.5),
                  boxShadow: [
                    // Bevel shadow - light from top-left
                    const BoxShadow(
                      color: Colors.white,
                      blurRadius: 6,
                      offset: Offset(-3, -3),
                    ),
                    // Dark shadow from bottom-right
                    BoxShadow(
                      color: Colors.black.withOpacity(0.15),
                      blurRadius: 12,
                      offset: const Offset(6, 6),
                    ),
                  ],
                ),
                padding: EdgeInsets.symmetric(
                  horizontal: isMobile ? 24.0 : 40.0,
                  vertical: isMobile ? 32.0 : 56.0,
                ),
                child: Form(
                  key: _formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Logo - machined disc style
                      Container(
                        width: isMobile ? 80 : 100,
                        height: isMobile ? 80 : 100,
                        margin: EdgeInsets.only(bottom: isMobile ? 20 : 32),
                        decoration: BoxDecoration(
                          color: AppTheme.titaniumMid,
                          shape: BoxShape.circle,
                          boxShadow: [
                            const BoxShadow(
                              color: Colors.white70,
                              blurRadius: 4,
                              offset: Offset(-2, -2),
                            ),
                            BoxShadow(
                              color: Colors.black.withOpacity(0.2),
                              blurRadius: 6,
                              offset: const Offset(3, 3),
                            ),
                          ],
                        ),
                        child: Center(
                          child: Icon(
                            Icons.dashboard_rounded,
                            size: isMobile ? 36 : 44,
                            color: AppTheme.primary,
                          ),
                        ),
                      ),
                      Text(
                        'CARDAMOM',
                        style: GoogleFonts.manrope(
                          fontSize: isMobile ? 22 : 28,
                          fontWeight: FontWeight.w900,
                          color: AppTheme.title,
                          letterSpacing: 4,
                        ),
                      ),
                      SizedBox(height: isMobile ? 8 : 12),
                      Text(
                        'Sign in to your account',
                        textAlign: TextAlign.center,
                        style: GoogleFonts.manrope(
                          color: AppTheme.primary,
                          fontSize: isMobile ? 12 : 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      SizedBox(height: isMobile ? 24 : 36),
                      if (_errorMessage != null)
                        Container(
                          padding: const EdgeInsets.all(12),
                          margin: const EdgeInsets.only(bottom: 16),
                          decoration: BoxDecoration(
                            color: AppTheme.danger.withOpacity(0.1),
                            border: Border.all(
                              color: AppTheme.danger.withOpacity(0.3),
                            ),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Icons.error_outline,
                                color: AppTheme.danger,
                                size: 16,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  _errorMessage!,
                                  style: TextStyle(
                                    color: AppTheme.danger,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      // Username field
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'USERNAME',
                            style: GoogleFonts.manrope(
                              fontSize: 10,
                              fontWeight: FontWeight.w800,
                              color: AppTheme.primary,
                              letterSpacing: 1.5,
                            ),
                          ),
                          const SizedBox(height: 8),
                          _buildTitaniumInput(
                            controller: _usernameController,
                            hint: 'Enter your username',
                            isMobile: isMobile,
                            autofocus: true,
                            textInputAction: TextInputAction.next,
                            validator: (value) {
                              if (value == null || value.trim().isEmpty) {
                                return 'Please enter your username';
                              }
                              return null;
                            },
                          ),
                        ],
                      ),
                      SizedBox(height: isMobile ? 16 : 20),
                      // Password field
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'PASSWORD',
                            style: GoogleFonts.manrope(
                              fontSize: 10,
                              fontWeight: FontWeight.w800,
                              color: AppTheme.primary,
                              letterSpacing: 1.5,
                            ),
                          ),
                          const SizedBox(height: 8),
                          _buildTitaniumInput(
                            controller: _passwordController,
                            hint: 'Enter your password',
                            isMobile: isMobile,
                            obscureText: true,
                            textInputAction: TextInputAction.done,
                            onFieldSubmitted: (_) => _handleLogin(),
                            validator: (value) {
                              if (value == null || value.isEmpty) {
                                return 'Please enter your password';
                              }
                              return null;
                            },
                          ),
                        ],
                      ),
                      SizedBox(height: isMobile ? 24 : 32),
                      // Sign In button - machined style
                      SizedBox(
                        width: double.infinity,
                        height: isMobile ? 52 : 56,
                        child: GestureDetector(
                          onTap: _isLoading ? null : _handleLogin,
                          child: Container(
                            decoration: BoxDecoration(
                              color: AppTheme.primary,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: Colors.white.withOpacity(0.2), width: 1),
                              boxShadow: [
                                BoxShadow(
                                  color: AppTheme.primary.withOpacity(0.3),
                                  blurRadius: 12,
                                  offset: const Offset(0, 6),
                                ),
                                const BoxShadow(
                                  color: Colors.white24,
                                  blurRadius: 2,
                                  offset: Offset(-1, -1),
                                ),
                              ],
                            ),
                            child: Center(
                              child: _isLoading
                                  ? const SizedBox(
                                      width: 24,
                                      height: 24,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2.5,
                                        color: Colors.white,
                                      ),
                                    )
                                  : Text(
                                      'SIGN IN',
                                      style: GoogleFonts.manrope(
                                        fontSize: isMobile ? 13 : 14,
                                        fontWeight: FontWeight.w800,
                                        color: Colors.white,
                                        letterSpacing: 2,
                                      ),
                                    ),
                            ),
                          ),
                        ),
                      ),
                      // Face Login button
                      SizedBox(height: isMobile ? 16 : 20),
                        Row(
                          children: [
                            Expanded(child: Divider(color: AppTheme.titaniumBorder.withOpacity(0.5))),
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 12),
                              child: Text(
                                'OR',
                                style: GoogleFonts.manrope(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                  color: AppTheme.muted,
                                  letterSpacing: 1.5,
                                ),
                              ),
                            ),
                            Expanded(child: Divider(color: AppTheme.titaniumBorder.withOpacity(0.5))),
                          ],
                        ),
                        SizedBox(height: isMobile ? 16 : 20),
                        SizedBox(
                          width: double.infinity,
                          height: isMobile ? 52 : 56,
                          child: GestureDetector(
                            onTap: (_isLoading || _isFaceLoginLoading) ? null : _handleFaceLogin,
                            child: Container(
                              decoration: BoxDecoration(
                                color: Colors.white.withOpacity(0.7),
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(color: AppTheme.primary.withOpacity(0.3), width: 1.5),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withOpacity(0.05),
                                    blurRadius: 8,
                                    offset: const Offset(0, 4),
                                  ),
                                ],
                              ),
                              child: Center(
                                child: _isFaceLoginLoading
                                    ? SizedBox(
                                        width: 24,
                                        height: 24,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2.5,
                                          color: AppTheme.primary,
                                        ),
                                      )
                                    : Row(
                                        mainAxisAlignment: MainAxisAlignment.center,
                                        children: [
                                          Icon(Icons.face_retouching_natural, color: AppTheme.primary, size: 20),
                                          const SizedBox(width: 8),
                                          Text(
                                            'SIGN IN WITH FACE',
                                            style: GoogleFonts.manrope(
                                              fontSize: isMobile ? 12 : 13,
                                              fontWeight: FontWeight.w800,
                                              color: AppTheme.primary,
                                              letterSpacing: 1.5,
                                            ),
                                          ),
                                        ],
                                      ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTitaniumInput({
    required TextEditingController controller,
    required String hint,
    required bool isMobile,
    bool obscureText = false,
    bool autofocus = false,
    TextInputAction? textInputAction,
    void Function(String)? onFieldSubmitted,
    String? Function(String?)? validator,
  }) {
    return Container(
      decoration: BoxDecoration(
        // Recessed titanium well for input
        color: AppTheme.titaniumDark.withOpacity(0.3),
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 4,
            offset: const Offset(2, 2),
          ),
          const BoxShadow(
            color: Colors.white54,
            blurRadius: 2,
            offset: Offset(-1, -1),
          ),
        ],
      ),
      child: TextFormField(
        controller: controller,
        autofocus: autofocus,
        obscureText: obscureText,
        textInputAction: textInputAction,
        onFieldSubmitted: onFieldSubmitted,
        style: GoogleFonts.manrope(
          fontSize: isMobile ? 14 : 15,
          color: AppTheme.title,
          fontWeight: FontWeight.w500,
        ),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: GoogleFonts.manrope(
            fontSize: isMobile ? 13 : 14,
            color: AppTheme.primary.withOpacity(0.5),
          ),
          filled: true,
          fillColor: Colors.white.withOpacity(0.6),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(color: AppTheme.titaniumBorder.withOpacity(0.5), width: 1),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(color: AppTheme.primary, width: 1.5),
          ),
          errorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(color: AppTheme.danger, width: 1),
          ),
          focusedErrorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(color: AppTheme.danger, width: 1.5),
          ),
          contentPadding: EdgeInsets.symmetric(
            horizontal: isMobile ? 16 : 20,
            vertical: isMobile ? 16 : 18,
          ),
        ),
        validator: validator,
      ),
    );
  }
}

