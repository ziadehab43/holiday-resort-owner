import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../models/owner.dart';
import '../models/owner_profile.dart';

class OwnerSessionData {
  const OwnerSessionData({required this.profile, required this.units});
  final OwnerProfile profile;
  final List<Owner> units;
}

class OwnerBackendException implements Exception {
  const OwnerBackendException(this.message);
  final String message;
}

abstract interface class OwnerBackend {
  Future<OwnerSessionData> signIn(String email, String password);
  Future<OwnerSessionData?> restoreSession();
  Future<void> signOut();
}

class FirebaseOwnerBackend implements OwnerBackend {
  FirebaseOwnerBackend({FirebaseAuth? auth, FirebaseFirestore? firestore})
    : _auth = auth ?? FirebaseAuth.instance,
      _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseAuth _auth;
  final FirebaseFirestore _firestore;

  @override
  Future<OwnerSessionData> signIn(String email, String password) async {
    try {
      final credential = await _auth.signInWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );
      return await _loadOwner(credential.user!.uid);
    } on FirebaseAuthException catch (error) {
      throw OwnerBackendException(_authMessage(error.code));
    } on FirebaseException catch (error) {
      await _safeSignOut();
      throw OwnerBackendException(_firestoreMessage(error.code));
    } on OwnerBackendException {
      await _safeSignOut();
      rethrow;
    } catch (_) {
      await _safeSignOut();
      throw const OwnerBackendException(
        'تعذر تسجيل الدخول حالياً. يرجى المحاولة مرة أخرى.',
      );
    }
  }

  @override
  Future<OwnerSessionData?> restoreSession() async {
    final user = _auth.currentUser;
    if (user == null) return null;
    try {
      return await _loadOwner(user.uid);
    } on FirebaseException catch (error) {
      await _safeSignOut();
      throw OwnerBackendException(_firestoreMessage(error.code));
    } on OwnerBackendException {
      await _safeSignOut();
      rethrow;
    } catch (_) {
      await _safeSignOut();
      throw const OwnerBackendException(
        'تعذر التحقق من حسابك. يرجى تسجيل الدخول مرة أخرى.',
      );
    }
  }

  Future<OwnerSessionData> _loadOwner(String uid) async {
    if (kDebugMode) {
      debugPrint('Owner session: reading users/$uid using Firebase Auth UID');
    }
    final userDocument = await _firestore
        .collection('users')
        .doc(uid)
        .get(const GetOptions(source: Source.server));
    if (!userDocument.exists) {
      throw const OwnerBackendException(
        'ملف المالك غير موجود. يرجى التواصل مع الإدارة.',
      );
    }
    final data = userDocument.data()!;
    if (data['role'] != 'owner') {
      throw const OwnerBackendException(
        'هذا الحساب غير مصرح له باستخدام تطبيق المالك.',
      );
    }
    if (data['adminOperation'] != null) {
      throw const OwnerBackendException(
        'يوجد تحديث حساب لم يكتمل. اطلب من الإدارة استعادة التحديث ثم أعد تسجيل الدخول؛ لم تُحذف بياناتك.',
      );
    }
    if (data['isActive'] != true) {
      throw const OwnerBackendException(
        'حسابك غير نشط. يرجى التواصل مع الإدارة.',
      );
    }

    final name = (data['name'] as String?)?.trim();
    final email = (data['email'] as String?)?.trim();
    if (name == null || name.isEmpty || email == null || email.isEmpty) {
      throw const OwnerBackendException(
        'بيانات حساب المالك غير مكتملة. يرجى التواصل مع الإدارة.',
      );
    }
    final profile = OwnerProfile(
      uid: uid,
      name: name,
      email: email,
      role: 'owner',
      isActive: true,
    );

    final unitSnapshot = await _firestore
        .collection('units')
        .where('ownerId', isEqualTo: uid)
        .where('isActive', isEqualTo: true)
        .get(const GetOptions(source: Source.server));
    final units =
        unitSnapshot.docs
            .where((document) => document.data()['isActive'] == true)
            .map((document) {
              final unit = document.data().map(
                (key, value) => MapEntry(key.trim(), value),
              );
              final unitNumber = (unit['unitNumber'] as String?)?.trim();
              if (unitNumber == null || unitNumber.isEmpty) return null;
              return Owner(
                unitId: document.id,
                name: profile.name,
                buildingNumber:
                    (unit['buildingNumber'] as String?)?.trim() ?? '',
                floorNumber: (unit['floorNumber'] as String?)?.trim() ?? '',
                apartment: unitNumber,
              );
            })
            .whereType<Owner>()
            .toList()
          ..sort((a, b) => a.apartment.compareTo(b.apartment));
    return OwnerSessionData(profile: profile, units: units);
  }

  @override
  Future<void> signOut() => _auth.signOut();

  Future<void> _safeSignOut() async {
    try {
      await _auth.signOut();
    } catch (_) {}
  }

  static String _authMessage(String code) => switch (code) {
    'invalid-credential' ||
    'wrong-password' ||
    'user-not-found' => 'البريد الإلكتروني أو كلمة المرور غير صحيحة.',
    'invalid-email' => 'يرجى إدخال بريد إلكتروني صحيح.',
    'user-disabled' => 'تم تعطيل هذا الحساب. يرجى التواصل مع الإدارة.',
    'too-many-requests' =>
      'تم إجراء محاولات كثيرة. يرجى الانتظار ثم المحاولة مرة أخرى.',
    'network-request-failed' =>
      'تعذر الاتصال بالشبكة. تحقق من الإنترنت وحاول مرة أخرى.',
    _ => 'تعذر تسجيل الدخول. يرجى المحاولة مرة أخرى.',
  };

  static String _firestoreMessage(String code) => switch (code) {
    'unavailable' =>
      'الخدمة غير متاحة حالياً. تحقق من الإنترنت وحاول مرة أخرى.',
    'permission-denied' =>
      'لا يمكن الوصول إلى بيانات الحساب. يرجى التواصل مع الإدارة.',
    _ => 'تعذر تحميل بيانات الحساب حالياً.',
  };
}
