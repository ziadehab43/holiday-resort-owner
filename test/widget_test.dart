import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:test_app/app/app.dart';
import 'package:test_app/models/owner.dart';
import 'package:test_app/models/owner_profile.dart';
import 'package:test_app/models/report.dart';
import 'package:test_app/services/delivery_qr_backend.dart';
import 'package:test_app/services/owner_backend.dart';
import 'package:test_app/services/owner_api_client.dart';
import 'package:test_app/services/guest_qr_backend.dart';
import 'package:test_app/services/history_backend.dart';
import 'package:test_app/services/report_backend.dart';
import 'package:test_app/state/app_session.dart';

void main() {
  const testUnits = [
    Owner(
      name: 'مالك الاختبار',
      buildingNumber: '1',
      floorNumber: '1',
      apartment: '101',
    ),
    Owner(
      name: 'مالك الاختبار',
      buildingNumber: '2',
      floorNumber: '2',
      apartment: '205',
    ),
    Owner(
      name: 'مالك الاختبار',
      buildingNumber: '3',
      floorNumber: '3',
      apartment: '310',
    ),
  ];

  AppSession testSession() => AppSession(
    linkedOwners: [testUnits.first],
    ownerId: 'test-owner-id',
    ownerEmail: 'owner@test.local',
    deliveryQrBackend: _FakeDeliveryQrBackend(),
    reportBackend: _FakeReportBackend(),
  );

  Future<void> openLogin(WidgetTester tester, AppSession session) async {
    await tester.pumpWidget(HolidayResortApp(session: session));
    expect(
      find.image(const AssetImage('assets/images/splash_final/wordmark.png')),
      findsWidgets,
    );
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 2000));
    expect(find.text('نسيت كلمة المرور؟'), findsNothing);
    // Asset decoding can complete on a later microtask in a cold test process.
    // Advance in bounded steps until the intro has actually handed off.
    for (
      var second = 0;
      second < 6 && find.text('نسيت كلمة المرور؟').evaluate().isEmpty;
      second++
    ) {
      await tester.pump(const Duration(seconds: 1));
    }
    await tester.pumpAndSettle();
  }

  testWidgets('owner app opens on login', (tester) async {
    await openLogin(tester, testSession());
    expect(find.text('نسيت كلمة المرور؟'), findsOneWidget);
    expect(find.text('تسجيل الدخول'), findsOneWidget);
  });

  testWidgets('forgot password and create account share contact route', (
    tester,
  ) async {
    await openLogin(tester, testSession());
    await tester.tap(find.text('نسيت كلمة المرور؟'));
    await tester.pumpAndSettle();
    expect(find.text('تواصل مع الإدارة'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.arrow_back_ios_new));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('إنشاء حساب'));
    await tester.tap(find.text('إنشاء حساب'));
    await tester.pumpAndSettle();
    expect(find.text('تواصل مع الإدارة'), findsOneWidget);
  });

  testWidgets('home has no notification and profile pops back to home', (
    tester,
  ) async {
    await openLogin(tester, testSession());
    await tester.tap(find.text('تسجيل الدخول'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.notifications_none), findsNothing);
    expect(find.text('Hi'), findsOneWidget);
    expect(find.text('صباح الخير'), findsNothing);
    expect(find.text('مساء الخير'), findsNothing);

    await tester.tap(find.byKey(const Key('profile_button')));
    await tester.pumpAndSettle();
    expect(find.text('تسجيل الخروج'), findsOneWidget);
    expect(find.text('إضافة وحدة أخرى'), findsNothing);
    expect(find.byIcon(Icons.keyboard_arrow_down_rounded), findsNothing);
    await tester.drag(
      find.byKey(const Key('profile_drag_handle')),
      const Offset(0, 300),
    );
    await tester.pumpAndSettle();
    expect(find.text('أحدث الأنشطة'), findsOneWidget);
  });

  testWidgets('delivery generates a one-person QR and appears in history', (
    tester,
  ) async {
    final session = testSession();
    await openLogin(tester, session);
    await tester.tap(find.text('تسجيل الدخول'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.qr_code_scanner_rounded));
    await tester.pumpAndSettle();

    expect(find.text('التوصيل'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('delivery_type_dropdown')));
    await tester.tap(find.byKey(const Key('delivery_type_dropdown')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('صيدلية').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('توليد كود التوصيل'));
    await tester.tap(find.text('توليد كود التوصيل'));
    await tester.pumpAndSettle();

    expect(find.text('تم إنشاء كود التوصيل بنجاح'), findsOneWidget);
    expect(find.text('فرد واحد'), findsWidgets);
    expect(session.activeHistory.first.type, QrType.delivery);
    expect(session.activeHistory.first.allowedPersons, 1);
    expect(session.activeHistory.first.deliveryType, 'صيدلية');
    expect(session.activeHistory.first.isRead, isFalse);
    expect(session.activeHistory.first.qrData, contains('delivery-token-'));

    await tester.tap(find.byIcon(Icons.arrow_back_ios_new));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.calendar_month_outlined));
    await tester.pumpAndSettle();
    expect(find.text('توصيل - صيدلية'), findsOneWidget);
    expect(find.text('فرد واحد'), findsWidgets);
  });

  testWidgets('multiple guest QR codes can be generated on the same day', (
    tester,
  ) async {
    final session = AppSession(
      linkedOwners: [testUnits.first],
      ownerId: 'test-owner-id',
      ownerEmail: 'owner@test.local',
      guestQrBackend: _FakeGuestQrBackend(),
    );
    await openLogin(tester, session);
    await tester.tap(find.text('تسجيل الدخول'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.qr_code_scanner_rounded));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('توليد كود الضيافة'));
    await tester.tap(find.text('توليد كود الضيافة'));
    await tester.pumpAndSettle();
    expect(find.text('كود الضيافة'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.arrow_back_ios_new));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('توليد كود الضيافة'));
    await tester.tap(find.text('توليد كود الضيافة'));
    await tester.pumpAndSettle();

    expect(find.text('كود الضيافة'), findsOneWidget);
    expect(session.activeHistory, hasLength(2));
  });

  test(
    'backend-linked units switch context and keep QR histories isolated',
    () {
      final session = AppSession(
        linkedOwners: testUnits,
        ownerId: 'test-owner-id',
        ownerEmail: 'owner@test.local',
      );
      final firstUnit = session.activeOwner;
      expect(session.linkedOwners, hasLength(3));
      final secondUnit = session.linkedOwners.last;
      session.switchOwner(secondUnit);
      final delivery = QrRecord.create(
        owner: secondUnit,
        type: QrType.delivery,
        allowedPersons: 1,
      );
      session.addQrRecord(delivery);
      expect(session.activeHistory, [delivery]);

      session.switchOwner(firstUnit!);
      expect(session.activeHistory, isNot(contains(delivery)));
    },
  );

  test(
    'delivery QR creates a new token every time and follows active unit',
    () async {
      final backend = _FakeDeliveryQrBackend();
      final session = AppSession(
        linkedOwners: testUnits.take(2).toList(),
        ownerId: 'test-owner-id',
        ownerEmail: 'owner@test.local',
        deliveryQrBackend: backend,
      );

      final unit101 = session.activeOwner!;
      final first = await session.generateDeliveryQr(unit101, 'مطعم');
      final second = await session.generateDeliveryQr(unit101, 'صيدلية');
      final third = await session.generateDeliveryQr(unit101, 'مندوب');
      expect({first.id, second.id, third.id}, hasLength(3));
      expect({first.qrToken, second.qrToken, third.qrToken}, hasLength(3));
      expect(session.historyFor(unit101), hasLength(3));
      expect(first.allowedPersons, 1);

      final unit205 = session.linkedOwners[1];
      session.switchOwner(unit205);
      final otherUnit = await session.generateDeliveryQr(unit205, 'سوبر ماركت');
      expect(otherUnit.unit, unit205.storageKey);
      expect(session.historyFor(unit205), [otherUnit]);
      expect(backend.records, hasLength(4));
    },
  );

  test(
    'guest quota supports multiple QR codes and is isolated per unit',
    () async {
      final backend = _FakeGuestQrBackend();
      final session = AppSession(
        linkedOwners: testUnits.take(2).toList(),
        ownerId: 'test-owner-id',
        ownerEmail: 'owner@test.local',
        guestQrBackend: backend,
      );

      final unit101 = session.activeOwner!;
      final first = await session.generateGuestQr(unit101, 3);
      final second = await session.generateGuestQr(unit101, 3);

      expect(first.created, isTrue);
      expect(second.created, isTrue);
      expect(second.record.id, isNot(first.record.id));
      expect(session.historyFor(unit101), hasLength(2));
      await expectLater(
        session.generateGuestQr(unit101, 1),
        throwsA(isA<GuestQrException>()),
      );

      final unit205 = session.linkedOwners[1];
      final secondUnit = await session.generateGuestQr(unit205, 2);
      expect(secondUnit.created, isTrue);
      expect(secondUnit.record.unit, unit205.storageKey);
      expect(backend.records, hasLength(3));
      await session.cancelGuestQr(first.record);
      final replacement = await session.generateGuestQr(unit101, 3);
      expect(replacement.created, isTrue);
    },
  );

  test(
    'Firestore history follows active unit and preserves opened state',
    () async {
      final older = QrRecord(
        id: 'delivery-unit-205',
        ownerId: 'test-owner-id',
        ownerName: '',
        unit: '205',
        unitNumber: '205',
        type: QrType.delivery,
        allowedPersons: 1,
        createdAt: DateTime(2026, 8, 30, 10),
        qrToken: 'delivery-token',
        validDate: '2026-08-30',
        deliveryType: 'صيدلية',
        status: QrStatus.used,
        isRead: false,
        isUsed: true,
      );
      final newer = QrRecord(
        id: 'guest-unit-101',
        ownerId: 'test-owner-id',
        ownerName: '',
        unit: '101',
        unitNumber: '101',
        type: QrType.guest,
        allowedPersons: 3,
        createdAt: DateTime(2026, 8, 31, 12),
        qrToken: 'guest-token',
        validDate: '2026-08-31',
        isRead: false,
      );
      final session = AppSession(
        linkedOwners: testUnits.take(2).toList(),
        ownerId: 'test-owner-id',
        ownerEmail: 'owner@test.local',
        historyBackend: _FakeHistoryBackend([older, newer]),
      );

      await session.loadActiveUnitHistory();
      expect(session.ownerHistory, [newer]);

      session.markQrRead(newer.id);
      await session.loadActiveUnitHistory();
      expect(session.ownerHistory.first.isRead, isTrue);

      session.switchOwner(session.linkedOwners[1]);
      await session.loadActiveUnitHistory();
      expect(session.ownerHistory, [older]);
      expect(session.ownerHistory.single.isUsed, isTrue);
    },
  );

  test('Home activities include only records created today in Cairo', () {
    final session = testSession();
    final cairoNow = FirebaseGuestQrBackend.egyptTime(
      DateTime.utc(2026, 9, 6, 12),
    );
    final today = QrRecord.create(
      owner: session.activeOwner!,
      type: QrType.guest,
      allowedPersons: 2,
      createdAt: cairoNow.subtract(const Duration(hours: 1)),
    );
    final yesterday = QrRecord.create(
      owner: session.activeOwner!,
      type: QrType.delivery,
      allowedPersons: 1,
      createdAt: cairoNow.subtract(const Duration(days: 1)),
    );
    session.addQrRecord(yesterday);
    session.addQrRecord(today);

    expect(session.todayActiveHistory(now: cairoNow), [today]);
    expect(session.activeHistory, containsAll(<QrRecord>[today, yesterday]));
  });

  testWidgets('home carousel snaps and changes the active unit', (
    tester,
  ) async {
    final session = AppSession(
      linkedOwners: testUnits,
      ownerId: 'test-owner-id',
      ownerEmail: 'owner@test.local',
    );
    await openLogin(tester, session);
    await tester.tap(find.text('تسجيل الدخول'));
    await tester.pumpAndSettle();
    expect(session.activeOwner!.apartment, '101');

    await tester.fling(
      find.byKey(const Key('unit_carousel')),
      const Offset(500, 0),
      1200,
    );
    await tester.pumpAndSettle();
    expect(session.activeOwner!.apartment, isNot('101'));
  });

  testWidgets('single-unit home remains on its only unit', (tester) async {
    const onlyOwner = Owner(
      name: 'مالك واحد',
      buildingNumber: '1',
      floorNumber: '1',
      apartment: '101',
    );
    final session = AppSession(
      linkedOwners: const [onlyOwner],
      ownerId: 'test-owner-id',
      ownerEmail: 'owner@test.local',
    );
    await openLogin(tester, session);
    await tester.tap(find.text('تسجيل الدخول'));
    await tester.pumpAndSettle();

    expect(find.text('101'), findsOneWidget);
    await tester.fling(
      find.byKey(const Key('unit_carousel')),
      const Offset(-500, 0),
      1200,
    );
    await tester.pumpAndSettle();
    expect(session.activeOwner, onlyOwner);
  });

  testWidgets('opening QR details marks read without changing usage', (
    tester,
  ) async {
    final session = testSession();
    session.addQrRecord(
      QrRecord.create(
        owner: session.activeOwner!,
        type: QrType.guest,
        allowedPersons: 2,
        isRead: false,
      ),
    );
    final unread = session.activeHistory.first;
    expect(unread.isRead, isFalse);
    expect(unread.isUsed, isFalse);
    final historyLength = session.activeHistory.length;

    await openLogin(tester, session);
    await tester.tap(find.text('تسجيل الدخول'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Material>(find.byKey(Key('activity_${unread.id}'))).color,
      const Color(0xFFC6E1E4),
    );
    await tester.tap(find.byKey(Key('activity_${unread.id}')));
    await tester.pumpAndSettle();

    expect(find.text('تفاصيل كود الضيافة'), findsOneWidget);
    expect(session.activeHistory.first.isRead, isTrue);
    expect(session.activeHistory.first.isUsed, isFalse);
    expect(session.activeHistory, hasLength(historyLength));
    await tester.tap(find.byIcon(Icons.arrow_back_ios_new));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Material>(find.byKey(Key('activity_${unread.id}'))).color,
      const Color(0xFFE5EEF2),
    );
  });

  testWidgets(
    'guest QR cancellation requires confirmation and updates details',
    (tester) async {
      final backend = _FakeGuestQrBackend();
      final session = AppSession(
        linkedOwners: [testUnits.first],
        ownerId: 'test-owner-id',
        ownerEmail: 'owner@test.local',
        guestQrBackend: backend,
      );
      final created = await session.generateGuestQr(session.activeOwner!, 3);

      await openLogin(tester, session);
      await tester.tap(find.text('تسجيل الدخول'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('activity_${created.record.id}')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('إلغاء الكود'));
      await tester.tap(find.text('إلغاء الكود'));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'هل أنت متأكد من إلغاء هذا الكود؟\nبعد الإلغاء لن يمكن استخدامه للدخول.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('تراجع'));
      await tester.pumpAndSettle();
      expect(backend.reserved[testUnits.first.storageKey], 3);

      await tester.tap(find.text('إلغاء الكود'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('إلغاء الكود').last);
      await tester.pumpAndSettle();

      expect(find.text('تم الإلغاء'), findsOneWidget);
      expect(find.text('إلغاء الكود'), findsNothing);
      expect(backend.reserved[testUnits.first.storageKey], 0);
      expect(session.ownerHistory.first.status, QrStatus.cancelled);
    },
  );

  test('security usage updates independently from read state', () {
    final session = testSession();
    session.addQrRecord(
      QrRecord.create(
        owner: session.activeOwner!,
        type: QrType.delivery,
        allowedPersons: 1,
        isRead: false,
      ),
    );
    final unread = session.activeHistory.first;
    session.updateQrUsage(unread.id, isUsed: true);
    final updated = session.activeHistory.first;
    expect(updated.isRead, isFalse);
    expect(updated.isUsed, isTrue);
  });

  testWidgets('fresh session shows clean Home and History empty states', (
    tester,
  ) async {
    final session = testSession();
    expect(session.activeHistory, isEmpty);
    expect(session.reports, isEmpty);
    await openLogin(tester, session);
    await tester.tap(find.text('تسجيل الدخول'));
    await tester.pumpAndSettle();
    expect(find.text('لا توجد أنشطة لهذه الوحدة حتى الآن'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.calendar_month_outlined));
    await tester.pumpAndSettle();
    expect(find.text('لا توجد أنشطة حتى الآن'), findsOneWidget);
  });

  testWidgets('report validates and submits the selected category', (
    tester,
  ) async {
    final session = testSession();
    await openLogin(tester, session);
    await tester.tap(find.text('تسجيل الدخول'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.report_outlined));
    await tester.pumpAndSettle();

    expect(find.text('إرسال بلاغ'), findsWidgets);
    await tester.ensureVisible(
      find.widgetWithText(FilledButton, 'إرسال البلاغ'),
    );
    await tester.tap(find.widgetWithText(FilledButton, 'إرسال البلاغ'));
    await tester.pump();
    expect(find.text('يرجى كتابة وصف المشكلة أو الطلب'), findsOneWidget);
    expect(session.reports, isEmpty);

    await tester.tap(find.text('مشكلة في QR').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('أخرى').last);
    await tester.enterText(
      find.byType(TextFormField),
      'أرغب في إرسال طلب مخصص إلى الإدارة.',
    );
    await tester.ensureVisible(
      find.widgetWithText(FilledButton, 'إرسال البلاغ'),
    );
    await tester.tap(find.widgetWithText(FilledButton, 'إرسال البلاغ'));
    await tester.pumpAndSettle();

    expect(find.text('تم إرسال الطلب'), findsOneWidget);
    expect(
      find.text('تم إرسال طلبك إلى الإدارة بنجاح وسيتم مراجعته في أقرب وقت.'),
      findsOneWidget,
    );
    expect(session.reports, hasLength(1));
    expect(session.reports.single.category, ReportCategory.other);
    expect(session.reports.single.unitId, session.activeOwner!.storageKey);
    expect(session.reports.single.status, ReportStatus.pending);
    expect(
      session.reports.single.message,
      'أرغب في إرسال طلب مخصص إلى الإدارة.',
    );
  });

  test('reports use the active unit at submission time', () async {
    final backend = _FakeReportBackend();
    final session = AppSession(
      linkedOwners: testUnits.take(2).toList(),
      ownerId: 'test-owner-id',
      ownerEmail: 'owner@test.local',
      reportBackend: backend,
    );

    await session.submitReport(
      category: ReportCategory.general,
      message: '  طلب للوحدة الأولى  ',
    );
    session.switchOwner(session.linkedOwners[1]);
    await session.submitReport(
      category: ReportCategory.unitRequest,
      message: 'طلب للوحدة الثانية',
    );

    expect(backend.records.map((report) => report.unitNumber), ['101', '205']);
    expect(backend.records.first.message, 'طلب للوحدة الأولى');
    expect(
      backend.records.every((report) => report.status == ReportStatus.pending),
      isTrue,
    );
  });

  test(
    'remote sign-in loads the verified profile and every active unit',
    () async {
      final backend = _FakeOwnerBackend(data: _ownerData(testUnits));
      final session = AppSession(backend: backend);
      await session.signIn('owner@example.com', 'password');

      expect(session.isAuthenticated, isTrue);
      expect(session.ownerId, 'firebase-owner-uid');
      expect(session.linkedOwners, testUnits);
      expect(session.activeOwner, testUnits.first);
    },
  );

  test('restored Firebase session revalidates profile and units', () async {
    final backend = _FakeOwnerBackend(data: _ownerData([testUnits.first]));
    final session = AppSession(backend: backend);

    expect(await session.restoreSession(), isTrue);
    expect(session.isAuthenticated, isTrue);
    expect(session.linkedOwners, [testUnits.first]);
  });

  test('valid owner with no units keeps a safe empty unit state', () async {
    final backend = _FakeOwnerBackend(data: _ownerData(const []));
    final session = AppSession(backend: backend);
    await session.signIn('owner@example.com', 'password');

    expect(session.isAuthenticated, isTrue);
    expect(session.hasUnits, isFalse);
    expect(session.activeOwner, isNull);
  });

  test('backend rejection never authenticates the Owner session', () async {
    const rejection = OwnerBackendException('الحساب غير مصرح له.');
    final session = AppSession(backend: _FakeOwnerBackend(error: rejection));

    await expectLater(
      session.signIn('wrong@example.com', 'wrong'),
      throwsA(isA<OwnerBackendException>()),
    );
    expect(session.isAuthenticated, isFalse);
    expect(session.linkedOwners, isEmpty);
  });

  test(
    'logout ends backend session and clears in-memory account data',
    () async {
      final backend = _FakeOwnerBackend(data: _ownerData([testUnits.first]));
      final session = AppSession(backend: backend);
      await session.signIn('owner@example.com', 'password');
      await session.logout();

      expect(backend.didSignOut, isTrue);
      expect(session.isAuthenticated, isFalse);
      expect(session.profile, isNull);
      expect(session.linkedOwners, isEmpty);
    },
  );

  test(
    'Owner API sends the Firebase token and returns real server data',
    () async {
      final client = OwnerApiClient(
        baseUrl: 'https://owner-api.example.test',
        tokenProvider: () async => 'firebase-id-token',
        client: MockClient((request) async {
          expect(request.headers['authorization'], 'Bearer firebase-id-token');
          expect(request.url.path, '/generate-guest-qr');
          return http.Response(jsonEncode({'qrId': 'server-qr'}), 200);
        }),
      );
      expect(
        (await client.post('/generate-guest-qr', {'unitId': 'unit-1'}))['qrId'],
        'server-qr',
      );
    },
  );

  test(
    'Owner API never treats an unauthorized backend response as success',
    () async {
      final client = OwnerApiClient(
        baseUrl: 'https://owner-api.example.test',
        tokenProvider: () async => 'invalid-token',
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({'code': 'permission-denied', 'message': 'رفض الطلب'}),
            403,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ),
        ),
      );
      await expectLater(
        client.post('/generate-guest-qr', {'unitId': 'forged-unit'}),
        throwsA(
          isA<OwnerApiException>().having(
            (error) => error.code,
            'code',
            'permission-denied',
          ),
        ),
      );
    },
  );

  test('Owner API reports a missing production endpoint explicitly', () async {
    final client = OwnerApiClient(
      baseUrl: '',
      tokenProvider: () async => 'firebase-id-token',
    );
    await expectLater(
      client.post('/generate-guest-qr', {'unitId': 'unit-1'}),
      throwsA(
        isA<OwnerApiException>()
            .having((error) => error.code, 'code', 'not-configured')
            .having((error) => error.message, 'message', contains('غير مهيأة')),
      ),
    );
  });
}

