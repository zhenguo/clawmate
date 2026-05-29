import 'package:flutter/material.dart';

import 'features/connections/screens/connections_list_screen.dart';

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ClawMate',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.blue,
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: const ConnectionsListScreen(),
    );
  }
}
