/// String constants for the v1 HTTP/WebSocket routes. Server route registration
/// and client URL building both reference these so the two stay in lockstep.
abstract final class Routes {
  static const String healthz = '/healthz';
  static const String notes = '/notes';
  static const String search = '/search';
  static const String ws = '/ws';
  static const String invites = '/invites';

  static String note(String id) => '/notes/$id';
  static String noteLock(String id) => '/notes/$id/lock';

  static String invite(String token) => '/invites/$token';
  static String inviteOnboarding(String token) =>
      '/invites/$token/onboarding.txt';
}
