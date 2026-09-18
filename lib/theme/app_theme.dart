import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const canvasColor = Color(0xfff5f7f9);
const cardColor = Colors.white;
const ink = Color(0xff101828);
const muted = Color(0xff718096);
const brandGreen = Color(0xff2e914f);
const paleGreen = Color(0xffeaf7ee);
const blue = brandGreen;
const fastMotion = Duration(milliseconds: 140);
ThemeData appTheme() => ThemeData(
  useMaterial3: true,
  fontFamily: 'Roboto',
  pageTransitionsTheme: const PageTransitionsTheme(
    builders: {
      TargetPlatform.android: QuickPageTransitions(),
      TargetPlatform.iOS: QuickPageTransitions(),
      TargetPlatform.windows: QuickPageTransitions(),
      TargetPlatform.linux: QuickPageTransitions(),
      TargetPlatform.macOS: QuickPageTransitions(),
    },
  ),
  scaffoldBackgroundColor: canvasColor,
  colorScheme: ColorScheme.fromSeed(
    seedColor: brandGreen,
    surface: canvasColor,
    primary: brandGreen,
    error: const Color(0xffdc2626),
  ),
  fontFamilyFallback: const [
    'Noto Sans CJK SC',
    'Microsoft YaHei',
    'sans-serif',
  ],
  textTheme: const TextTheme(
    bodyMedium: TextStyle(color: muted, fontSize: 14, height: 1.4),
    bodyLarge: TextStyle(color: ink, fontSize: 16, height: 1.4),
    titleMedium: TextStyle(color: ink, fontWeight: FontWeight.w700),
  ),
  appBarTheme: const AppBarTheme(
    backgroundColor: canvasColor,
    surfaceTintColor: Colors.transparent,
    foregroundColor: Colors.black,
    centerTitle: false,
    titleTextStyle: TextStyle(
      fontFamily: 'Roboto',
      fontFamilyFallback: ['Noto Sans CJK SC', 'Microsoft YaHei', 'sans-serif'],
      color: ink,
      fontSize: 18,
      fontWeight: FontWeight.w700,
    ),
    systemOverlayStyle: SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
      systemNavigationBarColor: Colors.white,
      systemNavigationBarIconBrightness: Brightness.dark,
    ),
  ),
  dialogTheme: DialogThemeData(
    backgroundColor: Colors.white,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
  ),
  bottomSheetTheme: const BottomSheetThemeData(
    backgroundColor: canvasColor,
    showDragHandle: true,
  ),
  progressIndicatorTheme: const ProgressIndicatorThemeData(
    color: brandGreen,
    linearTrackColor: Color(0xffe9edf1),
    borderRadius: BorderRadius.all(Radius.circular(8)),
  ),
  listTileTheme: const ListTileThemeData(
    iconColor: muted,
    minVerticalPadding: 12,
  ),
  snackBarTheme: SnackBarThemeData(
    behavior: SnackBarBehavior.floating,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
  ),
  dividerColor: const Color(0xffe5e5e8),
  cardTheme: const CardThemeData(
    color: Colors.white,
    surfaceTintColor: Colors.transparent,
    margin: EdgeInsets.zero,
  ),
  filledButtonTheme: FilledButtonThemeData(
    style: FilledButton.styleFrom(
      backgroundColor: brandGreen,
      foregroundColor: Colors.white,
      disabledBackgroundColor: const Color(0xffe7ebef),
      disabledForegroundColor: muted,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      textStyle: const TextStyle(
        fontFamily: 'Roboto',
        fontFamilyFallback: [
          'Noto Sans CJK SC',
          'Microsoft YaHei',
          'sans-serif',
        ],
        fontWeight: FontWeight.w700,
      ),
    ).copyWith(animationDuration: fastMotion),
  ),
  outlinedButtonTheme: OutlinedButtonThemeData(
    style: OutlinedButton.styleFrom(
      foregroundColor: ink,
      side: const BorderSide(color: Color(0xffdfe4ea)),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ).copyWith(animationDuration: fastMotion),
  ),
  textButtonTheme: TextButtonThemeData(
    style: TextButton.styleFrom().copyWith(animationDuration: fastMotion),
  ),
  iconButtonTheme: IconButtonThemeData(
    style: const ButtonStyle(animationDuration: fastMotion),
  ),
  inputDecorationTheme: InputDecorationTheme(
    filled: true,
    fillColor: const Color(0xfff8fafc),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: const BorderSide(color: Color(0xffd8dee8)),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: const BorderSide(color: Color(0xffd8dee8)),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: const BorderSide(color: brandGreen, width: 1.5),
    ),
  ),
  switchTheme: SwitchThemeData(
    thumbColor: WidgetStateProperty.resolveWith(
      (states) => states.contains(WidgetState.selected) ? Colors.white : muted,
    ),
    trackColor: WidgetStateProperty.resolveWith(
      (states) => states.contains(WidgetState.selected)
          ? brandGreen
          : const Color(0xffd8dee8),
    ),
  ),
);

class QuickPageTransitions extends PageTransitionsBuilder {
  const QuickPageTransitions();
  @override
  Duration get transitionDuration => const Duration(milliseconds: 160);
  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 140);
  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
    );
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween(
          begin: const Offset(.025, 0),
          end: Offset.zero,
        ).animate(curved),
        child: child,
      ),
    );
  }
}
