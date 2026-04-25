/// Constant-time string comparison.
///
/// Iterates the full length of the longer string regardless of where the
/// first mismatch occurs, so an attacker timing the response cannot deduce
/// any shared prefix with the configured key.
///
/// Returns `true` only when both strings have the same length AND every
/// byte matches.
bool constantTimeEquals(String a, String b) {
  final aBytes = a.codeUnits;
  final bBytes = b.codeUnits;
  // Always loop over the same length so the running time depends only on
  // the input length, not on where the first mismatch lives.
  final maxLen = aBytes.length > bBytes.length ? aBytes.length : bBytes.length;
  var diff = aBytes.length ^ bBytes.length;
  for (var i = 0; i < maxLen; i++) {
    final ai = i < aBytes.length ? aBytes[i] : 0;
    final bi = i < bBytes.length ? bBytes[i] : 0;
    diff |= ai ^ bi;
  }
  return diff == 0;
}
