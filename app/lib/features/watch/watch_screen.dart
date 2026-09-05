import 'dart:async';

import 'package:flutter/material.dart';
import 'package:youtube_player_iframe/youtube_player_iframe.dart';

/// A question Peeku asks at a point in the video.
///
/// Day 1 uses a hard-coded plan; from day 2 this comes from the Planner agent.
class PlannedQuestion {
  const PlannedQuestion({required this.atSeconds, required this.spoken});

  final int atSeconds;
  final String spoken;
}

/// Plays a YouTube video via the official embed and pauses at planned
/// timestamps so Peeku can ask a question. No overlays are drawn while the
/// video is playing; the question card appears only while paused.
class WatchScreen extends StatefulWidget {
  const WatchScreen({super.key, required this.videoId, required this.kidName});

  final String videoId;
  final String kidName;

  @override
  State<WatchScreen> createState() => _WatchScreenState();
}

class _WatchScreenState extends State<WatchScreen> {
  late final YoutubePlayerController _controller;
  StreamSubscription<YoutubeVideoState>? _position;

  // Placeholder plan; replaced by the Planner agent's QuestionPlan on day 2.
  final _plan = const [
    PlannedQuestion(atSeconds: 8, spoken: 'What animal is that?'),
    PlannedQuestion(atSeconds: 25, spoken: 'What colour was the ball?'),
  ];
  final _asked = <int>{};
  PlannedQuestion? _current;

  @override
  void initState() {
    super.initState();
    _controller = YoutubePlayerController.fromVideoId(
      videoId: widget.videoId,
      autoPlay: false,
      params: const YoutubePlayerParams(
        showControls: true,
        showFullscreenButton: false,
        strictRelatedVideos: true,
        enableCaption: false,
      ),
    );
    _position = _controller.videoStateStream.listen((s) => _onTick(s.position));
  }

  void _onTick(Duration pos) {
    if (_current != null) return;
    for (var i = 0; i < _plan.length; i++) {
      final q = _plan[i];
      if (!_asked.contains(i) && pos.inSeconds >= q.atSeconds) {
        _asked.add(i);
        _controller.pauseVideo();
        setState(() => _current = q);
        break;
      }
    }
  }

  Future<void> _resume() async {
    setState(() => _current = null);
    await _controller.playVideo();
  }

  Future<void> _seekBy(int seconds) async {
    final now = await _controller.currentTime;
    await _controller.seekTo(
      seconds: (now + seconds).clamp(0, 1e9),
      allowSeekAhead: true,
    );
  }

  @override
  void dispose() {
    _position?.cancel();
    _controller.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final player = YoutubePlayer(controller: _controller, aspectRatio: 16 / 9);
    return Scaffold(
      appBar: AppBar(title: Text('Peeku · ${widget.kidName}')),
      body: SafeArea(
        child: Column(
          children: [
            player,
            Padding(
              padding: const EdgeInsets.all(12),
              child: Wrap(
                spacing: 12,
                children: [
                  FilledButton.icon(
                    onPressed: () => _controller.playVideo(),
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Play'),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: () => _controller.pauseVideo(),
                    icon: const Icon(Icons.pause),
                    label: const Text('Pause'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => _seekBy(10),
                    icon: const Icon(Icons.forward_10),
                    label: const Text('+10 s'),
                  ),
                ],
              ),
            ),
            Expanded(
              child: _current == null
                  ? const SizedBox.shrink()
                  : _QuestionCard(question: _current!, onResume: _resume),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shown only while the video is paused. Day 1: text plus a resume button.
/// Day 3 replaces this with TTS, the mic button, and Peeku's animation.
class _QuestionCard extends StatelessWidget {
  const _QuestionCard({required this.question, required this.onResume});

  final PlannedQuestion question;
  final VoidCallback onResume;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFFFBF3E6),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.pets, size: 64, color: scheme.primary),
          const SizedBox(height: 12),
          Text(
            question.spoken,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w800,
              color: Color(0xFF1E1A17),
            ),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: onResume,
            icon: const Icon(Icons.mic),
            label: const Text('Answer (stub) and keep watching'),
          ),
        ],
      ),
    );
  }
}
