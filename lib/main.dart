// Wealth Ledger — app entry.
// P0: launches the design-token preview (dev) with a dark/light toggle.
// Real screens (concept: M1 概览) come after P0a OverviewVm wiring (see API_CONTRACT_V1).
import 'package:flutter/material.dart';
import 'theme/app_theme.dart';
import 'dev/tokens_preview.dart';

void main() => runApp(const WealthLedgerApp());

class WealthLedgerApp extends StatefulWidget {
  const WealthLedgerApp({super.key});

  @override
  State<WealthLedgerApp> createState() => _WealthLedgerAppState();
}

class _WealthLedgerAppState extends State<WealthLedgerApp> {
  ThemeMode _mode = ThemeMode.dark;

  void _toggle() => setState(() {
        _mode = _mode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
      });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Wealth Ledger',
      debugShowCheckedModeBanner: false,
      theme: buildLightTheme(),
      darkTheme: buildDarkTheme(),
      themeMode: _mode,
      home: TokensPreview(
        isDark: _mode == ThemeMode.dark,
        onToggleTheme: _toggle,
      ),
    );
  }
}
