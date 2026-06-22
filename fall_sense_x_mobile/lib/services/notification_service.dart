import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

class NotificationService {
  static final FlutterLocalNotificationsPlugin _notificationsPlugin =
      FlutterLocalNotificationsPlugin();

  static const AndroidNotificationChannel _offlineChannel = AndroidNotificationChannel(
    'offline_alerts',
    'Device Offline Alerts',
    description: 'Notifications when device goes offline',
    importance: Importance.high,
    enableVibration: true,
    playSound: true,
  );

  /// Request notification permissions (iOS)
  static Future<void> requestPermissions() async {
    await FirebaseMessaging.instance.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );
  }

  /// Initialize local notifications
  static Future<void> initialize() async {
    const AndroidInitializationSettings androidInit =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    
    const InitializationSettings initSettings = 
        InitializationSettings(android: androidInit);
    
    await _notificationsPlugin.initialize(initSettings);
    
    // Create notification channel for Android
    await _notificationsPlugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(_offlineChannel);
  }

  /// Show a local notification
  static Future<void> showNotification({
    required String title,
    required String body,
    required int notificationId,
  }) async {
    const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      'offline_alerts',
      'Device Offline Alerts',
      channelDescription: 'Notifications when device goes offline',
      importance: Importance.high,
      priority: Priority.high,
      enableVibration: true,
      playSound: true,
    );

    const NotificationDetails notificationDetails = 
        NotificationDetails(android: androidDetails);

    await _notificationsPlugin.show(
      notificationId,
      title,
      body,
      notificationDetails,
    );
  }

  /// Handle background message (called by FirebaseMessaging)
  static Future<void> handleBackgroundMessage(RemoteMessage message) async {
    // Show notification when app is in background/terminated
    await showNotification(
      title: message.notification?.title ?? 'FallSenseX',
      body: message.notification?.body ?? '',
      notificationId: message.messageId.hashCode,
    );
  }
}
