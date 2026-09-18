import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:test_app/app/app.dart';

import 'firebase_options.dart';
import 'version/app_version_gate.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  runApp(const AppVersionGate(app: 'owner', child: HolidayResortApp()));
}
