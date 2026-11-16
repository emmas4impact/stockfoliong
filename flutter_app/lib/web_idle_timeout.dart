import 'dart:async';

/// Wall-clock checks also cover browsers that suspend timers in hidden tabs.
class WebIdleTimeout {
  WebIdleTimeout({
    required this.deadline,
    required this.readSharedDeadline,
    required this.persist,
    required this.onExpired,
    this.now = DateTime.now,
  }) {
    _schedule();
  }

  static const window = Duration(hours: 1);
  DateTime deadline;
  final DateTime Function() now;
  final Future<DateTime?> Function() readSharedDeadline;
  final void Function(DateTime) persist;
  final void Function() onExpired;
  Timer? _timer;
  Timer? _pendingWrite;
  DateTime? _lastWrite;
  DateTime? _activityWhileChecking;
  bool _stopped = false;
  bool _checking = false;

  void activity() {
    if (_stopped) return;
    final time = now();
    if (!time.isBefore(deadline)) {
      _activityWhileChecking = time;
      unawaited(check());
      return;
    }
    _extend(time);
  }

  void _extend(DateTime time) {
    deadline = time.add(window);
    // Coalesce high-frequency pointer events; flush the last event on hide.
    const interval = Duration(seconds: 1);
    if (_lastWrite == null || time.difference(_lastWrite!) >= interval) {
      _pendingWrite?.cancel();
      _pendingWrite = null;
      _lastWrite = time;
      persist(deadline);
    } else {
      _pendingWrite ??= Timer(interval - time.difference(_lastWrite!), flush);
    }
  }

  void flush() {
    if (_pendingWrite == null) return;
    _pendingWrite!.cancel();
    _pendingWrite = null;
    _lastWrite = now();
    persist(deadline);
  }

  void _schedule() {
    _timer?.cancel();
    _timer = Timer(deadline.difference(now()), check);
  }

  Future<void> check() async {
    if (_stopped || _checking) return;
    if (!now().isBefore(deadline)) {
      _checking = true;
      try {
        // An active tab may have renewed the same signed-in session.
        DateTime? shared;
        try {
          shared = await readSharedDeadline();
        } catch (_) {
          // If no valid shared deadline can be confirmed, stay expired.
        }
        if (_stopped) return;
        if (shared == null || !now().isBefore(shared)) {
          dispose();
          onExpired();
          return;
        }
        deadline = shared;
        final activity = _activityWhileChecking;
        if (activity != null && activity.isBefore(shared)) _extend(activity);
      } finally {
        _activityWhileChecking = null;
        _checking = false;
      }
    }
    if (!_stopped) _schedule();
  }

  void dispose() {
    _stopped = true;
    _pendingWrite?.cancel();
    _pendingWrite = null;
    _timer?.cancel();
  }
}
