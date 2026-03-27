import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'dart:ui';
import 'package:google_fonts/google_fonts.dart';

class AppTheme {
  static const Color primary = Color(0xFF5D6E7E); // Matte Titanium Steel Blue
  static const Color secondary = Color(0xFF4F6EF7); // Ref 2: Titanium Accent
  static const Color titaniumLight = Color(0xFFE3E3DE);
  static const Color titaniumMid = Color(0xFFD1D1CB);
  static const Color titaniumDark = Color(0xFFA8A8A1);
  static const Color titaniumBorder = Color(0xFFC4C4BC);
  static const Color steelBlue = Color(0xFF2C3A5A);
  
  static const Color success = Color(0xFF078838); // Ref 1 Green
  static const Color danger = Color(0xFFE73908); // Ref 1 Orange/Red
  static const Color title = Color(0xFF131416);
  static const Color muted = Color(0xFF5D6E7E);
  static const Color bluishWhite = Color(0xFFF0F7FF); // Legacy support
  static const Color warning = Color(0xFFF59E0B); // Legacy support
  static const Color accent = Color(0xFF3B82F6); // Legacy support

  // Status Badge Colors (Exact Parity)
  static const Color statusOpen = Color(0xFF3B82F6);
  static const Color statusAdminSent = Color(0xFFF97316);
  static const Color statusClientDraft = Color(0xFFEAB308);
  static const Color statusClientSent = Color(0xFFA855F7);
  static const Color statusConfirmed = Color(0xFF10B981);
  static const Color statusCancelled = Color(0xFFEF4444);
  static const Color statusConverted = Color(0xFF6B7280);
  static const Color statusAdminDraft = Color(0xFF6366F1);
  
