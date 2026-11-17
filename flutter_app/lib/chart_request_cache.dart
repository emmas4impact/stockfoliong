import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

/// Small, memory-only cache. Expired data and failed requests are never reused.
class ChartRequestCache<T> {
  ChartRequestCache({
    this.ttl = const Duration(seconds: 30),
    this.capacity = 32,
    DateTime Function()? now,
  }) : assert(capacity > 0),
       _now = now ?? DateTime.now;

  final Duration ttl;
  final int capacity;
  final DateTime Function() _now;
  final _values = LinkedHashMap<String, ({DateTime expires, T value})>();
  final _pending = <String, Future<T>>{};

  Future<T> get(String key, Future<T> Function() load) {
    final cached = _values.remove(key);
    if (cached != null && _now().isBefore(cached.expires)) {
      _values[key] = cached;
      return SynchronousFuture(cached.value);
    }
    final pending = _pending[key];
    if (pending != null) return pending;
    final completer = Completer<T>();
    final future = completer.future;
    _pending[key] = future;
    Future<T>.sync(load).then((value) {
      // A clear/new request must not be overwritten by an older response.
      if (identical(_pending[key], future)) {
        _pending.remove(key);
        _values[key] = (expires: _now().add(ttl), value: value);
        while (_values.length > capacity) {
          _values.remove(_values.keys.first);
        }
      }
      completer.complete(value);
    }, onError: (Object error, StackTrace stack) {
      if (identical(_pending[key], future)) _pending.remove(key);
      completer.completeError(error, stack);
    });
    return future;
  }

  void clear() {
    _values.clear();
    _pending.clear();
  }
}
