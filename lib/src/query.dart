import 'dart:async';

import 'auth.dart';
import 'errors.dart';
import 'http.dart';

/// A value a filter can compare a column with: `String`, `num`, `bool`, `DateTime`.
String _text(Object value) =>
    value is DateTime ? value.toUtc().toIso8601String() : '$value';

String _listItem(Object value) {
  if (value is num) return '$value';
  final text = _text(value).replaceAll(r'\', r'\\').replaceAll('"', r'\"');
  return '"$text"';
}

bool _hasControl(String s) =>
    s.isEmpty || s.codeUnits.any((c) => c < 0x20 || c == 0x7f);

enum _Method { get, post, patch, delete }

/// A query on one table or view of the project's REST API. Nothing is sent until you `await` it:
///
/// ```dart
/// final open = await client.from('orders').select('id,total').eq('status', 'open').order('id').limit(10);
/// ```
///
/// Reads give a `List<Map<String, dynamic>>` (`single()`: one `Map`). `update()` and `delete()` refuse to run without at
/// least one filter, so a missing `.eq()` can't change every row by accident (row level security still decides which
/// rows a request may touch). Every method returns a new builder, so a base query can be reused.
class QueryBuilder implements Future<List<Map<String, dynamic>>> {
  QueryBuilder(this._http, this._auth, this._table)
      : _method = _Method.get,
        _params = const [],
        _filters = 0,
        _returnRows = false;

  QueryBuilder._(this._http, this._auth, this._table, this._method, this._body,
      this._params, this._filters, this._returnRows, this._invalid);

  final Http _http;
  final AuthClient _auth;
  final String _table;
  final _Method _method;
  Object? _body;
  final List<MapEntry<String, String>> _params;
  final int _filters;
  final bool _returnRows;
  String? _invalid;

  QueryBuilder _copy({
    _Method? method,
    Object? body,
    List<MapEntry<String, String>>? params,
    int? filters,
    bool? returnRows,
    String? invalid,
  }) =>
      QueryBuilder._(
        _http,
        _auth,
        _table,
        method ?? _method,
        body ?? _body,
        params ?? _params,
        filters ?? _filters,
        returnRows ?? _returnRows,
        invalid ?? _invalid,
      );

  /// Columns to return (PostgREST select syntax, e.g. `id,name,orders(total)`). On writes: return the rows.
  QueryBuilder select([String columns = '*']) => _copy(
      params: [..._params, MapEntry('select', columns)],
      returnRows: _method != _Method.get ? true : null);

  /// Inserts a row (a `Map`) or several (a `List<Map>`).
  QueryBuilder insert(Object values) =>
      _copy(method: _Method.post, body: values);

  QueryBuilder update(Map<String, Object?> values) =>
      _copy(method: _Method.patch, body: values);

  QueryBuilder delete() => _copy(method: _Method.delete);

  QueryBuilder _filter(String column, String op, String value) {
    if (_hasControl(column)) return _copy(invalid: 'Invalid column name.');
    return _copy(
        params: [..._params, MapEntry(column, '$op.$value')],
        filters: _filters + 1);
  }

  QueryBuilder eq(String column, Object value) =>
      _filter(column, 'eq', _text(value));
  QueryBuilder neq(String column, Object value) =>
      _filter(column, 'neq', _text(value));
  QueryBuilder gt(String column, Object value) =>
      _filter(column, 'gt', _text(value));
  QueryBuilder gte(String column, Object value) =>
      _filter(column, 'gte', _text(value));
  QueryBuilder lt(String column, Object value) =>
      _filter(column, 'lt', _text(value));
  QueryBuilder lte(String column, Object value) =>
      _filter(column, 'lte', _text(value));
  QueryBuilder like(String column, String pattern) =>
      _filter(column, 'like', pattern);
  QueryBuilder ilike(String column, String pattern) =>
      _filter(column, 'ilike', pattern);
  QueryBuilder inList(String column, List<Object> values) =>
      _filter(column, 'in', '(${values.map(_listItem).join(',')})');

  /// `isNull(col)` matches NULL; `isBool(col, true)` matches booleans.
  QueryBuilder isNull(String column) => _filter(column, 'is', 'null');
  QueryBuilder isBool(String column, bool value) =>
      _filter(column, 'is', '$value');

  QueryBuilder order(String column, {bool ascending = true, bool? nullsFirst}) {
    if (_hasControl(column)) return _copy(invalid: 'Invalid column name.');
    var v = '$column.${ascending ? 'asc' : 'desc'}';
    if (nullsFirst != null) v += nullsFirst ? '.nullsfirst' : '.nullslast';
    return _copy(params: [..._params, MapEntry('order', v)]);
  }

  QueryBuilder limit(int count) {
    if (count < 0)
      return _copy(invalid: 'limit must be a non-negative integer.');
    return _copy(params: [..._params, MapEntry('limit', '$count')]);
  }

  /// Rows [from] to [to], inclusive and zero-based.
  QueryBuilder range(int from, int to) {
    if (from < 0 || to < from)
      return _copy(invalid: 'range needs 0 ≤ from ≤ to.');
    return _copy(params: [
      ..._params,
      MapEntry('offset', '$from'),
      MapEntry('limit', '${to - from + 1}')
    ]);
  }

  /// Runs the query and returns exactly one row: an error if there are zero or several.
  Future<Map<String, dynamic>> single() async {
    final result = await _send(single: true);
    final decoded = result.json;
    if (decoded is Map<String, dynamic>) return decoded;
    throw EspobaseException.client(
        'decode_error', 'The answer was not a single row.');
  }

  Future<HttpResult> _send({bool single = false}) async {
    final invalid = _invalid;
    if (invalid != null)
      throw EspobaseException.client('invalid_query', invalid);
    if ((_method == _Method.patch || _method == _Method.delete) &&
        _filters == 0) {
      throw EspobaseException.client(
        'filter_required',
        'Add a filter (for example .eq("id", 1)) before ${_method == _Method.patch ? 'update' : 'delete'}().',
      );
    }
    final headers = <String, String>{
      if (_method != _Method.get)
        'prefer': _returnRows ? 'return=representation' : 'return=minimal',
      if (single) 'accept': 'application/vnd.pgrst.object+json',
    };
    return _http.send(
      '/rest/v1/${Uri.encodeComponent(_table)}',
      method: _method.name.toUpperCase(),
      jsonBody: _body,
      token: await _auth.accessToken(),
      repeatedQuery: _params,
      extraHeaders: headers,
    );
  }

  Future<List<Map<String, dynamic>>>? _run;

  Future<List<Map<String, dynamic>>> _execute() async {
    final result = await _send();
    final decoded = result.json;
    if (decoded == null) return const [];
    if (decoded is List<dynamic>)
      return [for (final row in decoded) row as Map<String, dynamic>];
    if (decoded is Map<String, dynamic>) return [decoded];
    throw EspobaseException.client(
        'decode_error', 'The answer was not a list of rows.');
  }

  Future<List<Map<String, dynamic>>> _future() => _run ??= _execute();

  @override
  Stream<List<Map<String, dynamic>>> asStream() => _future().asStream();

  @override
  Future<List<Map<String, dynamic>>> catchError(Function onError,
          {bool Function(Object error)? test}) =>
      _future().catchError(onError, test: test);

  @override
  Future<R> then<R>(
          FutureOr<R> Function(List<Map<String, dynamic>> value) onValue,
          {Function? onError}) =>
      _future().then(onValue, onError: onError);

  @override
  Future<List<Map<String, dynamic>>> timeout(Duration timeLimit,
          {FutureOr<List<Map<String, dynamic>>> Function()? onTimeout}) =>
      _future().timeout(timeLimit, onTimeout: onTimeout);

  @override
  Future<List<Map<String, dynamic>>> whenComplete(
          FutureOr<void> Function() action) =>
      _future().whenComplete(action);
}
