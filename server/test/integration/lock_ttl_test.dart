import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:server/src/clock.dart';
import 'package:test/test.dart';

import '_test_app.dart';

class _MutableClock implements Clock {
  _MutableClock(this._now);

  DateTime _now;

  void advance(Duration delta) => _now = _now.add(delta);

  @override
  DateTime nowUtc() => _now.toUtc();
}

/// Locks are TTL-bounded and evicted lazily on the next access. With the
/// integration server wired to a controllable [Clock], we can assert that:
///   1. A lock acquired by alice is reflected in `GET /notes/{id}`.
///   2. After advancing past the configured TTL, the same GET no longer
///      shows the lock and another actor can acquire it.
void main() {
  test('lock disappears after TTL elapses without a heartbeat', () async {
    final clock = _MutableClock(DateTime.utc(2026, 4, 25, 10));
    final app = await TestApp.start(lockTtlSeconds: 30, clock: clock);
    addTearDown(app.close);

    final createRes = await http.post(
      Uri.parse('${app.baseUrl}/notes'),
      headers: app.headers(actor: 'alice'),
      body: jsonEncode({'title': 'x', 'content': ''}),
    );
    expect(createRes.statusCode, 201);
    final id =
        (jsonDecode(createRes.body) as Map<String, dynamic>)['id'] as String;

    // Alice grabs the lock.
    final lockRes = await http.post(
      Uri.parse('${app.baseUrl}/notes/$id/lock'),
      headers: app.headers(actor: 'alice'),
    );
    expect(lockRes.statusCode, 200);

    // GET reflects it.
    final readRes = await http.get(
      Uri.parse('${app.baseUrl}/notes/$id'),
      headers: app.headers(actor: 'alice'),
    );
    final read = jsonDecode(readRes.body) as Map<String, dynamic>;
    expect((read['lock'] as Map)['holder'], 'alice');

    // Bob can't acquire while Alice holds.
    final stolen = await http.post(
      Uri.parse('${app.baseUrl}/notes/$id/lock'),
      headers: app.headers(actor: 'bob'),
    );
    expect(stolen.statusCode, 423);

    // Advance the clock past the TTL.
    clock.advance(const Duration(seconds: 31));

    // GET no longer shows a lock (lazy eviction).
    final readAfterRes = await http.get(
      Uri.parse('${app.baseUrl}/notes/$id'),
      headers: app.headers(actor: 'alice'),
    );
    final readAfter = jsonDecode(readAfterRes.body) as Map<String, dynamic>;
    expect(readAfter['lock'], isNull);

    // Bob can acquire now.
    final bobLock = await http.post(
      Uri.parse('${app.baseUrl}/notes/$id/lock'),
      headers: app.headers(actor: 'bob'),
    );
    expect(bobLock.statusCode, 200, reason: bobLock.body);
    final bobBody = jsonDecode(bobLock.body) as Map<String, dynamic>;
    expect(bobBody['holder'], 'bob');
  });
}
