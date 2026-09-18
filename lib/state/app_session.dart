import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:timezone/timezone.dart' as tz;

import '../models/owner.dart';
import '../models/owner_profile.dart';
import '../models/report.dart';
import '../services/owner_backend.dart';
import '../services/report_backend.dart';
import '../services/history_backend.dart';
import '../services/guest_qr_backend.dart';
import '../services/delivery_qr_backend.dart';

class AppSession extends ChangeNotifier {
  AppSession({
    OwnerBackend? backend,
    List<Owner>? linkedOwners,
    String? ownerId,
    String? ownerEmail,
    GuestQrBackend? guestQrBackend,
    DeliveryQrBackend? deliveryQrBackend,
    HistoryBackend? historyBackend,
    ReportBackend? reportBackend,
  }) {
    _backend = backend;
    _guestQrBackend = guestQrBackend;
    _deliveryQrBackend = deliveryQrBackend;
    _historyBackend = historyBackend;
    _reportBackend = reportBackend;
    // linkedOwners is an injection seam for widget tests only. The real app
    // always supplies FirebaseOwnerBackend and receives units from Firestore.
    if (linkedOwners != null) {
      if (ownerId == null || ownerEmail == null) {
        throw ArgumentError(
          'Injected units require an injected ownerId and ownerEmail.',
        );
      }
      _applySession(
        OwnerSessionData(
          profile: OwnerProfile(
            uid: ownerId,
            name: linkedOwners.isEmpty
                ? 'مالك الوحدة'
                : linkedOwners.first.name,
            email: ownerEmail,
            role: 'owner',
            isActive: true,
          ),
          units: linkedOwners,
        ),
        authenticated: false,
      );
    }
  }

  late final OwnerBackend? _backend;
  late final GuestQrBackend? _guestQrBackend;
  late final DeliveryQrBackend? _deliveryQrBackend;
  late final HistoryBackend? _historyBackend;
  late final ReportBackend? _reportBackend;
  final List<Owner> _linkedOwners = [];
  final Map<String, List<QrRecord>> _historyByUnit = {};
  final List<QrRecord> _ownerHistory = [];
  final Set<String> _openedHistoryIds = {};
  final List<OwnerReport> _reports = [];
  OwnerProfile? _profile;
  Owner? _activeOwner;
  bool _isAuthenticated = false;
  GuestDailyAllowance _allowance = const GuestDailyAllowance(reserved: 0);
  StreamSubscription<GuestDailyAllowance>? _allowanceSubscription;
  StreamSubscription<List<OwnerReport>>? _reportSubscription;
  StreamSubscription<List<QrRecord>>? _historySubscription;

  bool get isAuthenticated => _isAuthenticated;
  bool get usesRemoteAuth => _backend != null;
  OwnerProfile? get profile => _profile;
  Owner? get activeOwner => _activeOwner;
  bool get hasUnits => _linkedOwners.isNotEmpty;
  List<Owner> get linkedOwners => List.unmodifiable(_linkedOwners);
  String get ownerId => _profile?.uid ?? '';
  String get ownerEmail => _profile?.email ?? '';
  String get ownerName => _profile?.name ?? '';
  List<OwnerReport> get reports => List.unmodifiable(_reports);
  GuestDailyAllowance get guestAllowance => _allowance;
  List<QrRecord> get ownerHistory => List.unmodifiable(_ownerHistory);
  List<QrRecord> get activeHistory {
    final owner = _activeOwner;
    return owner == null
        ? const []
        : List.unmodifiable(_historyByUnit[owner.storageKey] ?? const []);
  }

  List<QrRecord> todayActiveHistory({DateTime? now}) {
    final owner = _activeOwner;
    if (owner == null) return const [];
    final egyptNow = FirebaseGuestQrBackend.egyptTime(now ?? DateTime.now());
    final startOfToday = tz.TZDateTime(
      egyptNow.location,
      egyptNow.year,
      egyptNow.month,
      egyptNow.day,
    );
    final startOfTomorrow = tz.TZDateTime(
      egyptNow.location,
      egyptNow.year,
      egyptNow.month,
      egyptNow.day + 1,
    );
    return List.unmodifiable(
      (_historyByUnit[owner.storageKey] ?? const []).where(
        (record) =>
            !record.createdAt.isBefore(startOfToday) &&
            record.createdAt.isBefore(startOfTomorrow),
      ),
    );
  }

  List<QrRecord> historyFor(Owner owner) =>
      List.unmodifiable(_historyByUnit[owner.storageKey] ?? const []);

  QrRecord? qrRecordById(String recordId) {
    for (final records in _historyByUnit.values) {
      for (final record in records) {
        if (record.id == recordId) return record;
      }
    }
    return null;
  }

