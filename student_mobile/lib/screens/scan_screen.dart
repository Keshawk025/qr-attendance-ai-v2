import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'api.dart';

class ScanScreen extends StatefulWidget {
  final String authToken;
  final String usn;
  final String deviceId;

  const ScanScreen({
    super.key,
    required this.authToken,
    required this.usn,
    required this.deviceId,
  });

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  final MobileScannerController _scanner = MobileScannerController(
    formats: [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  final FaceDetector _faceDetector = FaceDetector(
    options: FaceDetectorOptions(
      enableContours: false,
      enableClassification: true,
      performanceMode: FaceDetectorMode.fast,
    ),
  );

  bool _isBusy = false;
  bool _faceVisible = false;
  String _status = 'Scan teacher QR to continue';
  String _diag = '';
  bool _captureMode = false;
  bool _screenFlash = false;
  bool _samplingFace = false;
  bool _captureSucceeded = false;
  String? _pendingQrToken;
  CameraController? _faceCamera;

  @override
  void initState() {
    super.initState();
    _syncPending();
  }

  Future<void> _syncPending() async {
    final synced = await Api.syncQueuedAttendance(
      token: widget.authToken,
      usn: widget.usn,
      deviceId: widget.deviceId,
    );
    if (synced > 0 && mounted) {
      setState(() {
        _status = 'Synced $synced offline attendance record(s).';
      });
    }
  }

  bool _isFaceAcceptable(List<Face> faces) {
    if (faces.length != 1) {
      return false;
    }

    final face = faces.first;
    final box = face.boundingBox;

    // Basic quality gate: keep tiny/partial faces from passing.
    return box.width >= 110 && box.height >= 110;
  }

  Future<String?> _captureFaceImageB64() async {
    final cameras = await availableCameras();
    if (cameras.isEmpty) {
      throw Exception('No camera available. Check camera permission.');
    }
    final front = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.front,
      orElse: () => cameras.first,
    );

    final camera = CameraController(front, ResolutionPreset.medium, enableAudio: false);
    await camera.initialize();

    XFile? faceShot;
    try {
      faceShot = await camera.takePicture();
      final input = InputImage.fromFilePath(faceShot.path);
      final faces = await _faceDetector.processImage(input);
      final faceOk = _isFaceAcceptable(faces);

      if (!faceOk) {
        return null;
      }

      final bytes = await File(faceShot.path).readAsBytes();
      return base64Encode(bytes);
    } finally {
      if (faceShot != null) {
        try {
          await File(faceShot.path).delete();
        } catch (_) {}
      }
      await camera.dispose();
    }
  }

  bool _isFaceInsideGuide(Face face, int imageWidth, int imageHeight) {
    final box = face.boundingBox;
    final cx = (box.left + box.right) / 2;
    final cy = (box.top + box.bottom) / 2;
    final nx = cx / imageWidth;
    final ny = cy / imageHeight;

    final widthRatio = box.width / imageWidth;
    final heightRatio = box.height / imageHeight;
    final centered = (nx - 0.5).abs() < 0.20 && (ny - 0.45).abs() < 0.22;
    final sizeOk = widthRatio > 0.16 && heightRatio > 0.16;
    return centered && sizeOk;
  }

  bool _isLowLight(Uint8List bytes) {
    if (bytes.isEmpty) {
      return false;
    }
    final step = (bytes.length / 500).ceil().clamp(1, bytes.length);
    var sum = 0.0;
    var count = 0;
    for (var i = 0; i < bytes.length; i += step) {
      sum += bytes[i];
      count++;
    }
    final avg = count == 0 ? 255.0 : (sum / count);
    return avg < 75.0;
  }

  Future<void> _triggerScreenFlashIfNeeded(Uint8List bytes) async {
    if (!_isLowLight(bytes) || !mounted) {
      return;
    }
    setState(() => _screenFlash = true);
    await Future.delayed(const Duration(milliseconds: 140));
    if (mounted) {
      setState(() => _screenFlash = false);
    }
  }

  Future<void> _enterCaptureMode(String qrToken) async {
    _pendingQrToken = qrToken;
    _captureMode = true;
    _captureSucceeded = false;
    _faceVisible = false;
    _diag = 'Bring your face in front of the screen';

    final cameras = await availableCameras();
    final front = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.front,
      orElse: () => cameras.first,
    );
    _faceCamera = CameraController(front, ResolutionPreset.medium, enableAudio: false);
    await _faceCamera!.initialize();
    if (mounted) {
      setState(() {
        _status = 'Face mode: bring your face in front of the screen';
      });
    }
  }

  Future<void> _exitCaptureMode() async {
    _captureMode = false;
    _pendingQrToken = null;
    final cam = _faceCamera;
    _faceCamera = null;
    if (cam != null) {
      await cam.dispose();
    }
    if (mounted) {
      setState(() {
        _screenFlash = false;
      });
    }
  }

