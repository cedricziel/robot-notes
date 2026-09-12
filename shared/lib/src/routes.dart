/// String constants for the v1 HTTP/WebSocket routes. Server route registration
/// and client URL building both reference these so the two stay in lockstep.
abstract final class Routes {
  static const String healthz = '/healthz';
  static const String notes = '/notes';
  static const String search = '/search';
  static const String ws = '/ws';
  static const String invites = '/invites';
  static const String mcp = '/mcp';
  static const String oauthRegister = '/oauth/register';
  static const String oauthAuthorize = '/oauth/authorize';
  static const String oauthToken = '/oauth/token';
  static const String oauthRevoke = '/oauth/revoke';
  static const String wellKnownProtectedResource =
      '/.well-known/oauth-protected-resource';
  static const String wellKnownProtectedResourceMcp =
      '$wellKnownProtectedResource/mcp';
  static const String wellKnownAuthorizationServer =
      '/.well-known/oauth-authorization-server';

  static String note(String id) => '/notes/$id';
  static String noteLock(String id) => '/notes/$id/lock';

  static String invite(String token) => '/invites/$token';
  static String inviteOnboarding(String token) =>
      '/invites/$token/onboarding.txt';
}
