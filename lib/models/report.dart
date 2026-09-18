import 'package:cloud_firestore/cloud_firestore.dart';

enum ReportCategory { qr, security, unitRequest, general, other }

extension ReportCategoryValue on ReportCategory {
  String get firestoreValue => switch (this) {
    ReportCategory.qr => 'qr',
    ReportCategory.security => 'security',
    ReportCategory.unitRequest => 'unit_request',
    ReportCategory.general => 'general',
    ReportCategory.other => 'other',
  };

  static ReportCategory parse(Object? value) =>
      switch (value?.toString().trim().toLowerCase()) {
        'security' => ReportCategory.security,
        'unit_request' => ReportCategory.unitRequest,
        'general' => ReportCategory.general,
        'other' => ReportCategory.other,
        _ => ReportCategory.qr,
      };
}

enum ReportStatus { pending, inProgress, resolved, rejected }

extension ReportStatusValue on ReportStatus {
  String get firestoreValue => switch (this) {
    ReportStatus.pending => 'pending',
    ReportStatus.inProgress => 'in_progress',
    ReportStatus.resolved => 'resolved',
    ReportStatus.rejected => 'rejected',
  };

  String get arabicLabel => switch (this) {
    ReportStatus.pending => 'تم الإرسال',
    ReportStatus.inProgress => 'جاري المراجعة',
    ReportStatus.resolved => 'تم الحل',
    ReportStatus.rejected => 'مرفوض',
  };

  static ReportStatus parse(Object? value) =>
      switch (value?.toString().trim().toLowerCase()) {
        'in_progress' ||
        'under_review' ||
        'under review' => ReportStatus.inProgress,
        'resolved' => ReportStatus.resolved,
        'rejected' => ReportStatus.rejected,
        _ => ReportStatus.pending,
      };
}

class OwnerReport {
  const OwnerReport({
    required this.id,
    required this.ownerId,
    required this.ownerName,
    required this.unitId,
    required this.unitNumber,
    required this.category,
    required this.message,
    required this.createdAt,
    this.status = ReportStatus.pending,
    this.updatedAt,
    this.adminResponse,
  });

  factory OwnerReport.fromFirestore(String id, Map<String, dynamic> rawData) {
    final data = rawData.map((key, value) => MapEntry(key.trim(), value));
    final created = data['createdAt'];
    final updated = data['updatedAt'];
    return OwnerReport(
      id: id,
      ownerId: data['ownerId']?.toString().trim() ?? '',
      ownerName: data['ownerName']?.toString().trim() ?? '',
      unitId: data['unitId']?.toString().trim() ?? '',
      unitNumber: data['unitNumber']?.toString().trim() ?? '',
      category: ReportCategoryValue.parse(data['category']),
      message:
          (data['message'] ?? data['description'])?.toString().trim() ?? '',
      status: ReportStatusValue.parse(data['status']),
      createdAt: created is Timestamp
          ? created.toDate()
          : DateTime.fromMillisecondsSinceEpoch(0),
      updatedAt: updated is Timestamp ? updated.toDate() : null,
      adminResponse: (data['adminResponse'] ?? data['adminReply'])
          ?.toString()
          .trim(),
    );
  }

  final String id, ownerId, ownerName, unitId, unitNumber, message;
  final ReportCategory category;
  final ReportStatus status;
  final DateTime createdAt;
  final DateTime? updatedAt;
  final String? adminResponse;

  String get description => message;
}
