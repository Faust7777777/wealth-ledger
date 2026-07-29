import 'package:finwealth/data/view_models.dart';
import 'package:finwealth/features/agent_providers_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('选中模型不可用时不选择其他 provider', () {
    const models = [
      AgentModelVm(
        id: 'other/model',
        provider: 'other',
        displayName: 'Other',
        supportsImages: false,
      ),
    ];
    expect(agentSelectedModelMissing('xai/grok-4.5', models), isTrue);
    expect(agentSelectedModelMissing(null, models), isFalse);
  });

  test('设备码倒计时在到期后停止', () {
    final now = DateTime.utc(2026, 7, 29, 12);
    expect(agentOAuthCountdown('2026-07-29T12:01:05Z', now), '1:05 后失效');
    expect(agentOAuthCountdown('2026-07-29T11:59:59Z', now), isNull);
  });

  test('模型列表未成功返回时不能判定当前模型缺失', () {
    const selected = 'xai/grok-4.5';
    const model = AgentModelVm(
      id: selected,
      provider: 'xai',
      displayName: 'Grok 4.5',
      supportsImages: true,
    );

    expect(
      agentSelectedModelUnavailable(
        selected,
        const AsyncValue<List<AgentModelVm>>.loading(),
      ),
      isFalse,
    );
    expect(
      agentSelectedModelUnavailable(
        selected,
        AsyncValue<List<AgentModelVm>>.error(
          Exception('offline'),
          StackTrace.empty,
        ),
      ),
      isFalse,
    );
    expect(
      agentSelectedModelUnavailable(selected, const AsyncValue.data([model])),
      isFalse,
    );
    expect(
      agentSelectedModelUnavailable(selected, const AsyncValue.data([])),
      isTrue,
    );
  });

  testWidgets('连接中的 provider 不能再次发起 OAuth', (tester) async {
    const provider = AgentProviderVm(
      id: 'xai',
      displayName: 'Grok',
      authMethods: [AgentProviderAuthMethod.oauth],
      connectionStatus: AgentProviderConnectionStatus.connecting,
    );
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: Scaffold(body: AgentProviderRow(provider: provider)),
        ),
      ),
    );
    expect(find.text('连接中'), findsOneWidget);
    expect(find.text('刷新'), findsOneWidget);
    expect(find.text('连接'), findsNothing);
  });

  testWidgets('非 OAuth provider 不会错误调用 OAuth', (tester) async {
    const provider = AgentProviderVm(
      id: 'future',
      displayName: 'Future',
      authMethods: [AgentProviderAuthMethod.apiKey],
      connectionStatus: AgentProviderConnectionStatus.disconnected,
    );
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: Scaffold(body: AgentProviderRow(provider: provider)),
        ),
      ),
    );
    expect(find.text('暂不支持'), findsOneWidget);
    expect(find.text('连接'), findsNothing);
  });
}
