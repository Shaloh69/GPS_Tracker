import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import '../models/user.dart';
import 'api_service.dart';

class AuthService extends ChangeNotifier {
  final ApiService _api;
  final FlutterSecureStorage _secure = const FlutterSecureStorage();

  User? _user;
  String? _accessToken;
  String? _refreshToken;
  bool _loading = true;

  AuthService(this._api);

  User?   get user         => _user;
  bool    get isAuth       => _user != null;
  bool    get isLoading    => _loading;
  String? get accessToken  => _accessToken;

  // ── Initialise from storage ───────────────────────────────────────────────
  Future<void> init() async {
    try {
      _accessToken  = await _secure.read(key: 'access_token');
      _refreshToken = await _secure.read(key: 'refresh_token');
      if (_accessToken != null) {
        _api.setToken(_accessToken);
        final prefs = await SharedPreferences.getInstance();
        final raw = prefs.getString('user_data');
        if (raw != null) {
          _user = User.fromJson(jsonDecode(raw) as Map<String, dynamic>);
        } else {
          await _fetchMe();
        }
      }
    } catch (_) {
      await _clearSession();
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  // ── Auth actions ──────────────────────────────────────────────────────────
  Future<void> login(String email, String password) async {
    final res = await _api.post('/auth/login', {
      'email': email,
      'password': password,
    });
    await _applySession(res['data'] as Map<String, dynamic>);
  }

  Future<void> register(String email, String password, String? name) async {
    final res = await _api.post('/auth/register', {
      'email': email,
      'password': password,
      if (name?.isNotEmpty == true) 'name': name,
    });
    await _applySession(res['data'] as Map<String, dynamic>);
  }

  Future<void> logout() async {
    try {
      await _api.post('/auth/logout', {
        if (_refreshToken != null) 'refreshToken': _refreshToken,
      });
    } catch (_) {}
    await _clearSession();
    notifyListeners();
  }

  // ── Internals ─────────────────────────────────────────────────────────────
  Future<void> _applySession(Map<String, dynamic> data) async {
    _accessToken  = data['accessToken']  as String;
    _refreshToken = data['refreshToken'] as String?;
    _user = User.fromJson(data['user'] as Map<String, dynamic>);

    _api.setToken(_accessToken);

    await _secure.write(key: 'access_token',  value: _accessToken);
    if (_refreshToken != null) {
      await _secure.write(key: 'refresh_token', value: _refreshToken);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('user_data', jsonEncode({
      'id': _user!.id, 'email': _user!.email,
      'name': _user!.name, 'role': _user!.role,
    }));
    notifyListeners();
  }

  Future<void> _fetchMe() async {
    final res = await _api.get('/auth/me');
    _user = User.fromJson(res['data'] as Map<String, dynamic>);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('user_data', jsonEncode({
      'id': _user!.id, 'email': _user!.email,
      'name': _user!.name, 'role': _user!.role,
    }));
  }

  Future<void> _clearSession() async {
    _user = _accessToken = _refreshToken = null;
    _api.setToken(null);
    await _secure.deleteAll();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('user_data');
  }
}
