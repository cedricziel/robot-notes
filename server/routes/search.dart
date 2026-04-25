import 'dart:async';
import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:server/src/search_index.dart';

/// Default page size when the caller omits `limit`.
const int kDefaultSearchLimit = 20;

/// Hard ceiling on `limit`; larger values clamp here.
const int kMaxSearchLimit = 100;

/// `GET /search?q=<fts>&limit=<n>` — FTS5 full-text search over notes.
///
/// Errors:
///   - `missing_query` (400): `q` is absent
///   - `empty_query`   (400): `q` is whitespace-only
///   - `invalid_query` (400): `q` is not a valid FTS5 expression
///   - `bad_request`   (400): `limit` is not a positive integer
FutureOr<Response> onRequest(RequestContext context) {
  final method = context.request.method;
  if (method != HttpMethod.get) {
    return Response.json(
      statusCode: HttpStatus.methodNotAllowed,
      body: const {'error': 'method_not_allowed'},
    );
  }

  final query = context.request.uri.queryParameters;
  final rawQ = query['q'];
  if (rawQ == null) {
    return Response.json(
      statusCode: HttpStatus.badRequest,
      body: const {'error': 'missing_query'},
    );
  }
  final q = rawQ.trim();
  if (q.isEmpty) {
    return Response.json(
      statusCode: HttpStatus.badRequest,
      body: const {'error': 'empty_query'},
    );
  }

  final rawLimit = query['limit'];
  int parsedLimit;
  if (rawLimit == null) {
    parsedLimit = kDefaultSearchLimit;
  } else {
    final n = int.tryParse(rawLimit);
    if (n == null || n <= 0) {
      return Response.json(
        statusCode: HttpStatus.badRequest,
        body: const {
          'error': 'bad_request',
          'message': 'limit must be a positive integer',
        },
      );
    }
    parsedLimit = n;
  }
  final effectiveLimit = parsedLimit.clamp(1, kMaxSearchLimit);

  final index = context.read<SearchIndex>();
  final List<SearchHit> hits;
  try {
    hits = index.search(q, limit: effectiveLimit);
  } on InvalidSearchQueryException {
    return Response.json(
      statusCode: HttpStatus.badRequest,
      body: const {'error': 'invalid_query'},
    );
  }

  return Response.json(
    body: {
      'items': [
        for (final hit in hits)
          {
            'id': hit.id,
            'title': hit.title,
            'snippet': hit.snippet,
            'rank': hit.rank,
          },
      ],
      'limit': effectiveLimit,
    },
  );
}
