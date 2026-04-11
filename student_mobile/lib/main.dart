import 'package:flutter/material.dart';

import 'screens/login_screen.dart';

void main() {
  runApp(const StudentAttendanceApp());
}

class StudentAttendanceApp extends StatelessWidget {
  const StudentAttendanceApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Student Attendance',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1C78D4),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF060B14),
        inputDecorationTheme: const InputDecorationTheme(
          filled: true,
          fillColor: Color(0x221C2B4A),
          border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(14))),
        ),
        useMaterial3: true,
      ),
      home: const LoginScreen(),
    );
  }
}
