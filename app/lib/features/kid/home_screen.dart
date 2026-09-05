import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/models.dart';
import '../../core/orientation.dart';
import '../../core/speech.dart';
import '../../core/theme.dart';
import '../../main.dart';
import '../gate/lock_mode.dart';
import '../gate/pin_gate.dart';
import 'gilli_widget.dart';
import 'session_screen.dart';

/// Kid home: rows of thumbnails from the kid's approved channels only.
/// No search, no recommendations (SPEC 6.2). Band 4_6 sees pictures only;
/// a long-press has Gilli read the title aloud (SPEC 6.3 "focused").
class KidHomeScreen extends StatefulWidget {
  const KidHomeScreen({super.key});

  @override
  State<KidHomeScreen> createState() => _KidHomeScreenState();
}

class _KidHomeScreenState extends State<KidHomeScreen> {
  late Future<List<HomeRow>> _rows = _load();

  void _reload() => setState(() {
    _rows = _load();
  });

  Future<List<HomeRow>> _load() {
    final state = context.read<AppState>();
    final kid = state.activeKid;
    if (kid == null) return Future.value(const []);
    return state.gateway.home(kid.id);
  }

  @override
  void initState() {
    super.initState();
    // Best-effort screen pinning; the PIN gate is the real exit control.
    ScreenOrientation.kidMode();
    WidgetsBinding.instance.addPostFrameCallback((_) => LockMode.start());
  }

  Future<void> _tryExit() async {
    final ok = await showPinGate(context);
    if (!ok || !mounted) return;
    await LockMode.stop();
    await ScreenOrientation.parentMode();
    if (!mounted) return;
    context.read<AppState>().leaveKidMode();
    Navigator.of(context).pushNamedAndRemoveUntil(Routes.parent, (_) => false);
  }

  void _open(Video video) {
    context.read<GilliVoice>().stop();
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => SessionScreen(video: video)));
  }

  @override
  Widget build(BuildContext context) {
    final kid = context.select<AppState, Kid?>((s) => s.activeKid);
    if (kid == null) {
      // Kid mode without a kid: only reachable by a deep link; bounce back.
      return Scaffold(
        body: Center(
          child: FilledButton(
            onPressed: () => Navigator.of(
              context,
            ).pushNamedAndRemoveUntil(Routes.parent, (_) => false),
            child: const Text('Back to parent'),
          ),
        ),
      );
    }
    final showTitles = kid.band.showsVideoTitles;
    return PopScope(
      // Back never leaves kid mode; it opens the PIN gate instead.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _tryExit();
      },
      child: Scaffold(
        backgroundColor: HgColors.teal,
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, box) {
              final wide = box.maxWidth > 700;
              final thumbWidth = wide
                  ? box.maxWidth * 0.26
                  : box.maxWidth * 0.46;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Header(kid: kid, onExit: _tryExit),
                  Expanded(
                    child: FutureBuilder<List<HomeRow>>(
                      future: _rows,
                      builder: (context, snap) {
                        if (snap.hasError) {
                          return Center(
                            child: FilledButton(
                              onPressed: _reload,
                              child: const Text('Try again'),
                            ),
                          );
                        }
                        final rows = snap.data;
                        if (rows == null) {
                          return const Center(
                            child: CircularProgressIndicator(
                              color: HgColors.mango,
                            ),
                          );
                        }
                        return ListView(
                          padding: const EdgeInsets.fromLTRB(0, 8, 0, 24),
                          children: [
                            for (final row in rows)
                              _VideoRow(
                                row: row,
                                showTitles: showTitles,
                                thumbWidth: thumbWidth,
                                onOpen: _open,
                              ),
                          ],
                        );
                      },
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Kid avatar, small Gilli, and a quiet exit control for the parent.
class _Header extends StatelessWidget {
  const _Header({required this.kid, required this.onExit});
  final Kid kid;
  final VoidCallback onExit;

  @override
  Widget build(BuildContext context) {
    final preReader = kid.band == AgeBand.b4to6;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 12, 8),
      child: Row(
        spacing: 16,
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: const BoxDecoration(
              color: HgColors.mango,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            // Pre-readers get a star, not a letter: no glyphs to decode.
            child: preReader
                ? const Icon(Icons.star_rounded, size: 44, color: HgColors.teal)
                : Text(
                    kid.nickname.isEmpty ? '?' : kid.nickname[0].toUpperCase(),
                    style: HgText.display(size: 34, color: HgColors.teal),
                  ),
          ),
          const GilliWidget(size: 72),
          if (!preReader)
            Expanded(
              child: Text(
                'Hi ${kid.nickname}',
                style: HgText.display(size: 28),
                overflow: TextOverflow.ellipsis,
              ),
            )
          else
            const Spacer(),
          // 48 dp target, low contrast on purpose: parents find it, kids ignore it.
          IconButton(
            onPressed: onExit,
            iconSize: 26,
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            icon: const Icon(Icons.lock_outline_rounded),
            color: HgColors.cream.withValues(alpha: 0.55),
            tooltip: 'Parent',
          ),
        ],
      ),
    );
  }
}

class _VideoRow extends StatelessWidget {
  const _VideoRow({
    required this.row,
    required this.showTitles,
    required this.thumbWidth,
    required this.onOpen,
  });

  final HomeRow row;
  final bool showTitles;
  final double thumbWidth;
  final void Function(Video) onOpen;

  @override
  Widget build(BuildContext context) {
    final thumbHeight = thumbWidth * 9 / 16;
    final cardHeight = thumbHeight + (showTitles ? 52 : 0);
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 10,
        children: [
          if (showTitles)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                row.title,
                style: HgText.body(size: 16, color: HgColors.sky),
              ),
            ),
          SizedBox(
            height: cardHeight,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              itemCount: row.videos.length,
              separatorBuilder: (_, _) => const SizedBox(width: 16),
              itemBuilder: (context, i) => _Thumb(
                video: row.videos[i],
                width: thumbWidth,
                showTitle: showTitles,
                onOpen: onOpen,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Thumb extends StatelessWidget {
  const _Thumb({
    required this.video,
    required this.width,
    required this.showTitle,
    required this.onOpen,
  });

  final Video video;
  final double width;
  final bool showTitle;
  final void Function(Video) onOpen;

  @override
  Widget build(BuildContext context) {
    final voice = context.read<GilliVoice>();
    return SizedBox(
      width: width,
      child: Semantics(
        button: true,
        label: video.title,
        child: GestureDetector(
          onTap: () => onOpen(video),
          // SPEC 6.3: title read aloud on focus. On touch, focus is a hold.
          onLongPress: () => voice.say(url: '', fallbackText: video.title),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 8,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(22),
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: Image.network(
                    video.thumb,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const ColoredBox(
                      color: HgColors.tealDeep,
                      child: Icon(
                        Icons.play_circle_fill_rounded,
                        color: HgColors.mango,
                        size: 48,
                      ),
                    ),
                  ),
                ),
              ),
              if (showTitle)
                Text(
                  video.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: HgText.body(size: 15),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
