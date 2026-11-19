// The assistant's address lasts 90 days and is renewed in the app, keeping
// the same address (SEC-01, minimal version). No network, no real token.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexo/screens/sync_settings_screen.dart';
import 'package:nexo/sync/mcp_connectors.dart';
import 'package:nexo/sync/supabase_auth.dart';
import 'package:nexo/sync/sync_config.dart';

class _Auth extends SupabaseAuth {
  _Auth() : super(SyncConfig(Uri.parse('https://example.test'), 'pk'));
  @override
  Future<String?> accessToken() async => 'session';
}

void main() {
  final now = DateTime(2026, 11, 20, 10);
  McpConnector until(DateTime? end) =>
      McpConnector('k', 'Claude', null, false, expiresAt: end);

  test('the list says until when, and close to the end how many days', () {
    expect(connectorValidity(until(null), now), isNull,
        reason: 'an older server does not tell');
    expect(connectorValidity(until(DateTime(2027, 2, 18, 10)), now),
        'Vale até 18/02/2027');
    expect(
        connectorValidity(
            until(now.add(const Duration(days: 10, hours: 2))), now),
        'Vence em 10 dias (30/11/2026): renove em ⋮');
    expect(connectorValidity(until(now.add(const Duration(hours: 3))), now),
        'Vence hoje: renove em ⋮');
    expect(connectorValidity(until(now.subtract(const Duration(days: 1))), now),
        'Venceu em 19/11/2026: toque em ⋮ › Renovar');
  });

  test('renewing asks the server for the same connector and reads the new end',
      () async {
    final calls = <(String, Object?)>[];
    final mcp = McpConnectors(
        SyncConfig(Uri.parse('https://example.test'), 'pk'), _Auth(),
        clientFactory: () => MockClient((r) async {
              calls.add((r.url.path, jsonDecode(r.body)));
              if (r.url.path.endsWith('nexo_mcp_connector_status')) {
                return http.Response(
                    jsonEncode([
                      {
                        'id': 'k1',
                        'label': 'Claude',
                        'dataset_id': 'd',
                        'revoked_at': null,
                        'expires_at': '2027-02-18T13:00:00Z',
                      }
                    ]),
                    200);
              }
              return http.Response(
                  jsonEncode(
                      {'id': 'k1', 'expires_at': '2027-02-20T13:00:00Z'}),
                  200);
            }));
    expect((await mcp.list()).single.expiresAt,
        DateTime.parse('2027-02-18T13:00:00Z').toLocal());
    expect(await mcp.renew('k1'),
        DateTime.parse('2027-02-20T13:00:00Z').toLocal());
    expect(calls.last.$1, '/rest/v1/rpc/nexo_mcp_renew_connector');
    expect(calls.last.$2, {'p_id': 'k1'});
  });
}
