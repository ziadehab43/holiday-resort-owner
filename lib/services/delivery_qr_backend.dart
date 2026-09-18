import 'package:firebase_auth/firebase_auth.dart';

import '../models/owner.dart';
import 'owner_api_client.dart';

class DeliveryQrException implements Exception {
  const DeliveryQrException(this.message);
  final String message;
}

abstract interface class DeliveryQrBackend {
  Future<QrRecord> generate({
    required Owner unit,
    required String deliveryType,
  });
}

class FirebaseDeliveryQrBackend implements DeliveryQrBackend {
  FirebaseDeliveryQrBackend({FirebaseAuth? auth, OwnerApiClient? api})
    : _auth = auth ?? FirebaseAuth.instance,
      _api = api ?? OwnerApiClient(auth: auth);
  final FirebaseAuth _auth;
  final OwnerApiClient _api;

  @override
  Future<QrRecord> generate({
    required Owner unit,
    required String deliveryType,
  }) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null || uid.isEmpty) {
      throw const DeliveryQrException(
        'انتهت جلسة الدخول. سجل الدخول مرة أخرى.',
      );
    }
    final unitId = unit.unitId;
    if (unitId == null || unitId.isEmpty) {
      throw const DeliveryQrException('بيانات الوحدة غير مكتملة.');
    }
    try {
      final data = await _api.post('/generate-delivery-qr', {
        'unitId': unitId,
        'deliveryType': deliveryType,
      });
      return QrRecord(
        id: data['qrId'] as String,
        ownerId: data['ownerId'] as String?,
        ownerName: unit.name,
        unit: unit.storageKey,
        unitNumber: data['unitNumber']?.toString() ?? unit.apartment,
        type: QrType.delivery,
        allowedPersons: 1,
        createdAt: _millis(data['createdAt']),
        qrToken: data['qrToken'] as String,
        validDate: data['validDate'] as String,
        deliveryType: data['deliveryType']?.toString() ?? deliveryType,
        expiresAt: _millis(data['expiresAt']),
        isRead: false,
      );
    } on OwnerApiException catch (error) {
      final message = switch (error.code) {
        'permission-denied' => 'هذه الوحدة غير مرتبطة بحسابك.',
        'unauthenticated' => 'انتهت جلسة الدخول. سجل الدخول مرة أخرى.',
        _ => 'تعذر إنشاء كود التوصيل. تحقق من الإنترنت وحاول مرة أخرى.',
      };
      throw DeliveryQrException(message);
    }
  }

  static DateTime _millis(Object? value) {
    if (value is! num) {
      throw const DeliveryQrException('استجابة الخادم غير مكتملة.');
    }
    return DateTime.fromMillisecondsSinceEpoch(value.toInt());
  }
}
