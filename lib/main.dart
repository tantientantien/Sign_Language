import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:convert';
import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:udp/udp.dart';
import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart';
import 'pages/sign_list_screen.dart';
import 'package:flutter_tts/flutter_tts.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.black, // Màu nền của status bar
    statusBarIconBrightness: Brightness.light, // Màu biểu tượng (trắng)
  ));
  final cameras = await availableCameras();
  runApp(MyApp(cameras: cameras));
}

class MyApp extends StatelessWidget {
  final List<CameraDescription> cameras;

  const MyApp({super.key, required this.cameras});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: VideoStreamClient(cameras: cameras),
    );
  }
}

class VideoStreamClient extends StatefulWidget {
  final List<CameraDescription> cameras;

  const VideoStreamClient({super.key, required this.cameras});

  @override
  _VideoStreamClientState createState() => _VideoStreamClientState();
}

class _VideoStreamClientState extends State<VideoStreamClient> {
  late CameraController _cameraController;
  bool _isStreaming = false;
  late UDP _udpSender;
  Timer? _sendTimer;
  int _frameId = 0;
  String _serverMessage = '';
  String? _previousMessage;

  // Server configuration
  String serverIp = '10.10.66.192';
  int serverPort = 9999;
  final int bufferSize = 4096;

  // Add these variables to handle camera switch and audio toggle
  bool _isCameraSwitched = false;
  bool _isAudioEnabled = false;

  // Thêm biến để theo dõi camera hiện tại
  int _currentCameraIndex = 0;

  late FlutterTts _flutterTts;

  @override
  void initState() {
    super.initState();
    _flutterTts = FlutterTts();
    // Initialize camera
    _initializeCamera();
    // Initialize UDP sender và listener
    _initializeUDPSender();
  }

  Future<void> _initializeCamera() async {
    _cameraController = CameraController(
      widget.cameras[0],
      ResolutionPreset.low,
      enableAudio: false,
    );

    try {
      await _cameraController.initialize();
      setState(() {});
    } catch (e) {
      print('Error initializing camera: $e');
    }
  }

  Future<void> _initializeUDPSender() async {
    try {
      _udpSender = await UDP.bind(Endpoint.any(port: const Port(0)));
      print('UDP Sender initialized');

      // Thêm listener để nhận dữ liệu từ server
      _udpSender.asStream().listen((datagram) {
        if (datagram == null) return;

        // Sử dụng utf8.decode để giải mã dữ liệu đúng cách
        String message = utf8.decode(datagram.data, allowMalformed: true);
        print('Nhận được từ server: $message');
        setState(() {
          _serverMessage = message;
          if (_isAudioEnabled && message != _previousMessage) {
            _speak(_serverMessage);
            _previousMessage = message;
          }
        });
      });

      print('UDP Listener đã được thiết lập để nhận dữ liệu từ server');
    } catch (e) {
      print('Error initializing UDP sender: $e');
    }
  }

  @override
  void dispose() {
    _cameraController.dispose();
    _udpSender.close();
    _sendTimer?.cancel();
    super.dispose();
  }

  void _startStreaming() {
    if (_isStreaming) return;
    setState(() {
      _isStreaming = true;
    });

    _sendTimer =
        Timer.periodic(const Duration(milliseconds: 50), (timer) async {
      if (!_isStreaming) return;
      await _sendFrame();
    });
  }

  void _stopStreaming() {
    if (!_isStreaming) return;
    setState(() {
      _isStreaming = false;
    });
    _sendTimer?.cancel();
  }

