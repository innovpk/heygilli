import 'package:flutter/material.dart';

import 'features/watch/watch_screen.dart';

void main() => runApp(const HeyGilliApp());

class HeyGilliApp extends StatelessWidget {
  const HeyGilliApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'HeyGilli',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFF5A524),
          brightness: Brightness.dark,
          surface: const Color(0xFF0F2A33),
        ),
        useMaterial3: true,
      ),
      // Day-1 slice: straight into the watch screen with a demo video.
      home: const WatchScreen(videoId: 'ysz5S6PUM-U', kidName: 'Zara'),
    );
  }
}
