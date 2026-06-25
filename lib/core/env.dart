// Wealth Ledger — runtime environment & data-source mode (frontend_contract_v1 §14).
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 数据来源模式。默认 realLocal；debugFixture 仅 debug/demo 可用；apiRemote 未来接 VPS。
enum DataSourceMode { realLocal, debugFixture, apiRemote }

/// 单一来源的运行环境。
@immutable
class AppEnvironment {
  const AppEnvironment({required this.dataSourceMode});

  final DataSourceMode dataSourceMode;

  bool get isDemo => dataSourceMode == DataSourceMode.debugFixture;

  /// `--dart-define=DEMO=true` 且仅在 debug 构建下启用 fixture；release 永不进入 fixture。
  factory AppEnvironment.fromBuildConfig() {
    const demo = bool.fromEnvironment('DEMO');
    final useFixture = demo && kDebugMode;
    return AppEnvironment(
      dataSourceMode:
          useFixture ? DataSourceMode.debugFixture : DataSourceMode.realLocal,
    );
  }
}

/// 顶层覆盖点（测试/启动可 override）。
final appEnvironmentProvider =
    Provider<AppEnvironment>((ref) => AppEnvironment.fromBuildConfig());
