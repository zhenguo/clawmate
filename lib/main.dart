import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  WakelockPlus.enable();
  runApp(const ProviderScope(child: App()));
}
