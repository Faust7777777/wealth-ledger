// Wealth Ledger — entry.
// 默认 real_local 空账本；debug 构建下 --dart-define=DEMO=true 启用隔离 fixture（带 DEMO 角标）。
// dev token 预览仍可经 /dev/tokens 访问。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app/app.dart';

void main() => runApp(const ProviderScope(child: WealthLedgerApp()));
