import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:convert'; // Thêm dòng này
import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:udp/udp.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
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

  // Server configuration
  String serverIp = '10.10.66.192';
  int serverPort = 9999;
  final int bufferSize = 4096;

  // Add these variables to handle camera switch and audio toggle
  bool _isCameraSwitched = false;
  bool _isAudioEnabled = false;

  @override
  void initState() {
    super.initState();
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

    // Start a periodic timer to send frames every 500 milliseconds
    _sendTimer =
        Timer.periodic(const Duration(milliseconds: 500), (timer) async {
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
            title: const Text('Sign Language',
                style: TextStyle(color: Colors.white)),
            backgroundColor: Colors.black,
            actions: [
              IconButton(
                icon: const Icon(Icons.switch_camera),
                onPressed: _switchCamera,
                color:
                    _isCameraSwitched ? const Color(0xFFF9D317) : Colors.white,
              ),
              IconButton(
                icon:
                    Icon(_isAudioEnabled ? Icons.volume_up : Icons.volume_off),
                onPressed: _toggleAudio,
                color: _isAudioEnabled ? const Color(0xFFF9D317) : Colors.white,
              ),
              IconButton(
                icon: const Icon(Icons.settings),
                onPressed: () => _navigateToSettingsScreen(context),
                color: Colors.white,
              ),
            ],
          ),
          body: SafeArea(
            child: Column(
              children: [
                // Xem trước camera đầy màn hình với tỷ lệ 4:3
                SizedBox(
                  width: double.infinity,
                  child: Transform(
                    // Áp dụng scaleX: -1 để lật ngược theo chiều ngang
                    transform: Matrix4.identity()..scale(-1.0, 1.0, 1.0),
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

                // Nút đơn ở trung tâm
                Expanded(
                  child: Container(
                    color: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 20.0),
                    child: Center(
                      child: ElevatedButton(
                        onPressed:
                            _isStreaming ? _stopStreaming : _startStreaming,
                        style: ElevatedButton.styleFrom(
                          shape: const CircleBorder(),
                          padding: const EdgeInsets.all(20),
                          backgroundColor: _isStreaming
                              ? const Color(
                                  0xFFdf2a15) // Màu đỏ khi đang truyền
                              : Colors.white, // Màu mặc định
                          side: BorderSide(
                            color: Colors.white, // Viền trắng
                            width: _isStreaming
                                ? 4
                                : 2, // Viền dày hơn khi đang truyền
                          ),
                        ),
                        child: const SizedBox(
                            width: 50,
                            height: 50), // Container trống không có icon
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
  void _switchCamera() {
    setState(() {
      _isCameraSwitched = !_isCameraSwitched;
      // Logic to switch camera
    });
  }

  void _toggleAudio() {
    setState(() {
      _isAudioEnabled = !_isAudioEnabled;
      // Logic to toggle audio
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
