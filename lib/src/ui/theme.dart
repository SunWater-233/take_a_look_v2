part of '../take_a_look_app.dart';

ThemeData _buildTakeALookTheme() {
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: TalColors.background,
    colorScheme: const ColorScheme.dark(
      primary: TalColors.cyan,
      secondary: TalColors.green,
      surface: TalColors.surface,
      error: TalColors.red,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 36),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        minimumSize: const Size(34, 34),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: TalColors.field,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(7),
        borderSide: const BorderSide(color: TalColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(7),
        borderSide: const BorderSide(color: TalColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(7),
        borderSide: const BorderSide(color: TalColors.cyan),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
    ),
  );
}

Color _phaseColor(ProbeConnectionPhase phase) {
  switch (phase) {
    case ProbeConnectionPhase.disconnected:
      return TalColors.textMuted;
    case ProbeConnectionPhase.connecting:
      return TalColors.amber;
    case ProbeConnectionPhase.connected:
      return TalColors.green;
  }
}

Color _logColor(LogLevel level) {
  switch (level) {
    case LogLevel.info:
      return TalColors.textMuted;
    case LogLevel.success:
      return TalColors.green;
    case LogLevel.warning:
      return TalColors.amber;
    case LogLevel.error:
      return TalColors.red;
  }
}

class TalColors {
  const TalColors._();

  static const background = Color(0xFF0E1114);
  static const topBar = Color(0xFF12171C);
  static const surface = Color(0xFF151B21);
  static const panelHeader = Color(0xFF192029);
  static const header = Color(0xFF111820);
  static const field = Color(0xFF10161C);
  static const plotBackground = Color(0xFF0B0F13);
  static const border = Color(0xFF26313B);
  static const borderSoft = Color(0xFF1F2831);
  static const borderBright = Color(0xFF3B4652);
  static const grid = Color(0xFF1B2630);
  static const text = Color(0xFFE8EAED);
  static const textMuted = Color(0xFF9AA6B2);
  static const cyan = Color(0xFF51C7F8);
  static const green = Color(0xFF7BD88F);
  static const amber = Color(0xFFFFC857);
  static const red = Color(0xFFFF6B8A);
}

class TalText {
  const TalText._();

  static const body = TextStyle(
    color: TalColors.text,
    fontSize: 13,
    letterSpacing: 0,
  );
  static const bodyStrong = TextStyle(
    color: TalColors.text,
    fontSize: 13,
    fontWeight: FontWeight.w600,
    letterSpacing: 0,
  );
  static const muted = TextStyle(
    color: TalColors.textMuted,
    fontSize: 12,
    letterSpacing: 0,
  );
  static const panelTitle = TextStyle(
    color: TalColors.text,
    fontSize: 13,
    fontWeight: FontWeight.w700,
    letterSpacing: 0,
  );
  static const panelTab = TextStyle(
    color: TalColors.textMuted,
    fontSize: 12,
    fontWeight: FontWeight.w600,
    letterSpacing: 0,
  );
  static const panelTabActive = TextStyle(
    color: TalColors.cyan,
    fontSize: 12,
    fontWeight: FontWeight.w700,
    letterSpacing: 0,
  );
  static const pill = TextStyle(
    color: TalColors.text,
    fontSize: 12,
    fontWeight: FontWeight.w600,
    letterSpacing: 0,
  );
  static const code = TextStyle(
    color: TalColors.cyan,
    fontSize: 11,
    fontFeatures: [],
    letterSpacing: 0,
  );
  static const mutedCode = TextStyle(
    color: TalColors.textMuted,
    fontSize: 11,
    fontFeatures: [],
    letterSpacing: 0,
  );
  static const column = TextStyle(
    color: TalColors.textMuted,
    fontSize: 11,
    fontWeight: FontWeight.w700,
    letterSpacing: 0,
  );
  static const value = TextStyle(
    color: TalColors.green,
    fontSize: 13,
    fontWeight: FontWeight.w700,
    letterSpacing: 0,
  );
  static const metric = TextStyle(
    color: TalColors.text,
    fontSize: 14,
    fontWeight: FontWeight.w700,
    letterSpacing: 0,
  );
  static const legend = TextStyle(
    color: TalColors.text,
    fontSize: 11,
    fontWeight: FontWeight.w600,
    letterSpacing: 0,
  );
  static const warning = TextStyle(
    color: TalColors.amber,
    fontSize: 12,
    fontWeight: FontWeight.w700,
    letterSpacing: 0,
  );
  static const log = TextStyle(fontSize: 12, letterSpacing: 0);
}
