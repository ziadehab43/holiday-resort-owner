import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import '../models/owner.dart';
import 'owner_api_client.dart';

class GuestQrException implements Exception {
  const GuestQrException(this.message);
  final String message;
}

class GuestQrResult {
  const GuestQrResult({required this.record, required this.created});
  final QrRecord record;
  final bool created;
}

class GuestDailyAllowance {
  const GuestDailyAllowance({this.limit = 6, required this.reserved});
  final int limit, reserved;
  int get remaining => (limit - reserved).clamp(0, limit);
}

abstract interface class GuestQrBackend {
  Future<QrRecord?> getToday({required Owner unit});
  Future<GuestQrResult> generate({
    required Owner unit,
    required int guestCount,
  });
}

abstract interface class GuestQuotaBackend {
  Stream<GuestDailyAllowance> watchAllowance({required Owner unit});
  Future<void> cancel({required Owner unit, required QrRecord record});
}

class FirebaseGuestQrBackend implements GuestQrBackend, GuestQuotaBackend {
  FirebaseGuestQrBackend({
    FirebaseAuth? auth,
    FirebaseFirestore? firestore,
    OwnerApiClient? api,
  }) : _auth = auth ?? FirebaseAuth.instance,
       _firestore = firestore ?? FirebaseFirestore.instance,
       _api = api ?? OwnerApiClient(auth: auth);
  final FirebaseAuth _auth;
  final FirebaseFirestore _firestore;
  final OwnerApiClient _api;
  static const dailyLimit = 6;
  static bool _timeZonesInitialized = false;

  @override
  Future<QrRecord?> getToday({required Owner unit}) async {
    final records = await _todayRecords(unit);
    return records.isEmpty ? null : records.first;
  }

  @override
  Stream<GuestDailyAllowance> watchAllowance({required Owner unit}) {
    final uid = _authenticatedUid();
    final unitId = _unitId(unit);
    return _firestore
        .collection('qr_codes')
        .where('ownerId', isEqualTo: uid)
        .where('unitId', isEqualTo: unitId)
        .where('type', isEqualTo: 'guest')
        .where('validDate', isEqualTo: egyptDate())
        .snapshots()
        .map((snapshot) {
          final reserved = snapshot.docs
              .fold<int>(0, (total, document) {
                final data = document.data();
                final status = data['status']?.toString();
                if (status != 'active' && status != 'used') return total;
                return total + ((data['guestCount'] as num?)?.toInt() ?? 0);
              })
              .clamp(0, dailyLimit);
          return GuestDailyAllowance(reserved: reserved);
        });
  }

  @override
  Future<GuestQrResult> generate({
    required Owner unit,
    required int guestCount,
  }) async {
    if (guestCount < 1 || guestCount > dailyLimit) {
      throw const GuestQrException(
        'عدد الأفراد غير صالح. اختر عدداً ضمن المتبقي اليوم.',
      );
    }
    _authenticatedUid();
    final unitId = _unitId(unit);
    try {
      final data = await _api.post('/generate-guest-qr', {
        'unitId': unitId,
        'guestCount': guestCount,
      });
      return GuestQrResult(
        record: QrRecord(
          id: data['qrId'] as String,
          ownerId: data['ownerId'] as String?,
          ownerName: unit.name,
          unit: unit.storageKey,
          unitNumber: data['unitNumber']?.toString() ?? unit.apartment,
          type: QrType.guest,
          allowedPersons: (data['guestCount'] as num).toInt(),
          createdAt: _millis(data['createdAt']),
          qrToken: data['qrToken'] as String,
          validDate: data['validDate'] as String,
          expiresAt: _millis(data['expiresAt']),
          isRead: false,
        ),
        created: true,
      );
    } on OwnerApiException catch (error) {
      throw GuestQrException(_callableMessage(error, generating: true));
    }
  }

  @override
  Future<void> cancel({required Owner unit, required QrRecord record}) async {
    if (record.type != QrType.guest || record.unit != unit.storageKey) {
      throw const GuestQrException('لا يمكن إلغاء هذا الكود.');
    }
    _authenticatedUid();
    _unitId(unit);
    try {
      await _api.post('/cancel-guest-qr', {'qrId': record.id});
    } on OwnerApiException catch (error) {
      throw GuestQrException(_callableMessage(error, generating: false));
    }
  }

