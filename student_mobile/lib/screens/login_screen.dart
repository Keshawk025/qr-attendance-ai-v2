import 'dart:math';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'scan_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _usnCtrl = TextEditingController();
  bool _loading = false;
  bool _initializing = true;
  String? _error;
  String? _deviceId;
  bool _autoAttempted = false;

  @override
  void initState() {
    super.initState();
    _restoreSession();
  }

  @override
  void dispose() {
    _usnCtrl.dispose();
    super.dispose();
  }

  String _generateDeviceId() {
    final rand = Random.secure();
    final bytes = List<int>.generate(12, (_) => rand.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  Future<void> _restoreSession() async {
    final prefs = await SharedPreferences.getInstance();
    var deviceId = prefs.getString('device_id');
    if (deviceId == null || deviceId.length < 8) {
      deviceId = _generateDeviceId();
      await prefs.setString('device_id', deviceId);
    }

    final lastUsn = prefs.getString('last_usn');
    final discovered = await Api.autoDiscoverServer();
    if (discovered != null) {
    } else {
      _error = 'No backend found yet. Start the backend and stay on the same Wi-Fi.';
    }
    if (lastUsn != null && lastUsn.isNotEmpty) {
      _usnCtrl.text = lastUsn;
    }

    setState(() {
      _deviceId = deviceId;
      _initializing = false;
    });

    if (!_autoAttempted && lastUsn != null && lastUsn.isNotEmpty) {
      _autoAttempted = true;
      await _login(auto: true);
    }
  }

  Future<void> _login({bool auto = false}) async {
    if (!auto && !_formKey.currentState!.validate()) {
      return;
    }
    if (_deviceId == null) {
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final usn = _usnCtrl.text.trim();
      final res = await Api.studentLogin(
        usn: usn,
        deviceId: _deviceId!,
      );

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('last_usn', usn);
      await prefs.setString('auth_token', res['access_token'] as String);

      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => ScanScreen(
            authToken: res['access_token'] as String,
            usn: res['usn'] as String,
            deviceId: _deviceId!,
          ),
        ),
      );
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF04060B), Color(0xFF0C1A2D), Color(0xFF0A2A33)],
          ),
        ),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                  child: Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: const Color(0x66213857),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: const Color(0x332C4B7A)),
                    ),
                    child: Form(
                      key: _formKey,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text(
                            'Student Login',
                            style: TextStyle(fontSize: 28, fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 16),
                          TextFormField(
                            controller: _usnCtrl,
                            decoration: const InputDecoration(labelText: 'USN'),
                            validator: (v) => (v == null || v.trim().isEmpty) ? 'Enter USN' : null,
                          ),
                          const SizedBox(height: 10),
                          const SizedBox(height: 18),
                          if (_error != null) Text(_error!, style: const TextStyle(color: Colors.redAccent)),
                          const SizedBox(height: 8),
                          SizedBox(
                            width: double.infinity,
                            child: FilledButton(
                              onPressed: (_loading || _initializing || _deviceId == null) ? null : () => _login(),
                              child: Text(
                                _initializing
                                    ? 'Preparing device...'
                                    : _loading
                                        ? 'Signing in...'
                                        : 'Continue',
                              ),
                            ),
                          ),
                          if (_deviceId != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 12),
                              child: Text(
                                'Device locked: ${_deviceId!.substring(0, 8)}…',
                                style: const TextStyle(fontSize: 12, color: Color(0x99CDE2FF)),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
