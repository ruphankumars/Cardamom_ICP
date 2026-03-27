import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:dio/dio.dart';
import '../services/auth_provider.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';

class ChangePasswordScreen extends StatefulWidget {
  const ChangePasswordScreen({super.key});

  @override
  State<ChangePasswordScreen> createState() => _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends State<ChangePasswordScreen> {
  final _currentPasswordController = TextEditingController();
  final _newPasswordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void dispose() {
    _currentPasswordController.dispose();
    _newPasswordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  bool _hasMinLength(String password) => password.length >= 8;
  bool _hasUppercase(String password) => password.contains(RegExp(r'[A-Z]'));
  bool _hasLowercase(String password) => password.contains(RegExp(r'[a-z]'));
  bool _hasDigit(String password) => password.contains(RegExp(r'[0-9]'));

  bool _isPasswordValid(String password) {
    return _hasMinLength(password) &&
        _hasUppercase(password) &&
        _hasLowercase(password) &&
        _hasDigit(password);
  }

  Future<void> _handleChangePassword() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final apiService = ApiService();
      await apiService.changePassword(
        _currentPasswordController.text,
        _newPasswordController.text,
      );

      if (!mounted) return;

      final authProvider = context.read<AuthProvider>();
      authProvider.clearMustChangePassword();

      final role = authProvider.role;
      Navigator.of(context).pushReplacementNamed(
        role == 'client' ? '/client_dashboard' : '/admin_dashboard',
      );

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Password changed successfully',
            style: GoogleFonts.manrope(fontWeight: FontWeight.w600),
          ),
          backgroundColor: AppTheme.success,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      );
    } on DioException catch (e) {
      if (!mounted) return;
      final errorData = e.response?.data;
      setState(() {
        _isLoading = false;
        _errorMessage = errorData?['error']?.toString() ??
            errorData?['message']?.toString() ??
            'Failed to change password. Please try again.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = 'An unexpected error occurred: ${e.toString()}';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final isMobile = screenWidth < 600;
    final newPassword = _newPasswordController.text;

    return PopScope(
      canPop: false,
      child: Scaffold(
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
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [AppTheme.titaniumLight, AppTheme.titaniumMid, AppTheme.titaniumDark],
                    ),
                    borderRadius: BorderRadius.circular(isMobile ? 24 : 32),
                    border: Border.all(color: Colors.white.withOpacity(0.3), width: 0.5),
                    boxShadow: [
                      const BoxShadow(
                        color: Colors.white,
                        blurRadius: 6,
                        offset: Offset(-3, -3),
                      ),
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
                        // Icon
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
                              Icons.lock_reset_rounded,
                              size: isMobile ? 36 : 44,
                              color: AppTheme.primary,
                            ),
                          ),
                        ),
                        Text(
                          'CHANGE PASSWORD',
                          style: GoogleFonts.manrope(
                            fontSize: isMobile ? 20 : 24,
                            fontWeight: FontWeight.w900,
                            color: AppTheme.title,
                            letterSpacing: 3,
                          ),
                        ),
                        SizedBox(height: isMobile ? 8 : 12),
                        Text(
                          'You must change your password before continuing',
                          textAlign: TextAlign.center,
                          style: GoogleFonts.manrope(
                            color: AppTheme.primary,
                            fontSize: isMobile ? 12 : 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        SizedBox(height: isMobile ? 24 : 36),
                        // Error message
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
                        // Current password field
                        _buildFieldLabel('CURRENT PASSWORD', isMobile),
                        const SizedBox(height: 8),
                        _buildTitaniumInput(
                          controller: _currentPasswordController,
                          hint: 'Enter current password',
                          isMobile: isMobile,
                          obscureText: true,
                          textInputAction: TextInputAction.next,
                          validator: (value) {
                            if (value == null || value.isEmpty) {
                              return 'Please enter your current password';
                            }
                            return null;
                          },
                        ),
                        SizedBox(height: isMobile ? 16 : 20),
                        // New password field
                        _buildFieldLabel('NEW PASSWORD', isMobile),
                        const SizedBox(height: 8),
                        _buildTitaniumInput(
                          controller: _newPasswordController,
                          hint: 'Enter new password',
                          isMobile: isMobile,
                          obscureText: true,
                          textInputAction: TextInputAction.next,
                          onChanged: (_) => setState(() {}),
                          validator: (value) {
                            if (value == null || value.isEmpty) {
                              return 'Please enter a new password';
                            }
                            if (!_isPasswordValid(value)) {
                              return 'Password does not meet requirements';
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 12),
                        // Password requirements checklist
                        _buildRequirements(newPassword, isMobile),
                        SizedBox(height: isMobile ? 16 : 20),
                        // Confirm password field
                        _buildFieldLabel('CONFIRM PASSWORD', isMobile),
                        const SizedBox(height: 8),
                        _buildTitaniumInput(
                          controller: _confirmPasswordController,
                          hint: 'Re-enter new password',
                          isMobile: isMobile,
                          obscureText: true,
                          textInputAction: TextInputAction.done,
                          onFieldSubmitted: (_) => _handleChangePassword(),
                          validator: (value) {
                            if (value == null || value.isEmpty) {
                              return 'Please confirm your new password';
                            }
                            if (value != _newPasswordController.text) {
                              return 'Passwords do not match';
                            }
                            return null;
                          },
                        ),
                        SizedBox(height: isMobile ? 24 : 32),
                        // Submit button
                        SizedBox(
                          width: double.infinity,
                          height: isMobile ? 52 : 56,
                          child: GestureDetector(
                            onTap: _isLoading ? null : _handleChangePassword,
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
                                        'CHANGE PASSWORD',
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
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFieldLabel(String label, bool isMobile) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Text(
        label,
        style: GoogleFonts.manrope(
          fontSize: 10,
          fontWeight: FontWeight.w800,
          color: AppTheme.primary,
          letterSpacing: 1.5,
        ),
      ),
    );
  }

  Widget _buildRequirements(String password, bool isMobile) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.titaniumDark.withOpacity(0.15),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.titaniumBorder.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildRequirementRow('At least 8 characters', _hasMinLength(password), password.isNotEmpty),
          const SizedBox(height: 4),
          _buildRequirementRow('One uppercase letter', _hasUppercase(password), password.isNotEmpty),
          const SizedBox(height: 4),
          _buildRequirementRow('One lowercase letter', _hasLowercase(password), password.isNotEmpty),
          const SizedBox(height: 4),
          _buildRequirementRow('One digit', _hasDigit(password), password.isNotEmpty),
        ],
      ),
    );
  }

  Widget _buildRequirementRow(String text, bool met, bool hasInput) {
    final Color color;
    final IconData icon;
    if (!hasInput) {
      color = AppTheme.muted;
      icon = Icons.circle_outlined;
    } else if (met) {
      color = AppTheme.success;
      icon = Icons.check_circle;
    } else {
      color = AppTheme.danger;
      icon = Icons.cancel;
    }

    return Row(
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 8),
        Text(
          text,
          style: GoogleFonts.manrope(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: color,
          ),
        ),
      ],
    );
  }

  Widget _buildTitaniumInput({
    required TextEditingController controller,
    required String hint,
    required bool isMobile,
    bool obscureText = false,
    TextInputAction? textInputAction,
    void Function(String)? onFieldSubmitted,
    void Function(String)? onChanged,
    String? Function(String?)? validator,
  }) {
    return Container(
      decoration: BoxDecoration(
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
        obscureText: obscureText,
        textInputAction: textInputAction,
        onFieldSubmitted: onFieldSubmitted,
        onChanged: onChanged,
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