OwnerSessionData _ownerData(List<Owner> units) => OwnerSessionData(
  profile: const OwnerProfile(
    uid: 'firebase-owner-uid',
    name: 'مالك Firebase',
    email: 'owner@example.com',
    role: 'owner',
    isActive: true,
  ),
  units: units,
);

class _FakeOwnerBackend implements OwnerBackend {
  _FakeOwnerBackend({this.data, this.error});

  final OwnerSessionData? data;
  final OwnerBackendException? error;
  bool didSignOut = false;

  @override
  Future<OwnerSessionData> signIn(String email, String password) async {
    if (error case final failure?) throw failure;
    return data!;
  }

  @override
  Future<OwnerSessionData?> restoreSession() async {
    if (error case final failure?) throw failure;
    return data;
  }

  @override
  Future<void> signOut() async {
    didSignOut = true;
  }
}

class _FakeGuestQrBackend implements GuestQrBackend, GuestQuotaBackend {
  final List<QrRecord> records = [];
  final Map<String, int> reserved = {};

  @override
  Future<QrRecord?> getToday({required Owner unit}) async =>
      records.where((r) => r.unit == unit.storageKey).firstOrNull;

  @override
  Stream<GuestDailyAllowance> watchAllowance({required Owner unit}) =>
      Stream.value(
        GuestDailyAllowance(reserved: reserved[unit.storageKey] ?? 0),
      );