  String _authenticatedUid() {
    final uid = _auth.currentUser?.uid;
    if (uid == null || uid.isEmpty) {
      throw const GuestQrException('انتهت جلسة الدخول. سجل الدخول مرة أخرى.');
    }
    return uid;
  }

  String _unitId(Owner unit) {
    final id = unit.unitId;
    if (id == null || id.isEmpty) {
      throw const GuestQrException('بيانات الوحدة غير مكتملة.');
    }
    return id;
  }

  static DateTime _millis(Object? value) {
    if (value is! num) {
      throw const GuestQrException('استجابة الخادم غير مكتملة.');
    }
    return DateTime.fromMillisecondsSinceEpoch(value.toInt());
  }

  static String _callableMessage(
    OwnerApiException error, {
    required bool generating,
  }) => switch (error.code) {
    'daily-limit-exceeded' ||
    'resource-exhausted' => 'لا يوجد عدد كافٍ ضمن الحد اليومي للضيوف.',
    'permission-denied' => 'هذه الوحدة غير مرتبطة بحسابك.',
    'failed-precondition' =>
      generating
          ? 'تعذر إنشاء الكود بالحالة الحالية.'
          : 'لا يمكن إلغاء كود مستخدم أو غير نشط.',
    'unauthenticated' => 'انتهت جلسة الدخول. سجل الدخول مرة أخرى.',
    'not-configured' ||
    'backend-not-configured' ||
    'backend-auth-failed' ||
    'auth-unavailable' ||
    'invalid-response' ||
    'network-error' => error.message,
    _ =>
      generating
          ? 'تعذر إنشاء كود الضيافة. تحقق من الإنترنت وحاول مرة أخرى.'
          : 'تعذر إلغاء الكود. تحقق من الإنترنت وحاول مرة أخرى.',
  };

  Future<List<QrRecord>> _todayRecords(Owner unit) async {
    final uid = _authenticatedUid();
    final unitId = _unitId(unit);
    final date = egyptDate();
    try {
      final snapshot = await _firestore
          .collection('qr_codes')
          .where('ownerId', isEqualTo: uid)
          .where('unitId', isEqualTo: unitId)
          .where('type', isEqualTo: 'guest')
          .where('validDate', isEqualTo: date)
          .get(const GetOptions(source: Source.server));
      final records = snapshot.docs.map((doc) => recordFrom(doc, unit)).toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return records;
    } on FirebaseException {
      throw const GuestQrException(
        'تعذر التحقق من أكواد الضيافة. تحقق من الإنترنت وحاول مرة أخرى.',
      );
    }
  }

  static String egyptDate() {
    final now = egyptTime(DateTime.now());
    return '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }

  static tz.TZDateTime egyptTime(DateTime value) {
    if (!_timeZonesInitialized) {
      tz_data.initializeTimeZones();
      _timeZonesInitialized = true;
    }
    return tz.TZDateTime.from(value, tz.getLocation('Africa/Cairo'));
  }

  static QrRecord recordFrom(
    DocumentSnapshot<Map<String, dynamic>> snapshot,
    Owner unit,
  ) {
    final data = snapshot.data();
    if (data == null) {
      throw const GuestQrException('بيانات كود الضيافة غير مكتملة.');
    }
    final status = switch (data['status']?.toString()) {
      'used' => QrStatus.used,
      'cancelled' => QrStatus.cancelled,
      'expired' => QrStatus.expired,
      _ => QrStatus.active,
    };
    DateTime? timestamp(Object? value) =>
        value is Timestamp ? value.toDate() : null;
    return QrRecord(
      id: snapshot.id,
      ownerId: data['ownerId']?.toString(),
      ownerName: unit.name,
      unit: unit.storageKey,
      unitNumber: data['unitNumber']?.toString() ?? unit.apartment,
      type: QrType.guest,
      allowedPersons: (data['guestCount'] as num?)?.toInt() ?? 1,
      createdAt: timestamp(data['createdAt']) ?? DateTime.now(),
      qrToken: data['qrToken']?.toString() ?? '',
      validDate: data['validDate']?.toString(),
      expiresAt: timestamp(data['expiresAt']),
      usedAt: timestamp(data['usedAt']),
      cancelledAt: timestamp(data['cancelledAt']),
      status: status,
      isUsed: status == QrStatus.used,
      isRead: false,
    );
  }
}
