import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/web_idle_timeout.dart';

void main() {
  late DateTime now;
  late DateTime? stored;
  late WebIdleTimeout idle;
  late int expirations;

  setUp(() {
    now = DateTime.utc(2026, 11, 16);
    stored = now.add(WebIdleTimeout.window);
    expirations = 0;
    idle = WebIdleTimeout(
      deadline: stored!,
      now: () => now,
      readSharedDeadline: () async => stored,
      persist: (value) => stored = value,
      onExpired: () => expirations++,
    );
  });
  tearDown(() => idle.dispose());

  test('continued activity survives multiple original deadlines and persists on hide', () async {
    for (var i = 0; i < 4; i++) {
      now = now.add(const Duration(minutes: 59));
      idle.activity();
      idle.flush();
      expect(stored, now.add(WebIdleTimeout.window));
      await idle.check();
    }
    expect(expirations, 0);
  });

  test('waking or interacting at the idle boundary cannot resurrect the session', () async {
    now = stored!;
    idle.activity();
    await Future<void>.delayed(Duration.zero);
    await idle.check();
    idle.activity();
    expect(stored, now);
    expect(expirations, 1);
  });

  test('an idle tab respects a later shared deadline without extending it on resume', () async {
    now = stored!;
    stored = now.add(const Duration(minutes: 15));
    await idle.check();
    expect(idle.deadline, stored);
    expect(expirations, 0);
    now = stored!;
    await idle.check();
    expect(expirations, 1);
  });
}