  @override
  Future<GuestQrResult> generate({
    required Owner unit,
    required int guestCount,
  }) async {
    final used = reserved[unit.storageKey] ?? 0;
    if (used + guestCount > 6) {
      throw const GuestQrException('لا يوجد عدد كافٍ ضمن الحد اليومي للضيوف.');
    }
    final date = FirebaseGuestQrBackend.egyptDate();
    final record = QrRecord(
      id: 'guest_${unit.storageKey}_${records.length + 1}',
      ownerName: unit.name,
      unit: unit.storageKey,
      type: QrType.guest,
      allowedPersons: guestCount,
      createdAt: DateTime.now(),
      qrToken: 'secure-test-token-${unit.storageKey}',
      validDate: date,
    );
    records.add(record);
    reserved[unit.storageKey] = used + guestCount;
    return GuestQrResult(record: record, created: true);
  }

  @override
  Future<void> cancel({required Owner unit, required QrRecord record}) async {
    final index = records.indexWhere((item) => item.id == record.id);
    if (index < 0 || records[index].status != QrStatus.active) {
      throw const GuestQrException('لا يمكن إلغاء كود مستخدم أو غير نشط.');
    }
    records[index] = records[index].copyWith(
      status: QrStatus.cancelled,
      cancelledAt: DateTime.now(),
    );
    reserved[unit.storageKey] =
        ((reserved[unit.storageKey] ?? 0) - record.allowedPersons).clamp(0, 6);
  }
}

