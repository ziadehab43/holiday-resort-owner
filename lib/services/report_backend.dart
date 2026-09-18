import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../models/owner.dart';
import '../models/report.dart';

class ReportBackendException implements Exception {
  const ReportBackendException(this.message);
  final String message;
}

abstract interface class ReportBackend {
  Future<OwnerReport> createReport({
    required String ownerName,
    required Owner unit,
    required ReportCategory category,
    required String message,
  });
}

abstract interface class ReportTrackingBackend {
  Stream<List<OwnerReport>> watchUnitReports({required String unitId});
}

class FirebaseReportBackend implements ReportBackend, ReportTrackingBackend {
  FirebaseReportBackend({FirebaseAuth? auth, FirebaseFirestore? firestore})
    : _auth = auth ?? FirebaseAuth.instance,
      _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseAuth _auth;
  final FirebaseFirestore _firestore;

  @override
  Future<OwnerReport> createReport({
    required String ownerName,
    required Owner unit,
    required ReportCategory category,
    required String message,
  }) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null || uid.isEmpty) {
      throw const ReportBackendException(
        'انتهت جلسة الدخول. سجل الدخول مرة أخرى.',
      );
    }
    final unitId = unit.unitId;
    if (unitId == null || unitId.isEmpty) {
      throw const ReportBackendException('بيانات الوحدة غير مكتملة.');
    }
    final trimmedMessage = message.trim();
    if (trimmedMessage.isEmpty) {
      throw const ReportBackendException('يرجى كتابة وصف المشكلة أو الطلب.');
    }

    try {
      final reference = await _firestore.collection('reports').add({
        'ownerId': uid,
        'ownerName': ownerName,
        'unitId': unitId,
        'unitNumber': unit.apartment,
        'category': category.firestoreValue,
        'message': trimmedMessage,
        'description': trimmedMessage,
        'status': 'pending',
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': null,
        'adminResponse': null,
        'adminReply': null,
        'adminReadAt': null,
        'buildingNumber': unit.buildingNumber,
      });
      final saved = await reference.get(
        const GetOptions(source: Source.server),
      );
      debugPrint('REPORT_RUNTIME path=${reference.path} data=${saved.data()}');
      return OwnerReport(
        id: reference.id,
        ownerId: uid,
        ownerName: ownerName,
        unitId: unitId,
        unitNumber: unit.apartment,
        category: category,
        message: trimmedMessage,
        createdAt: DateTime.now(),
      );
    } on FirebaseException catch (error) {
      debugPrint(
        'REPORT_RUNTIME_FAILED collection=reports uid=$uid unitId=$unitId '
        'code=${error.code} message=${error.message}',
      );
      throw const ReportBackendException(
        'تعذر إرسال الطلب. تحقق من الإنترنت وحاول مرة أخرى.',
      );
    }
  }

  @override
  Stream<List<OwnerReport>> watchUnitReports({required String unitId}) {
    final uid = _auth.currentUser?.uid;
    if (uid == null || uid.isEmpty) {
      return Stream.error(
        const ReportBackendException('انتهت جلسة الدخول. سجل الدخول مرة أخرى.'),
      );
    }
    return _firestore
        .collection('reports')
        .where('ownerId', isEqualTo: uid)
        .where('unitId', isEqualTo: unitId)
        .snapshots()
        .map((snapshot) {
          final reports =
              snapshot.docs
                  .map((doc) => OwnerReport.fromFirestore(doc.id, doc.data()))
                  .toList()
                ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
          return reports;
        });
  }
}
