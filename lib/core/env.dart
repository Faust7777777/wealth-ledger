// Wealth Ledger — runtime environment & data-source mode (frontend_contract_v1 §14).
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 数据来源模式。默认 realLocal；debugFixture 仅 debug/demo 可用；apiRemote 未来接 VPS。
enum DataSourceMode { realLocal, debugFixture, apiMock, apiRemote }

/// 单一来源的运行环境。
@immutable
class AppEnvironment {
  const AppEnvironment({
    required this.dataSourceMode,
    this.apiBaseUrl = 'http://127.0.0.1:8790',
    this.apiScenario = '',
  });

  final DataSourceMode dataSourceMode;
  final String apiBaseUrl;
  final String apiScenario; // 仅 dev 联调：空=服务器默认(空态)；可设 'degraded'

  bool get isDemo => dataSourceMode == DataSourceMode.debugFixture;
  bool get isMock => dataSourceMode == DataSourceMode.apiMock;

  /// 非生产数据来源的可见角标：DEMO(fixture) / MOCK(api_mock)；real_local / api_remote 为 null。
  String? get devBannerLabel => switch (dataSourceMode) {
        DataSourceMode.debugFixture => 'DEMO',
        DataSourceMode.apiMock => 'MOCK',
        _ => null,
      };

  /// 模式选择（默认 real_local 空账本）：
  ///  --dart-define=DATA_SOURCE=api_mock   接本地 dev/mock server
  ///  --dart-define=DEMO=true (debug)      隔离 fixture
  ///  --dart-define=API_BASE=http://...    dev server 地址
  factory AppEnvironment.fromBuildConfig() {
    const ds = String.fromEnvironment('DATA_SOURCE');
    const demo = bool.fromEnvironment('DEMO');
    const apiBase =
        String.fromEnvironment('API_BASE', defaultValue: 'http://127.0.0.1:8790');
    const scenario = String.fromEnvironment('API_SCENARIO');
    final DataSourceMode mode;
    if (ds == 'api_mock') {
      mode = DataSourceMode.apiMock;
    } else if (ds == 'debug_fixture' || (demo && kDebugMode)) {
      mode = DataSourceMode.debugFixture;
    } else {
      mode = DataSourceMode.realLocal;
    }
    return AppEnvironment(
      dataSourceMode: mode,
      apiBaseUrl: apiBase,
      apiScenario: scenario,
    );
  }
}

/// 顶层覆盖点（测试/启动可 override）。
final appEnvironmentProvider =
    Provider<AppEnvironment>((ref) => AppEnvironment.fromBuildConfig());