  QrRecord? todayGuestQrFor(Owner owner) {
    final records = _historyByUnit[owner.storageKey] ?? const [];
    final date = FirebaseGuestQrBackend.egyptDate();
    for (final record in records) {
      if (record.type == QrType.guest && record.validDate == date) {
        return record;
      }
    }
    return null;
  }

  Future<QrRecord?> loadTodayGuestQr(Owner owner) async {
    final backend = _guestQrBackend;
    if (backend == null) return todayGuestQrFor(owner);
    final record = await backend.getToday(unit: owner);
    if (record != null) _storeQrRecord(record);
    return record;
  }

  Future<GuestQrResult> generateGuestQr(Owner owner, int guestCount) async {
    final backend = _guestQrBackend;
    if (backend == null) {
      throw const GuestQrException('خدمة كود الضيافة غير متاحة حالياً.');
    }
    final result = await backend.generate(unit: owner, guestCount: guestCount);
    _storeQrRecord(result.record);
    return result;
  }

  void watchActiveUnitData() {
    _allowanceSubscription?.cancel();
    _reportSubscription?.cancel();
    _historySubscription?.cancel();
    _allowance = const GuestDailyAllowance(reserved: 0);
    final owner = _activeOwner;
    if (owner == null) {
      notifyListeners();
      return;
    }
    final guestBackend = _guestQrBackend;
    if (guestBackend is GuestQuotaBackend) {
      final quotaBackend = guestBackend as GuestQuotaBackend;
      _allowanceSubscription = quotaBackend.watchAllowance(unit: owner).listen((
        value,
      ) {
        if (_activeOwner?.storageKey != owner.storageKey) return;
        _allowance = value;
        notifyListeners();
      });
    }
    final historyBackend = _historyBackend;
    if (historyBackend is HistoryTrackingBackend) {
      _historySubscription = historyBackend
          .watchUnitHistory(unitId: owner.unitId ?? owner.storageKey)
          .listen((items) {
            if (_activeOwner?.storageKey != owner.storageKey) return;
            final records = items
                .map(
                  (record) => _openedHistoryIds.contains(record.id)
                      ? record.copyWith(isRead: true)
                      : record,
                )
                .toList();
            _historyByUnit[owner.storageKey] = records;
            _ownerHistory
              ..clear()
              ..addAll(records);
            notifyListeners();
          });
    }
    final reportBackend = _reportBackend;
    if (reportBackend is ReportTrackingBackend) {
      final trackingBackend = reportBackend as ReportTrackingBackend;
      _reportSubscription = trackingBackend
          .watchUnitReports(unitId: owner.unitId ?? owner.storageKey)
          .listen((items) {
            if (_activeOwner?.storageKey != owner.storageKey) return;
            _reports
              ..clear()
              ..addAll(items);
            notifyListeners();
          });
    }
  }

  Future<void> cancelGuestQr(QrRecord record) async {
    final owner = _activeOwner;
    final backend = _guestQrBackend;
    if (owner == null) {
      throw const GuestQrException('لا توجد وحدة مرتبطة بالحساب.');
    }
    if (backend is! GuestQuotaBackend) {
      throw const GuestQrException('خدمة إلغاء الكود غير متاحة حالياً.');
    }
    await (backend as GuestQuotaBackend).cancel(unit: owner, record: record);
    final updated = record.copyWith(
      status: QrStatus.cancelled,
      cancelledAt: DateTime.now(),
    );
    _storeQrRecord(updated);
    await loadActiveUnitHistory();
  }

  Future<QrRecord> generateDeliveryQr(Owner owner, String deliveryType) async {
    final backend = _deliveryQrBackend;
    if (backend == null) {
      throw const DeliveryQrException('خدمة كود التوصيل غير متاحة حالياً.');
    }
    final record = await backend.generate(
      unit: owner,
      deliveryType: deliveryType,
    );
    _storeQrRecord(record);
    return record;
  }

  Future<void> loadActiveUnitHistory() async {
    final backend = _historyBackend;
    if (backend == null) return;
    final owner = _activeOwner;
    if (owner == null) {
      _ownerHistory.clear();
      notifyListeners();
      return;
    }
    final unitId = owner.unitId ?? owner.storageKey;
    final records = await backend.loadUnitHistory(unitId: unitId)
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    if (_activeOwner?.storageKey != owner.storageKey) return;
    _ownerHistory
      ..clear()
      ..addAll(
        records.map(
          (record) => _openedHistoryIds.contains(record.id)
              ? record.copyWith(isRead: true)
              : record,
        ),
      );
    notifyListeners();
  }

  Future<void> signIn(String email, String password) async {
    final backend = _backend;
    if (backend == null) {
      _isAuthenticated = true;
      notifyListeners();
      return;
    }
    final data = await backend.signIn(email, password);
    _applySession(data, authenticated: true);
  }

