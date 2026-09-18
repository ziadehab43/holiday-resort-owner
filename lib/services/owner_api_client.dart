import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

class OwnerApiException implements Exception {
  const OwnerApiException(this.code, this.message);
  final String code;
  final String message;
}

class OwnerApiClient {
  OwnerApiClient({
    this.auth,
    http.Client? client,
    String? baseUrl,
    this.tokenProvider,
  }) : _client = client ?? http.Client(),
       _baseUrl = baseUrl ?? const String.fromEnvironment('OWNER_API_BASE_URL', defaultValue: 'https://holiday-resort-owner-api.holiday-resort-mrx.workers.dev/');

  final FirebaseAuth? auth;
  final http.Client _client;
  final String _baseUrl;
  final Future<String?> Function()? tokenProvider;

  Future<Map<String, dynamic>> post(
    String path,
    Map<String, Object?> body,
  ) async {
    if (_baseUrl.trim().isEmpty) {
      throw const OwnerApiException(
        'not-configured',
        'خدمة الأكواد غير مهيأة. يرجى تحديث التطبيق أو التواصل مع الإدارة.',
      );
    }
    final base = Uri.tryParse(_baseUrl.trim());
    if (base == null || (!base.isScheme('https') && base.host != 'localhost')) {
      throw const OwnerApiException(
        'not-configured',
        'إعداد خدمة الأكواد غير صالح.',
      );
    }
    final provider = tokenProvider;
    final user = provider == null
        ? (auth ?? FirebaseAuth.instance).currentUser
        : null;
    if (provider == null && user == null) {
      throw const OwnerApiException(
        'unauthenticated',
        'انتهت جلسة الدخول. سجل الدخول مرة أخرى.',
      );
    }
    final token = provider != null
        ? await provider()
        : await user!.getIdToken(true);
    if (token == null || token.isEmpty) {
      throw const OwnerApiException(
        'unauthenticated',
        'تعذر التحقق من جلسة الدخول. سجل الدخول مرة أخرى.',
      );
    }
    try {
      final response = await _client
          .post(
            base.resolve(path),
            headers: {
              'authorization': 'Bearer $token',
              'content-type': 'application/json',
            },
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 25));
      final decoded = jsonDecode(response.body);
      final data = decoded is Map
          ? Map<String, dynamic>.from(decoded)
          : <String, dynamic>{};
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw OwnerApiException(
          data['code']?.toString() ?? 'request-failed',
          data['message']?.toString() ?? 'تعذر تنفيذ الطلب حالياً.',
        );
      }
      return data;
    } on OwnerApiException {
      rethrow;
    } on TimeoutException {
      throw const OwnerApiException('timeout', 'استغرقت الخدمة وقتاً طويلاً. حاول مرة أخرى.');
    } on SocketException {
      throw const OwnerApiException('no-internet', 'لا يوجد اتصال بالإنترنت.');
    } on http.ClientException {
      throw const OwnerApiException('no-internet', 'تعذر الوصول إلى الخدمة. تحقق من الاتصال.');
    } on FormatException {
      throw const OwnerApiException(
        'invalid-response',
        'استجابة خدمة الأكواد غير صالحة.',
      );
    } catch (_) {
      throw const OwnerApiException(
        'network-error',
        'تعذر الاتصال بخدمة الأكواد. تحقق من الإنترنت وحاول مرة أخرى.',
      );
    }
  }
}
