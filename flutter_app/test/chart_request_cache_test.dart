import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_app/chart_request_cache.dart';
import 'package:flutter_app/main.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('coalesces requests and returns fresh hits synchronously', () async {
    final cache = ChartRequestCache<int>();
    final pending = Completer<int>();
    var calls = 0;
    Future<int> load() { calls++; return pending.future; }
    final first = cache.get('GTCO:1y', load);
    expect(identical(first, cache.get('GTCO:1y', load)), isTrue);
    pending.complete(42);
    expect(await first, 42);
    expect(cache.get('GTCO:1y', load), isA<SynchronousFuture<int>>());
    expect(calls, 1);
  });

  test('expires, evicts least recently used entries and retries errors', () async {
    var now = DateTime.utc(2026, 11, 17);
    final cache = ChartRequestCache<int>(capacity: 2, now: () => now);
    var calls = 0;
    Future<int> load() async => ++calls;
    await cache.get('A', load);
    await cache.get('B', load);
    await cache.get('A', load);
    await cache.get('C', load);
    expect(await cache.get('B', load), 4);
    now = now.add(const Duration(seconds: 30));
    expect(await cache.get('B', load), 5);
    await expectLater(cache.get('error', () async => throw StateError('offline')), throwsStateError);
    expect(await cache.get('error', load), 6);
  });

  test('clearing prevents an old response from replacing a newer one', () async {
    final cache = ChartRequestCache<int>();
    final pending = Completer<int>();
    final old = cache.get('A', () => pending.future);
    cache.clear();
    await cache.get('A', () async => 2);
    pending.complete(1);
    await old;
    expect(await cache.get('A', () async => 3), 2);
  });

  test('API caches by stock, range and access mode; refresh and logout invalidate', () async {
    SharedPreferences.setMockInitialValues({});
    var calls = 0;
    final api = ApiClient('http://localhost', client: MockClient((request) async {
      calls++;
      if (request.url.path.endsWith('/history')) return http.Response('[]', 200);
      return http.Response(jsonEncode({'stock': {'symbol': 'GTCO'}, 'history': []}), 200);
    }));
    await api.stockDetail('GTCO');
    expect(api.stockDetail(' gtco '), isA<SynchronousFuture<StockDetailBundle>>());
    expect(calls, 1);
    await api.stockDetail('GTCO', range: '1m');
    await api.publicStockDetail('GTCO');
    await api.history('GTCO');
    await api.history('GTCO');
    expect(calls, 4);
    marketDataRefreshSignal.value++;
    await api.stockDetail('GTCO');
    expect(calls, 5);
    await api.clearToken();
    await api.stockDetail('GTCO');
    expect(calls, 6);
  });
}