  Future<bool> restoreSession() async {
    final backend = _backend;
    if (backend == null) return _isAuthenticated;
    final data = await backend.restoreSession();
    if (data == null) {
      _clearAccountState();
      return false;
    }
    _applySession(data, authenticated: true);
    return true;
  }

  Future<void> logout() async {
    await _backend?.signOut();
    _clearAccountState();
    notifyListeners();
  }

  void _applySession(OwnerSessionData data, {required bool authenticated}) {
    _profile = data.profile;
    _isAuthenticated = authenticated;
    _linkedOwners
      ..clear()
      ..addAll(data.units);
    _activeOwner = _linkedOwners.isEmpty ? null : _linkedOwners.first;
    _historyByUnit.clear();
    _ownerHistory.clear();
    _openedHistoryIds.clear();
    for (final owner in _linkedOwners) {
      _historyByUnit[owner.storageKey] = [];
    }
    _reports.clear();
    watchActiveUnitData();
    notifyListeners();
  }

  void _clearAccountState() {
    _isAuthenticated = false;
    _profile = null;
    _activeOwner = null;
    _linkedOwners.clear();
    _historyByUnit.clear();
    _ownerHistory.clear();
    _openedHistoryIds.clear();
    _reports.clear();
    _allowanceSubscription?.cancel();
    _reportSubscription?.cancel();
    _historySubscription?.cancel();
  }

  void switchOwner(Owner owner) {
    if (_activeOwner?.storageKey == owner.storageKey ||
        !_linkedOwners.contains(owner)) {
      return;
    }
    _activeOwner = owner;
    _ownerHistory.clear();
    watchActiveUnitData();
    notifyListeners();
  }

  @override
  void dispose() {
    _allowanceSubscription?.cancel();
    _reportSubscription?.cancel();
    _historySubscription?.cancel();
    super.dispose();
  }

  void addQrRecord(QrRecord record) {
    assert(record.unit == _activeOwner?.storageKey);
    (_historyByUnit[record.unit] ??= []).insert(0, record);
    notifyListeners();
  }

  void _storeQrRecord(QrRecord record) {
    final records = _historyByUnit[record.unit] ??= [];
    final index = records.indexWhere((item) => item.id == record.id);
    if (index >= 0) {
      records[index] = record;
    } else {
      records.insert(0, record);
    }
    final ownerIndex = _ownerHistory.indexWhere((item) => item.id == record.id);
    if (ownerIndex >= 0) {
      _ownerHistory[ownerIndex] = record;
    } else {
      _ownerHistory.insert(0, record);
    }
    notifyListeners();
  }

  void markQrRead(String recordId) {
    _openedHistoryIds.add(recordId);
    final ownerIndex = _ownerHistory.indexWhere(
      (record) => record.id == recordId,
    );
    if (ownerIndex >= 0 && !_ownerHistory[ownerIndex].isRead) {
      _ownerHistory[ownerIndex] = _ownerHistory[ownerIndex].copyWith(
        isRead: true,
      );
    }
    for (final records in _historyByUnit.values) {
      final index = records.indexWhere((record) => record.id == recordId);
      if (index >= 0) {
        if (records[index].isRead) {
          notifyListeners();
          return;
        }
        records[index] = records[index].copyWith(isRead: true);
        notifyListeners();
        return;
      }
    }
    notifyListeners();
  }

  void updateQrUsage(String recordId, {required bool isUsed}) {
    for (final records in _historyByUnit.values) {
      final index = records.indexWhere((record) => record.id == recordId);
      if (index >= 0) {
        records[index] = records[index].copyWith(isUsed: isUsed);
        notifyListeners();
        return;
      }
    }
  }

  Future<OwnerReport> submitReport({
    required ReportCategory category,
    required String message,
  }) async {
    final backend = _reportBackend;
    final owner = _activeOwner;
    if (backend == null) {
      throw const ReportBackendException(
        'خدمة إرسال الطلبات غير متاحة حالياً.',
      );
    }
    if (owner == null) {
      throw const ReportBackendException('لا توجد وحدة مرتبطة بالحساب.');
    }
    final report = await backend.createReport(
      ownerName: ownerName,
      unit: owner,
      category: category,
      message: message,
    );
    _reports.insert(0, report);
    notifyListeners();
    return report;
  }
}

class AppSessionScope extends InheritedNotifier<AppSession> {
  const AppSessionScope({
    super.key,
    required AppSession session,
    required super.child,
  }) : super(notifier: session);

  static AppSession of(BuildContext context, {bool listen = true}) {
    if (!listen) {
      final element = context
          .getElementForInheritedWidgetOfExactType<AppSessionScope>();
      return (element!.widget as AppSessionScope).notifier!;
    }
    return context
        .dependOnInheritedWidgetOfExactType<AppSessionScope>()!
        .notifier!;
  }
}
