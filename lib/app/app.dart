import 'package:flutter/material.dart';

import '../features/owner/contact_admin/contact_admin_screen.dart';
import '../features/owner/history/hospitality_history_screen.dart';
import '../features/owner/home/home_screen.dart';
import '../features/owner/hospitality/hospitality_screen.dart';
import '../features/owner/login/login_screen.dart';
import '../features/owner/profile/profile_screen.dart';
import '../features/owner/qr/qr_screen.dart';
import '../features/owner/report/report_screen.dart';
import '../features/splash/splash_screen.dart';
import '../models/owner.dart';
import '../services/owner_backend.dart';
import '../services/owner_api_client.dart';
import '../services/report_backend.dart';
import '../services/history_backend.dart';
import '../services/guest_qr_backend.dart';
import '../services/delivery_qr_backend.dart';
import '../state/app_session.dart';
import 'routes.dart';
import 'theme.dart';

class HolidayResortApp extends StatefulWidget {
  const HolidayResortApp({super.key, this.session});

  final AppSession? session;

  @override
  State<HolidayResortApp> createState() => _HolidayResortAppState();
}

class _HolidayResortAppState extends State<HolidayResortApp> {
  late final OwnerApiClient _ownerApi = OwnerApiClient();
  late final AppSession _session =
      widget.session ??
      AppSession(
        backend: FirebaseOwnerBackend(),
        guestQrBackend: FirebaseGuestQrBackend(api: _ownerApi),
        deliveryQrBackend: FirebaseDeliveryQrBackend(api: _ownerApi),
        historyBackend: FirebaseHistoryBackend(),
        reportBackend: FirebaseReportBackend(),
      );

  @override
  void dispose() {
    if (widget.session == null) _session.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AppSessionScope(
    session: _session,
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Holiday Resort',
      theme: buildTheme(),
      locale: const Locale('ar'),
      builder: (context, child) =>
          Directionality(textDirection: TextDirection.rtl, child: child!),
      initialRoute: AppRoutes.splash,
      routes: {
        AppRoutes.splash: (_) => const SplashScreen(),
        AppRoutes.login: (_) => const LoginScreen(),
        AppRoutes.contact: (_) => const ContactAdminScreen(),
        AppRoutes.home: (_) => const HomeScreen(),
        AppRoutes.report: (_) => const ReportScreen(),
        AppRoutes.hospitality: (_) => const HospitalityScreen(),
        AppRoutes.history: (_) => const HospitalityHistoryScreen(),
      },
      onGenerateRoute: (settings) {
        if (settings.name == AppRoutes.profile) {
          return PageRouteBuilder<void>(
            settings: settings,
            opaque: false,
            barrierColor: Colors.transparent,
            barrierDismissible: false,
            transitionDuration: const Duration(milliseconds: 320),
            reverseTransitionDuration: const Duration(milliseconds: 240),
            pageBuilder: (_, _, _) => const ProfileScreen(),
            transitionsBuilder: (_, animation, _, child) => SlideTransition(
              position: Tween(begin: const Offset(0, 1), end: Offset.zero)
                  .chain(CurveTween(curve: Curves.easeOutCubic))
                  .animate(animation),
              child: child,
            ),
          );
        }
        if (settings.name == AppRoutes.qr) {
          return MaterialPageRoute<void>(
            settings: settings,
            builder: (context) {
              final argument = settings.arguments;
              final session = AppSessionScope.of(context, listen: false);
              final owner = session.activeOwner;
              if (owner == null) {
                return const Scaffold(
                  body: Center(
                    child: Text('لا توجد وحدة مرتبطة بالحساب لإنشاء كود QR.'),
                  ),
                );
              }
              final record = argument is QrRecord
                  ? argument
                  : QrRecord.create(
                      owner: owner,
                      type: QrType.guest,
                      allowedPersons: argument as int? ?? 1,
                    );
              return QrScreen(
                record: record,
                recordOnOpen: record.validDate == null,
                showCreatedMessage: true,
              );
            },
          );
        }
        return null;
      },
    ),
  );
}
