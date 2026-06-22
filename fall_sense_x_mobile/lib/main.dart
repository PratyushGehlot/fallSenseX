import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:fall_sense_x_mobile/services/notification_service.dart';
import 'services/auth_service.dart';
import 'pages/login_page.dart';
import 'pages/find_device_page.dart';
import 'pages/dashboard_page.dart';
import 'firebase_options.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  await NotificationService.initialize();
  FirebaseMessaging.onBackgroundMessage(NotificationService.handleBackgroundMessage);
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Fall Sense X',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const AuthWrapper(),
      routes: {
        '/login': (_) => const LoginPage(),
        '/devices': (context) {
          final authService = AuthService();
          return FindDevicePage(userId: authService.currentUser()?.uid);
        },
        '/dashboard': (context) {
          final args = ModalRoute.of(context)?.settings.arguments as Map<String, dynamic>?;
          return DashboardPage(deviceId: args?['deviceId'] ?? 'FallSense_X1');
        },
      },
    );
  }
}

class AuthWrapper extends StatelessWidget {
  const AuthWrapper({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder(
      stream: AuthService().authStateChanges(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        if (snapshot.hasData) {
          return const FindDevicePage(userId: null);
        }
        return const LoginPage();
      },
    );
  }
}