  Future<void> _sampleAndSubmitFace() async {
    if (_samplingFace || _faceCamera == null || !_faceCamera!.value.isInitialized || _pendingQrToken == null) {
      return;
    }
    _samplingFace = true;
    XFile? shot;
    XFile? precheckShot;
    try {
      var attempts = 0;
      const maxAttempts = 20;

      while (mounted && _captureMode && _pendingQrToken != null && attempts < maxAttempts && !_captureSucceeded) {
        attempts += 1;
        await Future.delayed(const Duration(milliseconds: 300));

        precheckShot = await _faceCamera!.takePicture();
        final precheckInput = InputImage.fromFilePath(precheckShot.path);
        final faces = await _faceDetector.processImage(precheckInput);

        if (!_isFaceAcceptable(faces)) {
          if (mounted) {
            setState(() {
              _faceVisible = false;
              _diag = 'Need one clear face';
            });
          }
          try {
            await File(precheckShot.path).delete();
          } catch (_) {}
          continue;
        }

        final precheckBytes = await File(precheckShot.path).readAsBytes();
        final decoded = await decodeImageFromList(precheckBytes);
        final face = faces.first;
        final inside = _isFaceInsideGuide(face, decoded.width, decoded.height);
        if (!inside) {
          if (mounted) {
            setState(() {
              _faceVisible = false;
              _diag = 'Bring your face in front of the screen';
            });
          }
          try {
            await File(precheckShot.path).delete();
          } catch (_) {}
          continue;
        }

        final isDark = _isLowLight(precheckBytes);
        if (isDark) {
          if (mounted) {
            setState(() {
              _diag = 'Dark place detected. Flashing screen...';
            });
          }
          setState(() => _screenFlash = true);
          await Future.delayed(const Duration(milliseconds: 220));
          if (mounted) {
            setState(() => _screenFlash = false);
          }
        }

        try {
          await File(precheckShot.path).delete();
        } catch (_) {}

        shot = await _faceCamera!.takePicture();
        final bytes = await File(shot.path).readAsBytes();
        final finalInput = InputImage.fromFilePath(shot.path);
        final finalFaces = await _faceDetector.processImage(finalInput);
        if (!_isFaceAcceptable(finalFaces)) {
          if (mounted) {
            setState(() {
              _faceVisible = false;
              _diag = 'Face moved, retrying capture...';
            });
          }
          try {
            await File(shot.path).delete();
          } catch (_) {}
          shot = null;
          continue;
        }

        if (mounted) {
          setState(() {
            _faceVisible = true;
            _diag = 'Face aligned. Submitting...';
          });
        }

        final faceImageB64 = base64Encode(bytes);
        final res = await Api.markAttendance(
          token: widget.authToken,
          usn: widget.usn,
          deviceId: widget.deviceId,
          qrToken: _pendingQrToken!,
          faceDetected: true,
          faceImageB64: faceImageB64,
        );

        _captureSucceeded = true;
        await _exitCaptureMode();
        if (mounted) {
          setState(() {
            _status = 'Attendance marked for session ${res['session_id']}';
            _diag = 'Live submit succeeded';
          });
        }
        await HapticFeedback.heavyImpact();
        break;
      }

      if (!_captureSucceeded && mounted) {
        setState(() {
          _diag = 'Bring your face in front of the screen';
        });
      }
    } catch (e) {
      final message = e.toString().replaceFirst('Exception: ', '');
      final isConnectivityIssue = message.toLowerCase().contains('timeout') ||
          message.toLowerCase().contains('connection') ||
          message.toLowerCase().contains('socket');

      if (isConnectivityIssue && shot != null) {
        try {
          final bytes = await File(shot.path).readAsBytes();
          await Api.queueAttendance({
            'qr_token': _pendingQrToken,
            'face_detected': true,
            'face_image_b64': base64Encode(bytes),
          });
        } catch (_) {}
      }

      await _exitCaptureMode();
      if (mounted) {
        setState(() {
          _status = isConnectivityIssue
              ? 'Network issue: queued offline and will auto-sync later.'
              : message;
          _diag = isConnectivityIssue ? 'Queued for offline sync' : 'Server rejected request';
        });
      }
      await _scanner.start();
    } finally {
      if (precheckShot != null) {
        try {
          await File(precheckShot.path).delete();
        } catch (_) {}
      }
      if (shot != null) {
        try {
          await File(shot.path).delete();
        } catch (_) {}
      }
      _samplingFace = false;
      _isBusy = false;
    }
  }

  Future<void> _onDetected(BarcodeCapture capture) async {
    if (_isBusy) return;

    final code = capture.barcodes
        .map((b) => b.rawValue)
        .whereType<String>()
        .firstWhere((v) => v.isNotEmpty, orElse: () => '');
    if (code == null || code.isEmpty) {
      return;
    }

    setState(() {
      _isBusy = true;
      _status = 'QR detected. Validating face and marking attendance...';
    });
    await HapticFeedback.mediumImpact();
    try {
      await _scanner.stop();
      await _enterCaptureMode(code);
      await _sampleAndSubmitFace();
    } catch (e) {
      setState(() {
        _status = e.toString().replaceFirst('Exception: ', '');
        _diag = 'Capture start failed';
      });
      await _exitCaptureMode();
      await _scanner.start();
    }
  }

  @override
  void dispose() {
    _faceCamera?.dispose();
    _scanner.dispose();
    _faceDetector.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: const Text('Scan Attendance QR'),
      ),
      body: Stack(
        children: [
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF05080F), Color(0xFF0A1E35), Color(0xFF083B40)],
              ),
            ),
          ),
          MobileScanner(
            controller: _scanner,
            onDetect: _onDetected,
          ),
          if (_captureMode && _faceCamera != null && _faceCamera!.value.isInitialized)
            Positioned.fill(
              child: Stack(
                children: [
                  CameraPreview(_faceCamera!),
                ],
              ),
            ),
          if (_screenFlash)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(color: Colors.white),
              ),
            ),
          IgnorePointer(
            child: Center(
              child: Container(
                width: 240,
                height: 240,
                decoration: BoxDecoration(
                  border: Border.all(color: const Color(0xA6B6DEFF), width: _captureMode ? 0 : 2),
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: const Color(0x66213857),
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: const Color(0x332C4B7A)),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          'Bring your face in front of the screen',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          _status,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Color(0xFFCDE2FF)),
                        ),
                        if (_diag.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                              _diag,
                              style: const TextStyle(fontSize: 12, color: Color(0x80CDE2FF)),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
