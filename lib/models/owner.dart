import 'dart:convert';

class Owner {
  const Owner({
    this.unitId,
    required this.name,
    required this.buildingNumber,
    required this.floorNumber,
    required this.apartment,
  });
  final String? unitId;
  final String name, buildingNumber, floorNumber, apartment;
  String get unitLabel => apartment;
  String get storageKey => unitId ?? apartment;
}

enum QrType { guest, delivery }

enum QrStatus { active, used, cancelled, expired }

class QrRecord {
  const QrRecord({
    required this.id,
    required this.ownerName,
    required this.unit,
    required this.type,
    required this.allowedPersons,
    required this.createdAt,
    required this.qrToken,
    this.ownerId,
    this.unitNumber,
    this.validDate,
    this.deliveryType,
    this.usedAt,
    this.expiresAt,
    this.cancelledAt,
    this.status = QrStatus.active,
    this.isRead = true,
    this.isUsed = false,
  });

  factory QrRecord.create({
    required Owner owner,
    required QrType type,
    required int allowedPersons,
    DateTime? createdAt,
    bool isRead = true,
    bool isUsed = false,
  }) {
    final creationTime = createdAt ?? DateTime.now();
    return QrRecord(
      id: 'qr-${creationTime.microsecondsSinceEpoch.toRadixString(36)}',
      ownerName: owner.name,
      unit: owner.storageKey,
      type: type,
      allowedPersons: allowedPersons,
      createdAt: creationTime,
      qrToken: 'qr-${creationTime.microsecondsSinceEpoch.toRadixString(36)}',
      isRead: isRead,
      isUsed: isUsed,
    );
  }

  final String id, ownerName, unit;
  final QrType type;
  final int allowedPersons;
  final DateTime createdAt;
  final String qrToken;
  final String? ownerId, unitNumber, validDate;
  final String? deliveryType;
  final DateTime? usedAt;
  final DateTime? expiresAt, cancelledAt;
  final QrStatus status;
  final bool isRead, isUsed;

  QrRecord copyWith({
    bool? isRead,
    bool? isUsed,
    QrStatus? status,
    DateTime? cancelledAt,
  }) => QrRecord(
    id: id,
    ownerName: ownerName,
    unit: unit,
    type: type,
    allowedPersons: allowedPersons,
    createdAt: createdAt,
    qrToken: qrToken,
    ownerId: ownerId,
    unitNumber: unitNumber,
    validDate: validDate,
    deliveryType: deliveryType,
    usedAt: usedAt,
    expiresAt: expiresAt,
    cancelledAt: cancelledAt ?? this.cancelledAt,
    status: status ?? this.status,
    isRead: isRead ?? this.isRead,
    isUsed: isUsed ?? this.isUsed,
  );

  String get typeCode => type == QrType.delivery ? 'DELIVERY' : 'GUEST';
  String get qrData => jsonEncode({
    'qrId': id,
    'qrToken': qrToken,
    'ownerName': ownerName,
    'unit': unit,
    'qrType': typeCode,
    'allowedPersons': allowedPersons,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'expiresAt': expiresAt?.toUtc().toIso8601String(),
    'status': status.name.toUpperCase(),
    'isUsed': isUsed,
  });
}
