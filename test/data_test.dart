import 'dart:convert';
import 'dart:typed_data';

import 'package:espobase/espobase.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import 'support.dart';

Matcher _code(String code) =>
    isA<EspobaseException>().having((e) => e.code, 'code', code);

void main() {
  group('query builder', () {
    test('filters, ordering and range become PostgREST parameters', () async {
      final h = Harness((r) => jsonResponse([]));
      await h.client
          .from('orders')
          .select('id,total')
          .eq('status', 'open')
          .neq('kind', 'gift')
          .gt('total', 10)
          .gte('score', 1.5)
          .lt('n', 3)
          .lte('m', 4)
          .like('name', 'a*')
          .ilike('email', '%@x.com')
          .inList('id', [1, 2, 3])
          .inList('tag', ['a,b', 'say "hi"'])
          .isNull('deleted_at')
          .isBool('active', true)
          .order('created_at', ascending: false, nullsFirst: false)
          .range(10, 19);
      final params = h.requests.single.url.queryParametersAll.entries
          .expand((e) => e.value.map((v) => '${e.key}=$v'))
          .toList();
      expect(params, [
        'select=id,total',
        'status=eq.open',
        'kind=neq.gift',
        'total=gt.10',
        'score=gte.1.5',
        'n=lt.3',
        'm=lte.4',
        'name=like.a*',
        'email=ilike.%@x.com',
        'id=in.(1,2,3)',
        r'tag=in.("a,b","say \"hi\"")',
        'deleted_at=is.null',
        'active=is.true',
        'order=created_at.desc.nullslast',
        'offset=10',
        'limit=10',
      ]);
    });

    test('insert sends JSON and asks for no rows unless selected', () async {
      final h = Harness((r) => http201());
      await h.client.from('todos').insert({'title': 'Buy milk'});
      expect(h.requests.single.method, 'POST');
      expect(h.requests.single.headers['prefer'], 'return=minimal');
      expect(bodyOf(h.requests.single), {'title': 'Buy milk'});
      final h2 = Harness((r) => jsonResponse([
            {'id': 1, 'title': 'x'}
          ], 201));
      final rows = await h2.client.from('todos').insert([
        {'title': 'x'}
      ]).select();
      expect(rows, [
        {'id': 1, 'title': 'x'}
      ]);
      expect(h2.requests.single.headers['prefer'], 'return=representation');
      expect(h2.requests.single.headers['content-type'],
          startsWith('application/json'));
    });

    test('update and delete need a filter; nothing is sent without one',
        () async {
      final h = Harness((r) => http204());
      await expectLater(h.client.from('todos').update({'done': true}),
          throwsA(_code('filter_required')));
      await expectLater(
          h.client.from('todos').delete(), throwsA(_code('filter_required')));
      expect(h.requests, isEmpty);
      await h.client.from('todos').update({'done': true}).eq('id', 5);
      await h.client.from('todos').delete().eq('id', 5);
      expect(h.requests.map((r) => r.method), ['PATCH', 'DELETE']);
      expect(h.requests.first.url.queryParameters['id'], 'eq.5');
    });

    test(
        'single asks for one object; bad input is refused before sending; builders are immutable',
        () async {
      final h = Harness((r) => jsonResponse({'id': 3}));
      expect(await h.client.from('todos').select().eq('id', 3).single(),
          {'id': 3});
      expect(h.requests.single.headers['accept'],
          'application/vnd.pgrst.object+json');
      await expectLater(h.client.from('todos').eq('bad\ncolumn', 1),
          throwsA(_code('invalid_query')));
      await expectLater(
          h.client.from('todos').limit(-1), throwsA(_code('invalid_query')));
      await expectLater(
          h.client.from('todos').range(5, 2), throwsA(_code('invalid_query')));
      expect(h.requests.length, 1);
      expect(() => h.client.from(''), throwsA(_code('invalid_table')));
      final base = h.client.from('my table').select();
      final filtered = base.eq('id', 1);
      await base;
      await filtered;
      expect(h.requests[1].url.toString(),
          contains('/rest/v1/my%20table?select=%2A'));
      expect(h.requests[1].url.queryParameters.containsKey('id'), isFalse);
      expect(h.requests[2].url.queryParameters['id'], 'eq.1');
    });
  });

  group('storage', () {
    test('upload sends the bytes with the content type and upsert', () async {
      final h = Harness((r) => jsonResponse({
            'id': 'o1',
            'bucket': 'avatars',
            'path': 'me/pic 1.png',
            'size': 3,
            'sha256': 'a' * 64
          }));
      final out = await h.client.storage.from('avatars').upload(
          'me/pic 1.png', Uint8List.fromList([1, 2, 3]),
          contentType: 'image/png', upsert: true);
      expect(out.size, 3);
      final r = h.requests.single;
      expect(r.url.toString(),
          '$projectUrl/storage/v1/object/avatars/me/pic%201.png');
      expect(r.headers['content-type'], 'image/png');
      expect(r.headers['x-upsert'], 'true');
      expect(r.bodyBytes, [1, 2, 3]);
    });

    test('download, list, remove and bucket names', () async {
      final h = Harness((r) {
        if (r.url.path.contains('/object/list/') || r.method == 'DELETE')
          return jsonResponse([]);
        return http.Response.bytes([9, 9], 200);
      });
      final bucket = h.client.storage.from('docs');
      expect(await bucket.download('a/b.pdf'), [9, 9]);
      await bucket.list(prefix: 'a/', limit: 10);
      expect(bodyOf(h.requests[1]), {'prefix': 'a/', 'limit': 10});
      await bucket.remove(['a/b.pdf']);
      expect(bodyOf(h.requests[2]), {
        'paths': ['a/b.pdf']
      });
      await expectLater(bucket.remove([]), throwsA(_code('invalid_paths')));
      expect(() => h.client.storage.from('Bad Bucket'),
          throwsA(_code('invalid_bucket')));
    });

    test('image transforms change the download route and the links', () async {
      final h = Harness((r) => r.url.path.contains('/object/sign/')
          ? jsonResponse({
              'signedUrl':
                  '$projectUrl/storage/v1/object/sign/photos/a.jpg?token=T'
            })
          : http.Response.bytes([1], 200));
      final photos = h.client.storage.from('photos');
      await photos.download('a.jpg',
          transform: const ImageTransform(
              width: 200,
              height: 100,
              resize: 'contain',
              quality: 70,
              format: 'webp'));
      expect(h.requests[0].url.path,
          '/project/abcde12345/storage/v1/render/image/authenticated/photos/a.jpg');
      expect(h.requests[0].url.queryParameters, {
        'width': '200',
        'height': '100',
        'resize': 'contain',
        'quality': '70',
        'format': 'webp'
      });
      final signed = await photos.createSignedUrl('a.jpg', 600,
          transform: const ImageTransform(width: 64));
      expect(signed.path,
          '/project/abcde12345/storage/v1/render/image/sign/photos/a.jpg');
      expect(signed.queryParameters, {'token': 'T', 'width': '64'});
      expect(photos.getPublicUrl('a b.jpg').toString(),
          '$projectUrl/storage/v1/object/public/photos/a%20b.jpg');
      expect(
          photos
              .getPublicUrl('a.jpg', transform: const ImageTransform(width: 50))
              .path,
          '/project/abcde12345/storage/v1/render/image/public/photos/a.jpg');
      expect(h.requests.length, 2,
          reason: 'building a public URL makes no request');
    });
  });

  group('functions', () {
    test('send JSON and return the parsed answer; errors throw', () async {
      final h = Harness((r) => r.url.path.endsWith('/boom')
          ? jsonResponse(
              {'error': 'function_error', 'message': 'it broke'}, 500)
          : jsonResponse({'message': 'Hello'}));
      final response = await h.client.functions
          .invoke('hello', body: {'name': 'Ada'}, query: {'x': '1'});
      expect(response.data, {'message': 'Hello'});
      expect(response.status, 200);
      final r = h.requests.single;
      expect(r.url.path, '/project/abcde12345/functions/v1/hello');
      expect(r.url.queryParameters, {'x': '1'});
      expect(bodyOf(r), {'name': 'Ada'});
      await expectLater(
          h.client.functions.invoke('boom'),
          throwsA(isA<EspobaseException>()
              .having((e) => e.status, 'status', 500)
              .having((e) => e.code, 'code', 'function_error')));
      await expectLater(h.client.functions.invoke('Bad Name'),
          throwsA(_code('invalid_function')));
      await h.client.functions
          .invoke('hello', body: 'hi', headers: {'Content-Type': 'text/csv'});
      expect(h.requests.last.headers['content-type'], 'text/csv');
      expect(utf8.decode(h.requests.last.bodyBytes), 'hi');
    });
  });
}

http.Response http201() => http.Response('', 201);
http.Response http204() => http.Response('', 204);