  // Titanium Background Gradient - primary app background
  static const LinearGradient backgroundGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [titaniumLight, titaniumMid],
  );

  // Legacy gradient for gradual migration
  static const LinearGradient legacyBackgroundGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [
      Color(0xFFEEF2FF),
      Color(0xFFF8FAFC),
      Color(0xFFF1F5F9),
    ],
    stops: [0.0, 0.6, 1.0],
  );

  static final BoxDecoration titaniumGradient = BoxDecoration(
    gradient: const LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [titaniumLight, titaniumMid, titaniumDark],
    ),
    borderRadius: BorderRadius.circular(24),
    border: Border.all(color: Colors.white.withOpacity(0.3), width: 0.5),
  );

  static final BoxDecoration machinedDecoration = BoxDecoration(
    color: titaniumMid,
    borderRadius: BorderRadius.circular(fullRadius),
    boxShadow: [
      const BoxShadow(
        color: Colors.white70,
        blurRadius: 2,
        offset: Offset(-1, -1),
      ),
      BoxShadow(
        color: Colors.black.withOpacity(0.15),
        blurRadius: 4,
        offset: const Offset(2, 2),
      ),
    ],
  );

  static final BoxDecoration bevelDecoration = BoxDecoration(
    color: titaniumLight,
    borderRadius: BorderRadius.circular(24),
    boxShadow: [
      const BoxShadow(
        color: Colors.white,
        blurRadius: 4,
        offset: Offset(-2, -2),
      ),
      BoxShadow(
        color: Colors.black.withOpacity(0.1),
        blurRadius: 4,
        offset: const Offset(2, 2),
      ),
    ],
  );

  static const double fullRadius = 9999.0;

  static final BoxDecoration glassDecoration = BoxDecoration(
    color: Colors.white.withOpacity(0.1),
    borderRadius: BorderRadius.circular(24),
    border: Border.all(color: Colors.white.withOpacity(0.2), width: 1),
    boxShadow: [
      BoxShadow(
        color: Colors.black.withOpacity(0.05),
        blurRadius: 32,
        offset: const Offset(0, 8),
      ),
    ],
  );

  // Titanium Well - dark recessed panel (for calendar strips, dark sections)
  static final BoxDecoration titaniumWellDecoration = BoxDecoration(
    color: titaniumDark,
    borderRadius: BorderRadius.circular(24),
  );

  // Matte Glass - translucent overlay on titanium backgrounds
  static final BoxDecoration matteGlassDecoration = BoxDecoration(
    color: Colors.white.withOpacity(0.15),
    borderRadius: BorderRadius.circular(24),
    border: Border.all(color: Colors.white.withOpacity(0.2), width: 1),
  );

  // Floating Shadow - for bottom nav, FABs
  static final List<BoxShadow> floatingShadow = [
    BoxShadow(
      color: Colors.black.withOpacity(0.1),
      blurRadius: 25,
      offset: const Offset(0, 10),
      spreadRadius: -5,
    ),
    BoxShadow(
      color: Colors.black.withOpacity(0.1),
      blurRadius: 10,
      offset: const Offset(0, 8),
      spreadRadius: -6,
    ),
  ];

  // Titanium Card - elevated card with bevel shadow
  static final BoxDecoration titaniumCardDecoration = BoxDecoration(
    gradient: const LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [titaniumLight, titaniumMid, titaniumDark],
    ),
    borderRadius: BorderRadius.circular(24),
    border: Border.all(color: Colors.white.withOpacity(0.3), width: 0.5),
    boxShadow: [
      const BoxShadow(
        color: Colors.white,
        blurRadius: 4,
        offset: Offset(-2, -2),
      ),
      BoxShadow(
        color: Colors.black.withOpacity(0.1),
        blurRadius: 4,
        offset: const Offset(2, 2),
      ),
    ],
  );

  // Extruded Card - stronger shadow for hero cards
  static final BoxDecoration extrudedCardDecoration = BoxDecoration(
    gradient: const LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [titaniumLight, titaniumMid],
    ),
    borderRadius: BorderRadius.circular(24),
    border: Border.all(color: Colors.white.withOpacity(0.3), width: 0.5),
    boxShadow: [
      BoxShadow(
        color: Colors.black.withOpacity(0.15),
        blurRadius: 12,
        offset: const Offset(6, 6),
      ),
      const BoxShadow(
        color: Colors.white,
        blurRadius: 6,
        offset: Offset(-2, -2),
      ),
    ],
  );

  // Recessed Panel - inset appearance
  static final BoxDecoration recessedDecoration = BoxDecoration(
    color: titaniumMid.withOpacity(0.4),
    borderRadius: BorderRadius.circular(24),
    border: Border.all(color: Colors.white.withOpacity(0.2), width: 1),
  );

  static final ThemeData theme = ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: primary,
      primary: primary,
      secondary: secondary,
      error: danger,
      surface: titaniumLight,
      surfaceTint: Colors.transparent,
      ),
      textTheme: GoogleFonts.manropeTextTheme().copyWith(
        displayLarge: GoogleFonts.manrope(
          color: title,
          fontWeight: FontWeight.bold,
          letterSpacing: -0.5,
        ),
        displayMedium: GoogleFonts.outfit(
          color: title,
          fontWeight: FontWeight.bold,
        ),
        displaySmall: GoogleFonts.outfit(
          color: title,
          fontWeight: FontWeight.w600,
        ),
        headlineLarge: GoogleFonts.outfit(
          color: title,
          fontWeight: FontWeight.bold,
        ),
        headlineMedium: GoogleFonts.outfit(
          color: title,
          fontWeight: FontWeight.w600,
        ),
        bodyLarge: GoogleFonts.inter(
          color: title,
        ),
        bodyMedium: GoogleFonts.inter(
          color: title,
        ),
      ),
      cardTheme: CardThemeData(
        color: Colors.white.withOpacity(0.2),
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: const BorderSide(color: Color(0xFFFFFFFF), width: 0.55),
        ),
      ),
      // Safe override for Dropdowns only
      // canvasColor: Colors.white,
      popupMenuTheme: PopupMenuThemeData(
        color: titaniumLight,
        elevation: 8,
        shape: RoundedRectangleBorder(
          borderRadius: const BorderRadius.all(Radius.circular(20)),
          side: BorderSide(color: Colors.white.withOpacity(0.3)),
        ),
      ),
      dialogTheme: const DialogThemeData(
        backgroundColor: titaniumLight,
      ),
      dropdownMenuTheme: DropdownMenuThemeData(
        menuStyle: MenuStyle(
          backgroundColor: WidgetStateProperty.all(bluishWhite),
          shape: WidgetStateProperty.all(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
          ),
        ),
      ),
    listTileTheme: ListTileThemeData(
      selectedTileColor: primary.withOpacity(0.1),
      selectedColor: primary,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white.withOpacity(0.8),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(20),
        borderSide: const BorderSide(color: Color(0xFFD1D5DB)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(20),
        borderSide: const BorderSide(color: Color(0xFFD1D5DB)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(20),
        borderSide: const BorderSide(color: primary, width: 2),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(20),
        borderSide: const BorderSide(color: danger, width: 1),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(20),
        borderSide: const BorderSide(color: danger, width: 2),
      ),
      prefixIconColor: muted,
      suffixIconColor: muted,
      hintStyle: const TextStyle(color: Color(0xFF94A3B8), fontSize: 14),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        elevation: 0,
        backgroundColor: primary,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        textStyle: GoogleFonts.outfit(fontWeight: FontWeight.bold),
      ),
    ),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: ClothPullPageTransitionsBuilder(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.linux: ClothPullPageTransitionsBuilder(),
        TargetPlatform.macOS: ClothPullPageTransitionsBuilder(),
        TargetPlatform.windows: ClothPullPageTransitionsBuilder(),
      },
    ),
  );
}

