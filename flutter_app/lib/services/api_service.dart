import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../constants.dart';

class ApiService {
  String? _accessToken;

  void setToken(String? token) => _accessToken = token;

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (_accessToken != null) 'Authorization': 'Bearer $_accessToken',
      };

  static const _timeout = Duration(seconds: 15);

  Future<Map<String, dynamic>> get(String path) async {
    final res = await http
        .get(Uri.parse('$kBaseUrl$path'), headers: _headers)
        .timeout(_timeout);
    return _parse(res);
  }

  Future<Map<String, dynamic>> post(
      String path, Map<String, dynamic> body) async {
    final res = await http
        .post(Uri.parse('$kBaseUrl$path'),
            headers: _headers, body: jsonEncode(body))
        .timeout(_timeout);
    return _parse(res);
  }

  Future<Map<String, dynamic>> delete(String path) async {
    final res = await http
        .delete(Uri.parse('$kBaseUrl$path'), headers: _headers)
        .timeout(_timeout);
    return _parse(res);
  }

  Map<String, dynamic> _parse(http.Response res) {
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    if (res.statusCode >= 400) {
      throw ApiException(
        body['message'] as String? ?? 'Request failed',
        res.statusCode,
      );
    }
    return body;
  }
}

class ApiException implements Exception {
  final String message;
  final int statusCode;
  const ApiException(this.message, this.statusCode);
  @override
  String toString() => message;
}