class _FakeDeliveryQrBackend implements DeliveryQrBackend {
  final List<QrRecord> records = [];

  @override
  Future<QrRecord> generate({
    required Owner unit,
    required String deliveryType,
  }) async {
    final sequence = records.length + 1;
    final record = QrRecord(
      id: 'delivery-$sequence',
      ownerName: unit.name,
      unit: unit.storageKey,
      type: QrType.delivery,
      allowedPersons: 1,
      createdAt: DateTime.now(),
      qrToken: 'delivery-token-$sequence-${unit.storageKey}',
      validDate: FirebaseGuestQrBackend.egyptDate(),
      deliveryType: deliveryType,
      isRead: false,
    );
    records.add(record);
    return record;
  }
}

class _FakeHistoryBackend implements HistoryBackend {
  _FakeHistoryBackend(this.records);
  final List<QrRecord> records;

  @override
  Future<List<QrRecord>> loadUnitHistory({required String unitId}) async =>
      records.where((record) => record.unit == unitId).toList();
}

class _FakeReportBackend implements ReportBackend {
  final List<OwnerReport> records = [];

  @override
  Future<OwnerReport> createReport({
    required String ownerName,
    required Owner unit,
    required ReportCategory category,
    required String message,
  }) async {
    final report = OwnerReport(
      id: 'report-${records.length + 1}',
      ownerId: 'test-owner-id',
      ownerName: ownerName,
      unitId: unit.storageKey,
      unitNumber: unit.apartment,
      category: category,
      message: message.trim(),
      createdAt: DateTime.now(),
    );
    records.add(report);
    return report;
  }
}