class LiquidModalTransitionBuilder {
  static Widget build(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curvedAnimation = CurvedAnimation(
      parent: animation,
      curve: Curves.elasticOut,
    );

    return ScaleTransition(
      scale: Tween<double>(begin: 0.8, end: 1.0).animate(curvedAnimation),
      child: FadeTransition(
        opacity: animation,
        child: child,
      ),
    );
  }
}

class ClothPullPageTransitionsBuilder extends PageTransitionsBuilder {
  const ClothPullPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    // Calibrated for "Liquid" feel: 400ms equivalent (standard is 300ms)
    final curvedAnimation = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutQuart, 
    );

    return FadeTransition(
      opacity: curvedAnimation,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0.0, 0.05),
          end: Offset.zero,
        ).animate(curvedAnimation),
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.96, end: 1.0).animate(curvedAnimation),
          child: child,
        ),
      ),
    );
  }
}

class InnerShadow extends StatelessWidget {
  final Widget child;
  final List<BoxShadow> shadows;
  final BorderRadius borderRadius;

  const InnerShadow({
    super.key,
    required this.child,
    required this.shadows,
    this.borderRadius = BorderRadius.zero,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
      ),
      clipBehavior: Clip.antiAlias,
      child: CustomPaint(
        painter: _InnerShadowPainter(shadows, borderRadius),
        child: child,
      ),
    );
  }
}

class _InnerShadowPainter extends CustomPainter {
  final List<BoxShadow> shadows;
  final BorderRadius borderRadius;

  _InnerShadowPainter(this.shadows, this.borderRadius);

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = borderRadius.toRRect(rect);

    for (final shadow in shadows) {
      final shadowRect = rect.inflate(shadow.spreadRadius);
      final shadowRRect = borderRadius.toRRect(shadowRect);

      final path = Path()..addRRect(rrect);
      final shadowPath = Path()
        ..addRect(shadowRect.inflate(shadow.blurRadius))
        ..addRRect(shadowRRect)
        ..fillType = PathFillType.evenOdd;

      canvas.save();
      canvas.clipPath(path);
      
      // Manual shadow for better control
      final paint = Paint()
        ..color = shadow.color
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, shadow.blurRadius);
      
      canvas.drawPath(shadowPath.shift(shadow.offset), paint);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_InnerShadowPainter oldDelegate) => true;
}
