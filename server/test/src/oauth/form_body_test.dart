import 'package:dart_frog/dart_frog.dart';
import 'package:server/src/oauth/form_body.dart';
import 'package:test/test.dart';

Request _request(String body, {String? contentType}) => Request.post(
      Uri.parse('http://localhost/oauth/token'),
      headers: contentType == null ? const {} : {'content-type': contentType},
      body: body,
    );

void main() {
  group('parseFormBody', () {
    test('repeated keys: last value wins', () async {
      final form = await parseFormBody(
        _request(
          'a=1&a=2',
          contentType: 'application/x-www-form-urlencoded',
        ),
      );
      expect(form, {'a': '2'});
    });

    test('decodes + as space', () async {
      final form = await parseFormBody(
        _request(
          'name=foo+bar',
          contentType: 'application/x-www-form-urlencoded',
        ),
      );
      expect(form, {'name': 'foo bar'});
    });

    test('percent-decodes values', () async {
      final form = await parseFormBody(
        _request(
          'a=%40b%2Fc',
          contentType: 'application/x-www-form-urlencoded',
        ),
      );
      expect(form, {'a': '@b/c'});
    });

    test('accepts a charset parameter on the content type', () async {
      final form = await parseFormBody(
        _request(
          'a=1',
          contentType: 'application/x-www-form-urlencoded; charset=utf-8',
        ),
      );
      expect(form, {'a': '1'});
    });

    test('rejects a non-form content type', () async {
      expect(
        () => parseFormBody(
          _request('{"a":1}', contentType: 'application/json'),
        ),
        throwsA(isA<UnsupportedFormContentTypeException>()),
      );
    });

    test('rejects a missing content type', () async {
      expect(
        () => parseFormBody(_request('a=1')),
        throwsA(isA<UnsupportedFormContentTypeException>()),
      );
    });
  });
}
