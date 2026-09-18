import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../models/owner.dart';

class HistoryException implements Exception {
  const HistoryException(this.message);
  final String message;
}

abstract interface class HistoryBackend {
  Future<List<QrRecord>> loadUnitHistory({required String unitId});
}

abstract interface class HistoryTrackingBackend implements HistoryBackend {
  Stream<List<QrRecord>> watchUnitHistory({required String unitId});
}

class FirebaseHistoryBackend implements HistoryTrackingBackend {
  FirebaseHistoryBackend({FirebaseAuth? auth, FirebaseFirestore? firestore})
    : _auth = auth ?? FirebaseAuth.instance,
      _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseAuth _auth;
  final FirebaseFirestore _firestore;

  @override
  Future<List<QrRecord>> loadUnitHistory({required String unitId}) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null || uid.isEmpty) {
      throw const HistoryException('انتهت جلسة الدخول. سجل الدخول مرة أخرى.');
    }
    try {
      final snapshot = await _firestore
          .collection('qr_codes')
          .where('ownerId', isEqualTo: uid)
          .where('unitId', isEqualTo: unitId)
          .get(const GetOptions(source: Source.server));
      final records =
          snapshot.docs
              .map((document) => _parse(document, uid))
              .whereType<QrRecord>()
              .toList()
            ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return records;
    } on FirebaseException {
      throw const HistoryException(
        'تعذر تحميل السجل. تحقق من الإنترنت وحاول مرة أخرى.',
      );
    }
  }

  @override
  Stream<List<QrRecord>> watchUnitHistory({required String unitId}) {
    final uid = _auth.currentUser?.uid;
    if (uid == null || uid.isEmpty) {
      return Stream.error(
        const HistoryException('انتهت جلسة الدخول. سجل الدخول مرة أخرى.'),
      );
    }
    return _firestore
        .collection('qr_codes')
        .where('ownerId', isEqualTo: uid)
        .where('unitId', isEqualTo: unitId)
        .snapshots()
        .map((snapshot) {
          final records = snapshot.docs
              .map((document) => _parse(document, uid))
              .whereType<QrRecord>()
              .toList()
            ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
          return records;
        });
  }

  static QrRecord? _parse(
    QueryDocumentSnapshot<Map<String, dynamic>> document,
    String ownerId,
  ) {
    final data = document.data().map(
      (key, value) => MapEntry(key.trim(), value),
    );
    final typeValue = data['type']?.toString().trim().toLowerCase();
    final type = switch (typeValue) {
      'guest' => QrType.guest,
      'delivery' => QrType.delivery,
      _ => null,
    };
    if (type == null) return null;

    final countValue = data['guestCount'];
    final count = countValue is num
        ? countValue.toInt()
        : int.tryParse(countValue?.toString() ?? '') ?? 1;
    final createdValue = data['createdAt'];
    final usedValue = data['usedAt'];
    final expiresValue = data['expiresAt'];
    final cancelledValue = data['cancelledAt'];
    final statusValue = data['status']?.toString().trim().toLowerCase();
    final isUsed = statusValue == 'used' || usedValue is Timestamp;
    final status = switch (statusValue) {
      'used' => QrStatus.used,
      'cancelled' => QrStatus.cancelled,
      'expired' => QrStatus.expired,
      _
          when expiresValue is Timestamp &&
              !expiresValue.toDate().isAfter(DateTime.now()) =>
        QrStatus.expired,
      _ => QrStatus.active,
    };

    return QrRecord(
      id: document.id,
      ownerId: ownerId,
      ownerName: '',
      unit: data['unitId']?.toString().trim() ?? '',
      unitNumber: data['unitNumber']?.toString().trim() ?? '',
      type: type,
      allowedPersons: count.clamp(1, 6),
      createdAt: createdValue is Timestamp
          ? createdValue.toDate()
          : DateTime.fromMillisecondsSinceEpoch(0),
      qrToken: data['qrToken']?.toString().trim() ?? '',
      validDate: data['validDate']?.toString().trim(),
      deliveryType: data['deliveryType']?.toString().trim(),
      usedAt: usedValue is Timestamp ? usedValue.toDate() : null,
      expiresAt: expiresValue is Timestamp ? expiresValue.toDate() : null,
      cancelledAt: cancelledValue is Timestamp ? cancelledValue.toDate() : null,
      status: status,
      isRead: false,
      isUsed: isUsed,
    );
  }
}
