import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:finwealth/core/env.dart';
import 'package:finwealth/data/api_mock_repositories.dart';
import 'package:finwealth/data/auth_repositories.dart';
import 'package:finwealth/data/providers.dart';

void main() {
  test('api_remote is an API-backed production data source', () {
    const environment = AppEnvironment(
      dataSourceMode: DataSourceMode.apiRemote,
      apiBaseUrl: 'https://api.example.com',
    );

    expect(environment.isApiBacked, isTrue);
    expect(environment.isLocalServer, isFalse);
    expect(environment.devBannerLabel, isNull);
  });

  test('api_remote selects HTTP auth and ledger repositories', () {
    final container = ProviderContainer(
      overrides: [
        appEnvironmentProvider.overrideWithValue(
          const AppEnvironment(
            dataSourceMode: DataSourceMode.apiRemote,
            apiBaseUrl: 'https://api.example.com',
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    expect(
      container.read(authRepositoryProvider),
      isA<LocalServerAuthRepository>(),
    );
    expect(
      container.read(accountRepositoryProvider),
      isA<LocalServerAccountRepository>(),
    );
  });
}
