import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:mocktail/mocktail.dart';
import 'package:server/src/actor.dart';
import 'package:server/src/actor_middleware.dart';
import 'package:test/test.dart';

class _MockRequestContext extends Mock implements RequestContext {}

class _MockRequest extends Mock implements Request {}

RequestContext _ctx({Map<String, String> headers = const {}}) {
  final ctx = _MockRequestContext();
  final req = _MockRequest();
  when(() => req.method).thenReturn(HttpMethod.get);
  when(() => req.uri).thenReturn(Uri.parse('http://localhost/notes'));
  final lower = {
    for (final entry in headers.entries) entry.key.toLowerCase(): entry.value,
  };
  when(() => req.headers).thenReturn(lower);
  when(() => ctx.request).thenReturn(req);
  // `provide<T>()` must return a fresh context whose `read<T>()` yields the
  // supplied value. Mocktail's default `provide` returns null, so we wire a
  // tiny stub that records the latest provider and routes `read<Actor>()`
  // through it. That mirrors the contract the middleware relies on without
  // booting a full Dart Frog router.
  when(() => ctx.provide<Actor>(any())).thenAnswer((invocation) {
    final create = invocation.positionalArguments.first as Actor Function();
    final value = create();
    when(() => ctx.read<Actor>()).thenReturn(value);
    return ctx;
  });
  return ctx;
}

Future<Actor> _runAndCaptureActor(RequestContext context) async {
  late Actor captured;
  Future<Response> handler(RequestContext c) async {
    captured = c.read<Actor>();
    return Response(body: 'ok');
  }

  final mw = actorIdentity();
  final response = await mw(handler)(context);
  expect(response.statusCode, HttpStatus.ok);
  return captured;
}

void main() {
  group('actorIdentity', () {
    test('uses the X-Actor header value when present', () async {
      final ctx = _ctx(headers: {'X-Actor': 'alice'});
      final actor = await _runAndCaptureActor(ctx);
      expect(actor.name, 'alice');
    });

    test('falls back to "unknown" when X-Actor is absent', () async {
      final ctx = _ctx();
      final actor = await _runAndCaptureActor(ctx);
      expect(actor.name, Actor.unknownName);
      expect(identical(actor, Actor.unknown), isTrue);
    });

    test('falls back to "unknown" when X-Actor is empty', () async {
      final ctx = _ctx(headers: {'X-Actor': ''});
      final actor = await _runAndCaptureActor(ctx);
      expect(actor.name, Actor.unknownName);
    });

    test('trims whitespace around the X-Actor value', () async {
      final ctx = _ctx(headers: {'X-Actor': '  bob  '});
      final actor = await _runAndCaptureActor(ctx);
      expect(actor.name, 'bob');
    });

    test('treats whitespace-only X-Actor as unknown', () async {
      final ctx = _ctx(headers: {'X-Actor': '   '});
      final actor = await _runAndCaptureActor(ctx);
      expect(actor.name, Actor.unknownName);
    });

    test('preserves multi-word display names verbatim', () async {
      final ctx = _ctx(headers: {'X-Actor': "Alice's laptop"});
      final actor = await _runAndCaptureActor(ctx);
      expect(actor.name, "Alice's laptop");
    });
  });

  group('Actor.fromHeader', () {
    test('null → unknown', () {
      expect(identical(Actor.fromHeader(null), Actor.unknown), isTrue);
    });

    test('empty → unknown', () {
      expect(identical(Actor.fromHeader(''), Actor.unknown), isTrue);
    });

    test('non-empty → trimmed name', () {
      expect(Actor.fromHeader(' alice ').name, 'alice');
    });
  });

  group('Actor equality', () {
    test('equal by name', () {
      expect(const Actor('alice'), const Actor('alice'));
    });

    test('different names are not equal', () {
      expect(const Actor('alice') == const Actor('bob'), isFalse);
    });
  });
}
