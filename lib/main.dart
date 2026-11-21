import 'package:flutter/material.dart';

import 'pages/lan_page.dart';
import 'pages/settings_page.dart';
import 'pages/tools_page.dart';
import 'pages/wifi_page.dart';
import 'theme.dart';

void main() {
  runApp(const NetProbeApp());
}

class NetProbeApp extends StatelessWidget {
  const NetProbeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '网络工具箱',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: const HomeShell(),
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  static const _pages = [
    WifiPage(),
    LanPage(),
    ToolsPage(),
    SettingsPage(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _index, children: _pages),
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: AppColors.border, width: 1)),
        ),
        child: SafeArea(
          top: false,
          child: BottomNavigationBar(
            currentIndex: _index,
            onTap: (i) => setState(() => _index = i),
            items: const [
              BottomNavigationBarItem(icon: Icon(Icons.wifi_rounded), label: 'WiFi'),
              BottomNavigationBarItem(icon: Icon(Icons.router_outlined), label: '局域网'),
              BottomNavigationBarItem(icon: Icon(Icons.terminal_rounded), label: '工具'),
              BottomNavigationBarItem(icon: Icon(Icons.tune_rounded), label: '设置'),
            ],
          ),
        ),
      ),
    );
  }
}
