import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:video_player/video_player.dart';

class SignListScreen extends StatefulWidget {
  const SignListScreen({super.key});

  @override
  _SignListScreenState createState() => _SignListScreenState();
}

class _SignListScreenState extends State<SignListScreen> {
  String searchQuery = '';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Tra cứu'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: TextField(
              decoration: const InputDecoration(
                labelText: 'Tìm kiếm',
                border: OutlineInputBorder(),
              ),
              onChanged: (value) {
                setState(() {
                  searchQuery = value; // Cập nhật trạng thái khi nhập dữ liệu
                });
              },
            ),
          ),
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance.collection('sign').snapshots(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(
                      child: SizedBox(
                    width: 30,
                    height: 30,
                    child: CircularProgressIndicator(),
                  ));
                }
                if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                  return const Center(child: Text('No data found'));
                }

                // Lọc kết quả dựa trên searchQuery
                var signs = snapshot.data!.docs
                    .where((sign) =>
                        sign['name']
                            .toString()
                            .toLowerCase()
                            .contains(searchQuery.toLowerCase()) ||
                        sign['url']
                            .toString()
                            .toLowerCase()
                            .contains(searchQuery.toLowerCase()))
                    .toList();

                // Nếu không có searchQuery, giới hạn kết quả còn 3 phần tử
                if (searchQuery.isEmpty) {
                  signs = signs.take(3).toList();
                }

                if (signs.isEmpty) {
                  return const Center(child: Text('Không tìm thấy kết quả'));
                }

                return ListView.builder(
                  itemCount: signs.length,
                  itemBuilder: (context, index) {
                    final sign = signs[index];
                    final name = sign['name'];
                    final String url = sign['url'];

                    return ListTile(
                      title: Text(name),
                      subtitle: VideoCard(
                        url: url,
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class VideoCard extends StatefulWidget {
  const VideoCard({super.key, required this.url});

  final String url; // Nhận URL từ bên ngoài

  @override
  _VideoCardState createState() => _VideoCardState();
}

class _VideoCardState extends State<VideoCard>
    with SingleTickerProviderStateMixin {
  bool isPlaying = false;
  late AnimationController _controller;
  late Animation<double> _animation;
  late VideoPlayerController _videoController;

  @override
  void initState() {
    super.initState();
    _videoController =
        VideoPlayerController.network(widget.url) // Sử dụng URL được truyền vào
          ..initialize().then((_) {
            setState(() {});
          });
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _animation = Tween<double>(begin: 1.0, end: 0.0).animate(_controller);
  }

  @override
  void dispose() {
    _videoController.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 160,
      child: Stack(
        alignment: Alignment.center,
        children: [
          GestureDetector(
            onTap: () {
              setState(() {
                isPlaying = !isPlaying;
                if (isPlaying) {
                  _videoController.play();
                } else {
                  _videoController.pause();
                }
              });
            },
            child: Container(
              width: double.infinity,
              height: 160,
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(8),
              ),
              child: _videoController.value.isInitialized
                  ? VideoPlayer(_videoController)
                  : const Center(
                      child: SizedBox(
                      width: 30,
                      height: 30,
                      child: CircularProgressIndicator(),
                    )),
            ),
          ),
          GestureDetector(
            onTap: () {
              setState(() {
                isPlaying = !isPlaying;
                if (isPlaying) {
                  _videoController.play();
                } else {
                  _videoController.pause();
                }
              });
            },
            child: AnimatedOpacity(
              opacity: isPlaying ? 0 : 1,
              duration: const Duration(milliseconds: 200),
              child: Container(
                height: 30,
                width: 30,
                alignment: Alignment.center,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white,
                ),
                child: const Icon(Icons.play_arrow, size: 20),
              ),
            ),
          )
        ],
      ),
    );
  }
}
