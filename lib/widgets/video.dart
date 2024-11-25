import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';


class VideoCard extends StatefulWidget {
  const VideoCard({super.key});

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
    // ignore: deprecated_member_use
    _videoController = VideoPlayerController.network(
        'https://flutter.github.io/assets-for-api-docs/assets/videos/bee.mp4')
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
                  : const CircularProgressIndicator(),
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