  Future<void> _sendFrame() async {
    if (!_cameraController.value.isInitialized) {
      print('Camera not initialized');
      return;
    }

    try {
      XFile file = await _cameraController.takePicture();
      Uint8List imageBytes = await file.readAsBytes();

      // Decode image to reduce quality
      img.Image? image = img.decodeImage(imageBytes);
      if (image == null) {
        print('Could not decode image');
        return;
      }

      // Resize image if necessary
      img.Image resizedImage = img.copyResize(image, width: 320, height: 320);

      // Encode to JPEG with quality 50
      Uint8List jpegBytes =
          Uint8List.fromList(img.encodeJpg(resizedImage, quality: 50));

      // Fragment data into UDP packets
      int maxDataSize = bufferSize - 12; // 12 bytes for header and footer
      int totalPackets = (jpegBytes.length / maxDataSize).ceil();

      print('Sending frame $_frameId with $totalPackets packets');

      for (int i = 0; i < totalPackets; i++) {
        int start = i * maxDataSize;
        int end = start + maxDataSize;
        if (end > jpegBytes.length) end = jpegBytes.length;
        Uint8List chunk = jpegBytes.sublist(start, end);

        // Header: 4 bytes frame_id, 4 bytes packet_id
        ByteData headerData = ByteData(8);
        headerData.setUint32(0, _frameId, Endian.big);
        headerData.setUint32(4, i, Endian.big);
        Uint8List header = headerData.buffer.asUint8List();

        // Create packet
        Uint8List packet = Uint8List(header.length + chunk.length)
          ..setRange(0, header.length, header)
          ..setRange(header.length, header.length + chunk.length, chunk);

        // Send packet
        await _udpSender.send(
            packet,
            Endpoint.unicast(InternetAddress(serverIp),
                port: Port(serverPort)));
        print('Sent packet $i for frame $_frameId');
      }

      // Send footer: 4 bytes frame_id, 4 bytes packet_id = 0xFFFFFFFF, 4 bytes total_packets
      ByteData footerData = ByteData(12);
      footerData.setUint32(0, _frameId, Endian.big);
      footerData.setUint32(4, 0xFFFFFFFF, Endian.big);
      footerData.setUint32(8, totalPackets, Endian.big);
      Uint8List footer = footerData.buffer.asUint8List();

      await _udpSender.send(footer,
          Endpoint.unicast(InternetAddress(serverIp), port: Port(serverPort)));
      print('Sent footer for frame $_frameId');

      _frameId++;
    } catch (e) {
      print('Error sending frame: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_cameraController.value.isInitialized) {
      return const MaterialApp(
        home: Scaffold(
          body: Center(
            child: CircularProgressIndicator(),
          ),
        ),
      );
    }

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Builder(
        builder: (context) => Scaffold(
          appBar: AppBar(
            toolbarHeight: 100,
            title: const Text('Ngôn Ngữ Ký Hiệu',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.bold)),
            backgroundColor: Colors.black,
            actions: [
              IconButton(
                icon: Icon(
                  _isAudioEnabled ? Icons.volume_up : Icons.volume_off,
                  size: 20,
                ),
                onPressed: _toggleAudio,
                color: _isAudioEnabled ? const Color(0xFFF9D317) : Colors.white,
              ),
              IconButton(
                icon: const Icon(Icons.settings, size: 20),
                onPressed: () => _navigateToSettingsScreen(context),
                color: Colors.white,
              ),
            ],
          ),
          body: SafeArea(
            child: Column(
              children: [
                // Xem trước camera với chiều cao linh hoạt
                SizedBox(
                  width: double.infinity,
                  height: MediaQuery.of(context).size.height *
                      0.6, // 60% chiều cao màn hình
                  child: Transform(
                    // Áp dụng scaleX: -1 để lật ngược theo chiều ngang
                    transform: Matrix4.identity()..scale(1.0, 1.0, 1.0),
                    alignment: Alignment.center,
                    child: CameraPreview(_cameraController),
                  ),
                ),

                // Thêm hiển thị _serverMessage
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(8.0),
                  color: Colors.black,
                  child: Text(
                    _serverMessage,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Color(0xFFF9D317),
                      fontSize: 18,
                    ),
                  ),
                ),

                // Nút Start và Switch Camera ở trung tâm
                Expanded(
                  child: Container(
                    color: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 20.0),
                    child: Center(
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          ElevatedButton(
                              onPressed: _navigateToNewScreen,
                              style: ElevatedButton.styleFrom(
                                shape: const CircleBorder(),
                                padding: const EdgeInsets.all(8),
                                backgroundColor:
                                    const Color.fromRGBO(128, 128, 128, 0.2),
                              ),
                              child: const Icon(
                                Icons.search,
                                color: Colors.white,
                                size: 15,
                              )),
                          const SizedBox(width: 50),
                          ElevatedButton(
                            onPressed:
                                _isStreaming ? _stopStreaming : _startStreaming,
                            style: ElevatedButton.styleFrom(
                              shape: const CircleBorder(),
                              padding: const EdgeInsets.all(25),
                              backgroundColor: _isStreaming
                                  ? const Color(
                                      0xFFdf2a15) // Màu đỏ khi đang truyền
                                  : const Color.fromRGBO(
                                      128, 128, 128, 0.2), // Màu mặc định
                              side: BorderSide(
                                color: Colors.white, // Viền trắng
                                width: _isStreaming
                                    ? 8
                                    : 5, // Viền dày hơn khi đang truyền
                              ),
                            ),
                            child: const SizedBox(
                                width: 20,
                                height: 20), // Container trống không có icon
                          ),
                          const SizedBox(width: 50),
                          ElevatedButton(
                              onPressed: _switchCamera,
                              style: ElevatedButton.styleFrom(
                                shape: const CircleBorder(),
                                padding: const EdgeInsets.all(8),
                                backgroundColor:
                                    const Color.fromRGBO(128, 128, 128, 0.2),
                              ),
                              child: const Icon(
                                Icons.switch_camera_outlined,
                                color: Colors.white,
                                size: 15,
                              )),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // Add these methods to handle camera switch and audio toggle
  void _switchCamera() async {
    if (widget.cameras.length < 2) {
      // Không có nhiều camera để chuyển đổi
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Không có camera phụ để chuyển đổi.')),
      );
      return;
    }

    setState(() {
      _isCameraSwitched = !_isCameraSwitched;
      _currentCameraIndex = (_currentCameraIndex + 1) % widget.cameras.length;
    });

    try {
      await _cameraController.dispose();
      _cameraController = CameraController(
        widget.cameras[_currentCameraIndex],
        ResolutionPreset.low,
        enableAudio: _isAudioEnabled,
      );

      await _cameraController.initialize();
      setState(() {});
      print('Chuyển đổi sang camera $_currentCameraIndex');
    } catch (e) {
      print('Lỗi khi chuyển đổi camera: $e');
    }
  }

  void _toggleAudio() {
    setState(() {
      _isAudioEnabled = !_isAudioEnabled;
      if (_isAudioEnabled) {
        if (_serverMessage != _previousMessage) {
          _speak(_serverMessage);
          _previousMessage = _serverMessage;
        }
      }
    });
  }

  void _navigateToSettingsScreen(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => SettingsScreen(
          serverIp: serverIp,
          serverPort: serverPort,
          onSettingsChanged: (newIp, newPort) {
            setState(() {
              serverIp = newIp;
              serverPort = newPort;
            });
          },
        ),
      ),
    );
  }

  void _navigateToNewScreen() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => const SignListScreen(),
      ),
    );
  }

  Future<void> _speak(String text) async {
    await _flutterTts.setLanguage("vi-VN");
    await _flutterTts.setPitch(1.0);
    await _flutterTts.speak(text);
  }
}

// New screen for settings
class SettingsScreen extends StatelessWidget {
  final String serverIp;
  final int serverPort;
  final Function(String, int) onSettingsChanged;

  const SettingsScreen({
    super.key,
    required this.serverIp,
    required this.serverPort,
    required this.onSettingsChanged,
  });

  @override
  Widget build(BuildContext context) {
    TextEditingController ipController = TextEditingController(text: serverIp);
    TextEditingController portController =
        TextEditingController(text: serverPort.toString());

    return Scaffold(
      appBar: AppBar(
        title: const Text('Cài đặt Server'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            TextField(
              controller: ipController,
              decoration: const InputDecoration(labelText: 'Địa chỉ IP'),
            ),
            TextField(
              controller: portController,
              decoration: const InputDecoration(labelText: 'Cổng'),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: () {
                onSettingsChanged(ipController.text,
                    int.tryParse(portController.text) ?? serverPort);
                Navigator.pop(context);
              },
              child: const Text('Lưu'),
            ),
          ],
        ),
      ),
    );
  }
}
