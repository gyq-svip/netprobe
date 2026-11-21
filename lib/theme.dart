import 'package:flutter/material.dart';

import 'core/models.dart';

/// 深色霓虹配色
class AppColors {
  static const bg = Color(0xFF080B11);
  static const surface = Color(0xFF111721);
  static const surfaceAlt = Color(0xFF1A2230);
  static const border = Color(0xFF26313F);

  static const accent = Color(0xFF00E5A0);
  static const accentDim = Color(0xFF00A87A);
  static const blue = Color(0xFF3DA9FC);
  static const purple = Color(0xFF9D7CFF);
  static const warn = Color(0xFFFFB020);
  static const danger = Color(0xFFFF4D5E);

  static const text = Color(0xFFE9EFF7);
  static const textDim = Color(0xFF8798AD);
  static const textFaint = Color(0xFF5A6B80);
}

/// RSSI / 质量 -> 颜色
Color qualityColor(int quality) {
  if (quality >= 80) return AppColors.accent;
  if (quality >= 60) return const Color(0xFF8BE04E);
  if (quality >= 40) return AppColors.warn;
  if (quality >= 20) return const Color(0xFFFF8A3D);
  return AppColors.danger;
}

Color riskColor(RiskLevel level) {
  switch (level) {
    case RiskLevel.info:
      return AppColors.blue;
    case RiskLevel.notice:
      return AppColors.warn;
    case RiskLevel.warning:
      return const Color(0xFFFF8A3D);
    case RiskLevel.danger:
      return AppColors.danger;
  }
}

ThemeData buildTheme() {
  const scheme = ColorScheme.dark(
    primary: AppColors.accent,
    onPrimary: Color(0xFF04170F),
    secondary: AppColors.blue,
    surface: AppColors.surface,
    onSurface: AppColors.text,
    error: AppColors.danger,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.bg,
    canvasColor: AppColors.bg,
    dividerColor: AppColors.border,
    splashFactory: InkSparkle.splashFactory,
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.bg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        color: AppColors.text,
        fontSize: 18,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.3,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.surfaceAlt,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: AppColors.accent, width: 1.4),
      ),
      hintStyle: const TextStyle(color: AppColors.textFaint, fontSize: 13),
    ),
    textTheme: const TextTheme(
      bodyMedium: TextStyle(color: AppColors.text, fontSize: 14),
      bodySmall: TextStyle(color: AppColors.textDim, fontSize: 12),
      titleMedium: TextStyle(color: AppColors.text, fontSize: 15, fontWeight: FontWeight.w600),
    ),
    bottomNavigationBarTheme: const BottomNavigationBarThemeData(
      backgroundColor: AppColors.surface,
      selectedItemColor: AppColors.accent,
      unselectedItemColor: AppColors.textFaint,
      type: BottomNavigationBarType.fixed,
      elevation: 0,
      showUnselectedLabels: true,
      selectedLabelStyle: TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
      unselectedLabelStyle: TextStyle(fontSize: 11),
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: AppColors.surfaceAlt,
      contentTextStyle: TextStyle(color: AppColors.text),
      behavior: SnackBarBehavior.floating,
    ),
  );
}

/// 统一的卡片外壳
class Panel extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  final Color? color;
  final Color? borderColor;
  final Gradient? gradient;
  final VoidCallback? onTap;

  const Panel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(14),
    this.color,
    this.borderColor,
    this.gradient,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final content = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: gradient == null ? (color ?? AppColors.surface) : null,
        gradient: gradient,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: borderColor ?? AppColors.border, width: 1),
      ),
      child: child,
    );
    if (onTap == null) return content;
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: content,
    );
  }
}

/// 小标签
class Chip2 extends StatelessWidget {
  final String text;
  final Color color;

  const Chip2(this.text, {super.key, this.color = AppColors.textDim});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.14),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: color.withOpacity(0.35), width: 0.8),
      ),
      child: Text(
        text,
        style: TextStyle(color: color, fontSize: 10.5, fontWeight: FontWeight.w600, height: 1.25),
      ),
    );
  }
}

/// 区块标题
class SectionTitle extends StatelessWidget {
  final String text;
  final Widget? trailing;

  const SectionTitle(this.text, {super.key, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 18, 2, 10),
      child: Row(
        children: [
          Container(
            width: 3,
            height: 13,
            decoration: BoxDecoration(
              color: AppColors.accent,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            text,
            style: const TextStyle(
              color: AppColors.text,
              fontSize: 13.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
            ),
          ),
          const Spacer(),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}
