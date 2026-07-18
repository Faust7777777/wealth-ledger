// 防御性/实现边界文案静态扫描（2026-07-18 任务单门禁）：
// 只扫描用户可见层（lib/features、lib/app、lib/shared）的字符串字面量，
// 注释与工程契约不受限。任何被禁短语再次进入可见文案时此测试失败。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 被禁短语：产品边界声明、内部流程/实现说明、工程命名。
const List<String> _banned = [
  '本应用',
  '不代表',
  '不会自动',
  '不自动',
  '不下单',
  '不扣款',
  '不转账',
  '不连券商',
  '不连银行',
  '只生成',
  '确认后才',
  '候选',
  '复核',
  '账本',
  '真实退订',
  '不会猜测',
  '自然月锚点',
  '不改历史',
  '不改动历史',
  '真实 API',
  'MVP',
  'local_server',
  'run_self_use',
  'Rust',
  'atomic group',
  '后端',
];

/// 提取一行代码中的单引号字符串字面量内容（忽略行首注释）。
Iterable<String> _stringLiterals(String line) sync* {
  final trimmed = line.trimLeft();
  if (trimmed.startsWith('//')) return;
  final matches = RegExp(r"'([^']*)'").allMatches(line);
  for (final m in matches) {
    yield m.group(1)!;
  }
}

void main() {
  test('用户可见字符串不含防御性/实现边界文案', () {
    final files = <File>[];
    for (final dir in ['lib/features', 'lib/app', 'lib/shared']) {
      files.addAll(
        Directory(dir)
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart')),
      );
    }
    expect(files, isNotEmpty, reason: '扫描目录应存在 dart 文件');

    final violations = <String>[];
    for (final file in files) {
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        for (final literal in _stringLiterals(lines[i])) {
          for (final phrase in _banned) {
            if (literal.contains(phrase)) {
              violations.add('${file.path}:${i + 1} 含「$phrase」: $literal');
            }
          }
        }
      }
    }
    expect(
      violations,
      isEmpty,
      reason: '可见文案不得声明产品不会做什么或解释内部实现：\n${violations.join('\n')}',
    );
  });
}
