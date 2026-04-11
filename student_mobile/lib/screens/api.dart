import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class Api {
  static const defaultPort = 8000;
  static const _baseUrlKey = 'server_base_url';
  static const _pendingQueueKey = 'pending_attendance_queue';
  static const Duration timeout = Duration(seconds: 10);
  static const Duration discoveryTimeout = Duration(milliseconds: 700);

  static Future<String> getBaseUrl() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_baseUrlKey);
    if (saved == null || saved.trim().isEmpty) {
      return 'http://10.212.19.217:$defaultPort';
    }
    return saved.trim();
  }

  static Future<void> setBaseUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_baseUrlKey, url.trim());
  }

  static Future<bool> checkHealth([String? overrideUrl]) async {
    return checkHealthAt(overrideUrl);
  }

  static Future<bool> checkHealthAt(String? overrideUrl, {Duration? timeoutOverride}) async {
    try {
      final base = overrideUrl ?? await getBaseUrl();
      final res = await http.get(Uri.parse('$base/health')).timeout(timeoutOverride ?? timeout);
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  static Future<String?> _probeCandidates(List<String> candidates, {int batchSize = 16}) async {
    for (var i = 0; i < candidates.length; i += batchSize) {
      final batch = candidates.skip(i).take(batchSize).toList();
      final results = await Future.wait(
        batch.map((url) => checkHealthAt(url, timeoutOverride: discoveryTimeout)),
      );
      for (var j = 0; j < results.length; j++) {
        if (results[j]) {
          return batch[j];
        }
      }
    }
    return null;
  }

  static Future<List<String>> _localSubnetCandidates() async {
    final urls = <String>[];
    final seen = <String>{};

    void addHost(String host) {
      final url = 'http://$host:$defaultPort';
      if (seen.add(url)) {
        urls.add(url);
      }
    }

    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          final octets = addr.address.split('.');
          if (octets.length != 4) continue;
          final prefix = '${octets[0]}.${octets[1]}.${octets[2]}';
          for (var host = 1; host <= 254; host++) {
            addHost('$prefix.$host');
          }
        }
      }
    } catch (_) {}

    return urls;
  }

  static Future<String?> autoDiscoverServer() async {
    final saved = await getBaseUrl();
    final localSubnet = await _localSubnetCandidates();
    final candidates = <String>[
      saved,
      'http://10.0.2.2:$defaultPort',
      'http://127.0.0.1:$defaultPort',
      'http://localhost:$defaultPort',
      'http://192.168.0.1:$defaultPort',
      'http://192.168.0.2:$defaultPort',
      'http://192.168.1.1:$defaultPort',
      'http://192.168.1.2:$defaultPort',
      'http://192.168.29.1:$defaultPort',
      'http://192.168.43.1:$defaultPort',
      'http://192.168.100.1:$defaultPort',
      'http://10.0.0.1:$defaultPort',
      'http://10.0.0.2:$defaultPort',
      'http://10.0.1.1:$defaultPort',
      'http://10.1.1.1:$defaultPort',
      'http://172.16.0.1:$defaultPort',
      'http://172.16.1.1:$defaultPort',
      'http://172.17.0.1:$defaultPort',
      'http://172.18.0.1:$defaultPort',
      'http://172.19.0.1:$defaultPort',
      'http://172.20.0.1:$defaultPort',
      'http://172.21.0.1:$defaultPort',
      'http://172.22.0.1:$defaultPort',
      'http://172.23.0.1:$defaultPort',
      'http://172.24.0.1:$defaultPort',
      'http://172.25.0.1:$defaultPort',
      'http://172.26.0.1:$defaultPort',
      'http://172.27.0.1:$defaultPort',
      'http://172.28.0.1:$defaultPort',
      'http://172.29.0.1:$defaultPort',
      'http://172.30.0.1:$defaultPort',
      'http://172.31.0.1:$defaultPort',
      ...localSubnet,
    ];

    final found = await _probeCandidates(candidates);
    if (found != null) {
      await setBaseUrl(found);
      return found;
    }
    return null;
  }

  static Future<Map<String, dynamic>> studentLogin({
    required String usn,
    required String deviceId,
  }) async {
    var baseUrl = await getBaseUrl();
    if (!await checkHealthAt(baseUrl, timeoutOverride: discoveryTimeout)) {
      final discovered = await autoDiscoverServer();
      if (discovered == null) {
        throw Exception('No reachable backend found. Start the backend and stay on the same Wi-Fi.');
      }
      baseUrl = discovered;
    }
    final res = await http.post(
      Uri.parse('$baseUrl/auth/student/login'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'usn': usn, 'device_id': deviceId}),
    ).timeout(timeout, onTimeout: () {
      throw Exception('Connection timeout. Check if backend is running on 0.0.0.0.');
    });

    final body = jsonDecode(res.body) as Map<String, dynamic>;
    if (res.statusCode >= 400) {
      throw Exception(body['detail'] ?? 'Login failed');
    }
    return body;
  }

  static Future<Map<String, dynamic>> markAttendance({
    required String token,
    required String usn,
    required String deviceId,
    required String qrToken,
    required bool faceDetected,
    required String? faceImageB64,
  }) async {
    final baseUrl = await getBaseUrl();
    final res = await http.post(
      Uri.parse('$baseUrl/attendance/mark'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode({
        'qr_token': qrToken,
        'usn': usn,
        'device_id': deviceId,
        'face_detected': faceDetected,
        'face_image_b64': faceImageB64,
      }),
    ).timeout(timeout, onTimeout: () {
      throw Exception('Connection timeout. Check if backend is running.');
    });

    final body = jsonDecode(res.body) as Map<String, dynamic>;
    if (res.statusCode >= 400) {
      throw Exception(body['detail'] ?? 'Attendance failed');
    }
    return body;
  }

  static Future<void> queueAttendance(Map<String, dynamic> payload) async {
    final prefs = await SharedPreferences.getInstance();
    final current = prefs.getStringList(_pendingQueueKey) ?? [];
    current.add(jsonEncode(payload));
    await prefs.setStringList(_pendingQueueKey, current);
  }

  static Future<int> syncQueuedAttendance({
    required String token,
    required String usn,
    required String deviceId,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final current = prefs.getStringList(_pendingQueueKey) ?? [];
    if (current.isEmpty) {
      return 0;
    }

    final remaining = <String>[];
    var synced = 0;

    for (final raw in current) {
      try {
        final item = jsonDecode(raw) as Map<String, dynamic>;
        await markAttendance(
          token: token,
          usn: usn,
          deviceId: deviceId,
          qrToken: item['qr_token'] as String,
          faceDetected: item['face_detected'] as bool,
          faceImageB64: item['face_image_b64'] as String?,
        );
        synced += 1;
      } on SocketException {
        remaining.add(raw);
      } catch (_) {
        // Keep failed records for retry unless server confirms permanent error.
        remaining.add(raw);
      }
    }

    await prefs.setStringList(_pendingQueueKey, remaining);
    return synced;
  }
}
