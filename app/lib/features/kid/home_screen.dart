import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/models.dart';
import '../../core/orientation.dart';
import '../../core/protocol.dart';
import '../../core/sounds.dart';
import '../../core/speech.dart';
import '../../core/theme.dart';
import 'kid_palette.dart';
import '../../main.dart';
import '../gate/lock_mode.dart';
import '../gate/pin_gate.dart';
import 'break_screen.dart';
import 'games/play_screen.dart';
import 'gilli_widget.dart';
import 'nothing_yet_screen.dart';
import 'session_screen.dart';
import 'sleepy_gilli.dart';

/// Kid home: the kid's approved channels as tabs, and the chosen one's videos.
/// No search, no recommendations (SPEC 6.2). Band 4_6 gets one grid with a
/// title under each picture, as on YouTube Kids; a long-press has Gilli read
/// the title aloud (SPEC 6.3 "focused").
class KidHomeScreen extends StatefulWidget {
  const KidHomeScreen({super.key, this.hear});

  /// What the child says into the search mic. Null listens on the real mic;
  /// tests hand in the words, since there is no microphone under a test.
  @visibleForTesting
  final Future<String> Function()? hear;

  @override
  State<KidHomeScreen> createState() => _KidHomeScreenState();
}

/// The rows plus the answer to "is this child allowed to watch at all".
///
/// Both are loaded together so the home screen never paints a shelf of
/// thumbnails for a second before finding out a break is running.
class _Home {
  const _Home(this.rows, this.state);
  final List<HomeRow> rows;
  final WatchState state;
}

class _KidHomeScreenState extends State<KidHomeScreen> {
  late Future<_Home> _home = _load();

  /// Mirrors what the last build painted, so the back handler knows a break
  /// is on screen without waiting on the future again.
  bool _onBreak = false;

  void _reload() => setState(() {
    _home = _load();
  });

  /// What the child has typed. Empty is the ordinary home; the gateway is what
  /// decides whether a query counts at all.
  String _query = '';
  Timer? _debounce;

  /// A child types slowly and one letter at a time, so the rows are not
  /// refetched on every keystroke.
  void _search(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      if (!mounted) return;
      setState(() {
        _query = q;
        _home = _load();
      });
    });
  }

  Future<_Home> _load() async {
    final state = context.read<AppState>();
    final kid = state.activeKid;
    if (kid == null) return const _Home([], WatchState());
    // PROTOCOL: `GET /kids/{id}/state` is what the client checks before
    // offering anything to watch. Checking it here is also what makes a break
    // survive the app being killed and reopened mid-break.
    //
    // A gateway that does not answer this yet must not leave a child staring
    // at "Try again": watching is allowed unless the server says otherwise,
    // and the socket still stops playback if a break fires mid-session.
    WatchState watch;
    try {
      watch = await state.gateway.watchState(kid.id);
    } catch (e) {
      debugPrint('[home] watch state unavailable: $e');
      watch = const WatchState();
    }
    if (!watch.watchingAllowed) return _Home(const [], watch);
    return _Home(await state.gateway.home(kid.id, query: _query), watch);
  }

  /// What is in the search box, typed or said.
  final _searchText = TextEditingController();

  /// The mic for voice search, made on first use: most visits never search.
  KidEars? _ears;
  bool _listening = false;

  /// Voice search: one listening window, and what was heard goes in the box
  /// as if it had been typed. A child who cannot spell "volcano", or cannot
  /// read yet, can still say it. The words go no further than the search
  /// itself, which only narrows the approved list.
  Future<void> _searchByVoice() async {
    if (_listening) {
      await _ears?.finishNow();
      return;
    }
    context.read<GilliVoice>().stop();
    setState(() => _listening = true);
    final String said;
    if (widget.hear case final hear?) {
      said = await hear();
    } else {
      final heard = await (_ears ??= KidEars()).listen(
        window: const Duration(seconds: 6),
      );
      said = heard.transcript;
    }
    if (!mounted) return;
    setState(() => _listening = false);
    if (said.trim().isEmpty) return;
    _searchText.text = said.trim();
    _search(said.trim());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchText.dispose();
    _ears?.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    // Best-effort screen pinning; the PIN gate is the real exit control.
    ScreenOrientation.kidMode();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      LockMode.start();
      // A notice from the parent's side ("Moved to Shown · Undo") must not
      // follow them in: a notice with an action stays until dismissed, and a
      // child would be the one left to tap Undo.
      if (mounted) ScaffoldMessenger.maybeOf(context)?.clearSnackBars();
    });
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

  /// Gilli in the header, so a touch anywhere on the shelf keeps him awake.
  final _gilli = GlobalKey<SleepyGilliState>();

  /// Tapping Gilli once he is awake. Games follow the same gate as videos:
  /// the header only offers this while watching is allowed.
  Future<void> _openGames(Kid kid, KidPalette palette) async {
    context.read<GilliVoice>().stop();
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => KidTheme(
          palette: palette,
          child: PlayScreen(kid: kid),
        ),
      ),
    );
    // A break may have come due while they played.
    if (mounted) _reload();
  }

  Future<void> _open(Video video) async {
    context.read<GilliVoice>().stop();
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => SessionScreen(video: video)));
    // Coming back may mean the session ended, or that a break ran and is now
    // over: either way the watch state has moved on.
    if (mounted) _reload();
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
    // One ground for kid mode. There was a day/night switch in the header;
    // it was one more thing on a shelf that is for picking a video.
    const palette = KidPalette.nightTime;
    return KidTheme(
      palette: palette,
      child: _build(context, kid, showTitles, palette),
    );
  }

  Widget _build(
    BuildContext context,
    Kid kid,
    bool showTitles,
    KidPalette palette,
  ) {
    return PopScope(
      // Back never leaves kid mode; it opens the PIN gate instead. During a
      // break it does nothing at all: the break screen has its own PIN way
      // out, and back must not become a second one.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_onBreak) _tryExit();
      },
      child: Scaffold(
        backgroundColor: palette.ground,
        body: SafeArea(
          child: FutureBuilder<_Home>(
            future: _home,
            builder: (context, snap) {
              final home = snap.data;
              _onBreak = home?.state.isOnBreak ?? false;
              // A running break replaces the whole screen, header and
              // all: there is nothing to start, so there is nothing to
              // show around it.
              if (home != null && home.state.isOnBreak) {
                return BreakScreen(
                  kid: kid,
                  breakPeriod: home.state.activeBreak!,
                  onFinished: _reload,
                );
              }
              return Listener(
                behavior: HitTestBehavior.translucent,
                onPointerDown: (_) => _gilli.currentState?.stir(),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _Header(
                      kid: kid,
                      gilliKey: _gilli,
                      onExit: _tryExit,
                      onPlay: home != null && home.state.watchingAllowed
                          ? () => _openGames(kid, palette)
                          : null,
                      // Readers only: a pre-reader cannot read it.
                      state: showTitles ? home?.state : null,
                    ),
                    // On unless the parent turned it off, for every child: a
                    // pre-reader who cannot type can use the mic.
                    if (kid.searchEnabled)
                      _SearchBox(
                        controller: _searchText,
                        onChanged: _search,
                        onMic: _searchByVoice,
                        listening: _listening,
                      ),
                    Expanded(
                      child: Builder(
                        builder: (context) {
                          if (snap.hasError) {
                            return Center(
                              child: FilledButton(
                                onPressed: _reload,
                                child: const Text('Try again'),
                              ),
                            );
                          }
                          if (home == null) {
                            return Center(
                              child: CircularProgressIndicator(
                                color: palette.accent,
                              ),
                            );
                          }
                          // Out of minutes: a calm end to the day, not an
                          // empty shelf a child keeps tapping at.
                          if (!home.state.watchingAllowed) {
                            return DayDoneScreen(kid: kid);
                          }
                          // Nothing approved yet — every new profile starts
                          // here, and the Curator may still be working. An
                          // empty ListView renders literally nothing, which
                          // a child cannot tell apart from a broken app.
                          if (home.rows.every((r) => r.videos.isEmpty)) {
                            // A search that found nothing is not an empty
                            // shelf: there is something to change, and the
                            // box has to stay on screen to change it.
                            return _query.isEmpty
                                ? NothingYetScreen(kid: kid)
                                : _NoMatches(kid: kid);
                          }
                          return _Shelf(
                            rows: home.rows,
                            showTitles: showTitles,
                            onOpen: _open,
                          );
                        },
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Gilli, the games, and a quiet exit control for the parent.
///
/// The child's own picture used to lead this row. It was one more circle in a
/// header of circles, above a shelf that marked its channels with circles too,
/// and it did nothing a child needs while picking a video. The parent sets it
/// when adding or editing the child.
class _Header extends StatelessWidget {
  const _Header({
    required this.kid,
    required this.gilliKey,
    required this.onExit,
    required this.onPlay,
    this.state,
  });
  final Kid kid;
  final GlobalKey<SleepyGilliState> gilliKey;
  final VoidCallback onExit;

  /// The games button. Null when there is nothing to play, and then there is
  /// no button: games follow the same gate as videos.
  final VoidCallback? onPlay;

  /// Today's minutes and the next break, for a reader. Null hides the line.
  final WatchState? state;

  @override
  Widget build(BuildContext context) {
    final palette = KidPalette.of(context);
    final preReader = kid.band == AgeBand.b4to6;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 16, 12),
      child: Row(
        spacing: 16,
        children: [
          // He naps when nobody is touching the screen, and a pinch (a tap,
          // a click, or two fingers) wakes him. Pinching him does nothing
          // else: the games have their own button.
          SleepyGilli(key: gilliKey, kid: kid, size: 72),
          if (!preReader)
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                spacing: 4,
                children: [
                  Text(
                    'Hi ${kid.nickname}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: HgText.display(size: 30, color: palette.onGround),
                  ),
                  // How much is left, said once, where a child can see it
                  // without asking. Not a countdown: a number that only moves
                  // when the screen reloads, because a ticking clock on a
                  // shelf of videos is a thing to watch, not a fact to know.
                  if (state case final left?) _TimeLeft(state: left, kid: kid),
                ],
              ),
            )
          else
            const Spacer(),
          // Gilli's games. Mango, not the quiet chip colour of the lock: this
          // one is for the child, and it should look like it.
          if (onPlay != null)
            Tooltip(
              message: 'Games',
              child: Semantics(
                button: true,
                label: 'Play a game with Gilli',
                child: Material(
                  key: const Key('play-games'),
                  color: HgColors.mango,
                  shape: const CircleBorder(),
                  child: InkWell(
                    onTap: withTap(onPlay),
                    customBorder: const CircleBorder(),
                    child: const SizedBox(
                      // 52, like the lock beside it: a four-year-old's finger
                      // does not land inside 40.
                      width: 52,
                      height: 52,
                      child: Icon(
                        Icons.sports_esports_rounded,
                        size: 28,
                        color: HgColors.white,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          const SizedBox(width: 8),
          // The way back to the parent. It was cream at 55% on teal and
          // nothing else — findable on a phone, invisible in the corner of a
          // wide window, and the first thing a parent hunts for. It is a
          // filled circle now: still quiet, but unmistakably a control.
          //
          // Quiet is the point, not hidden. The child this is kept from is
          // four and cannot read the label anyway; what actually stops them
          // is the PIN behind it, so making the door visible costs nothing.
          Tooltip(
            message: 'Parent',
            child: Material(
              color: palette.chip,
              shape: const CircleBorder(),
              child: InkWell(
                onTap: onExit,
                customBorder: const CircleBorder(),
                child: SizedBox(
                  width: 52,
                  height: 52,
                  child: Icon(
                    Icons.lock_outline_rounded,
                    size: 26,
                    color: palette.onGround,
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

/// The shelf: a section for each channel, one under the next, each a heading
/// and a strip of big tiles that scrolls sideways.
///
/// Before this it was a row of channel tabs over a grid, and before that a
/// list of rows each marked by a picture too small to find. Sections with a
/// real heading are what a child already knows from every other shelf of
/// videos, and they show everything at once instead of hiding all but one
/// channel behind a tab.
class _Shelf extends StatelessWidget {
  const _Shelf({
    required this.rows,
    required this.showTitles,
    required this.onOpen,
  });

  final List<HomeRow> rows;
  final bool showTitles;
  final void Function(Video) onOpen;

  @override
  Widget build(BuildContext context) {
    if (!showTitles) {
      return _PictureGrid(
        videos: [for (final r in rows) ...r.videos],
        onOpen: onOpen,
      );
    }
    return LayoutBuilder(
      builder: (context, box) {
        // Two and a bit tiles across a phone held sideways, three and a bit on
        // a tablet. The bit is the edge of the next tile, which says there is
        // more that way without an arrow.
        final across = box.maxWidth >= 900 ? 3.3 : 2.3;
        final tile = ((box.maxWidth - _side) / across).clamp(180.0, 480.0);
        return ListView(
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            for (final row in rows)
              if (row.videos.isNotEmpty)
                _Section(row: row, tileWidth: tile, onOpen: onOpen),
          ],
        );
      },
    );
  }
}

/// A pre-reader's shelf: one grid of big pictures, a title under each, the
/// way YouTube Kids shows its youngest.
///
/// No channel headings: without the name, a channel's picture over each row
/// was one more small circle to puzzle at. The title stays, as it does on
/// YouTube Kids: a parent reading along uses it, a child soon starts to, and a
/// hold on the picture has Gilli read it out.
class _PictureGrid extends StatelessWidget {
  const _PictureGrid({required this.videos, required this.onOpen});

  final List<Video> videos;
  final void Function(Video) onOpen;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        const gap = 20.0;
        final across = box.maxWidth >= 900 ? 3 : 2;
        final width = (box.maxWidth - _side * 2 - gap * (across - 1)) / across;
        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(_side, 8, _side, 32),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: across,
            mainAxisSpacing: gap,
            crossAxisSpacing: gap,
            mainAxisExtent: width * 9 / 16 + _Section._words,
          ),
          itemCount: videos.length,
          itemBuilder: (context, i) =>
              _Tile(video: videos[i], showTitle: true, onOpen: onOpen),
        );
      },
    );
  }
}

/// The shelf's margin on the left and right.
const _side = 24.0;

/// One channel for a reader: its heading, and a strip of its videos.
class _Section extends StatelessWidget {
  const _Section({
    required this.row,
    required this.tileWidth,
    required this.onOpen,
  });

  final HomeRow row;
  final double tileWidth;
  final void Function(Video) onOpen;

  /// Room under a reader's tile for two lines of title and one of length.
  static const _words = 86.0;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 14,
        children: [
          _SectionHeading(row: row),
          SizedBox(
            height: tileWidth * 9 / 16 + _words,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: _side),
              itemCount: row.videos.length,
              separatorBuilder: (_, _) => const SizedBox(width: 18),
              itemBuilder: (context, i) => SizedBox(
                width: tileWidth,
                child: _Tile(
                  video: row.videos[i],
                  showTitle: true,
                  onOpen: onOpen,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Which channel a section is: its picture in a ring, and its name.
class _SectionHeading extends StatelessWidget {
  const _SectionHeading({required this.row});

  final HomeRow row;

  @override
  Widget build(BuildContext context) {
    final palette = KidPalette.of(context);
    const size = 44.0;
    final fallback = ColoredBox(
      color: palette.tile,
      child: Icon(
        Icons.video_library_rounded,
        color: palette.accent,
        size: size * 0.5,
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: _side),
      child: Semantics(
        header: true,
        label: row.title,
        excludeSemantics: true,
        child: Row(
          spacing: 14,
          children: [
            Container(
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: palette.accent, width: 3),
              ),
              child: ClipOval(
                child: SizedBox.square(
                  dimension: size,
                  child: row.thumb.isEmpty
                      ? fallback
                      : Image.network(
                          row.thumb,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => fallback,
                        ),
                ),
              ),
            ),
            Flexible(
              child: Text(
                row.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: HgText.display(size: 26, color: palette.accent),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One video. A reader gets its title and how long it is under the picture;
/// a pre-reader gets the picture alone, and a hold has Gilli read the title.
class _Tile extends StatelessWidget {
  const _Tile({
    required this.video,
    required this.showTitle,
    required this.onOpen,
  });

  final Video video;
  final bool showTitle;
  final void Function(Video) onOpen;

  /// "8 min", the way a child who reads would say it. Under a minute is 1.
  static String _length(int seconds) =>
      '${(seconds / 60).round().clamp(1, 999)} min';

  @override
  Widget build(BuildContext context) {
    final palette = KidPalette.of(context);
    final voice = context.read<GilliVoice>();
    return Semantics(
      button: true,
      label: video.title,
      child: GestureDetector(
        onTap: withTap(() => onOpen(video)),
        // SPEC 6.3: title read aloud on focus. On touch, focus is a hold.
        onLongPress: () => voice.say(url: '', fallbackText: video.title),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: Image.network(
                  video.thumb,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => ColoredBox(
                    color: palette.tile,
                    child: Icon(
                      Icons.play_circle_fill_rounded,
                      color: palette.accent,
                      size: 48,
                    ),
                  ),
                ),
              ),
            ),
            if (showTitle) ...[
              const SizedBox(height: 10),
              Text(
                video.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: HgText.display(size: 18, color: palette.onGround),
              ),
              if (video.durationS > 0) ...[
                const SizedBox(height: 4),
                Text(
                  _length(video.durationS),
                  style: HgText.body(size: 14, color: palette.quiet),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

/// The child's search box, typed or said. On unless a parent turned it off.
///
/// What it searches is the point: the gateway filters the videos already
/// approved for this child and can return nothing else. There is no code path
/// from here to YouTube's search, which is what keeps the allowlist a real
/// boundary rather than a default, and what makes it safe to leave on.
class _SearchBox extends StatelessWidget {
  const _SearchBox({
    required this.controller,
    required this.onChanged,
    required this.onMic,
    required this.listening,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onMic;
  final bool listening;

  @override
  Widget build(BuildContext context) {
    final palette = KidPalette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        textInputAction: TextInputAction.search,
        style: HgText.body(size: 17, color: palette.onGround),
        cursorColor: palette.accent,
        decoration: InputDecoration(
          // Says where it looks, so a child is not hunting for something that
          // was never here.
          hintText: listening ? 'Listening…' : 'Find one of your videos',
          hintStyle: HgText.body(size: 17, color: palette.quiet),
          prefixIcon: Icon(Icons.search_rounded, color: palette.quiet),
          // Say it instead of typing it.
          suffixIcon: Padding(
            padding: const EdgeInsets.only(right: 6),
            child: IconButton(
              key: const Key('search-mic'),
              tooltip: listening ? 'Stop listening' : 'Say it',
              onPressed: withTap(onMic),
              style: IconButton.styleFrom(
                backgroundColor: listening ? HgColors.mango : palette.card,
              ),
              icon: Icon(
                listening ? Icons.graphic_eq_rounded : Icons.mic_rounded,
                color: listening ? HgColors.white : palette.accent,
              ),
            ),
          ),
          filled: true,
          fillColor: palette.chip,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(999),
            borderSide: BorderSide.none,
          ),
          contentPadding: const EdgeInsets.symmetric(vertical: 14),
        ),
      ),
    );
  }
}

/// Searched, and none of this child's videos matched.
///
/// Deliberately not [NothingYetScreen]: that one says there is nothing at all,
/// which would be false and would send a child away from a shelf that is
/// actually full. This says the word did not match, which is fixable.
class _NoMatches extends StatelessWidget {
  const _NoMatches({required this.kid});

  final Kid kid;

  @override
  Widget build(BuildContext context) {
    final palette = KidPalette.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: 10,
          children: [
            const GilliWidget(size: 110, gesture: Gesture.think),
            Text(
              'Nothing with that word',
              textAlign: TextAlign.center,
              style: HgText.display(size: 24),
            ),
            Text(
              'Try another word, or clear it to see everything again.',
              textAlign: TextAlign.center,
              style: HgText.body(size: 16, color: palette.quiet),
            ),
          ],
        ),
      ),
    );
  }
}

/// "35 minutes left today · next break in 12 minutes".
///
/// Readers only. A pre-reader cannot read it, and a number they cannot read
/// sitting above their videos is decoration that takes up the shelf.
class _TimeLeft extends StatelessWidget {
  const _TimeLeft({required this.state, required this.kid});

  final WatchState state;
  final Kid kid;

  String? get _text {
    final parts = <String>[];
    if (kid.dailyMinutes > 0 && state.minutesLeftToday > 0) {
      parts.add(
        '${state.minutesLeftToday} '
        '${state.minutesLeftToday == 1 ? "minute" : "minutes"} left today',
      );
    }
    if (kid.breakAfterMinutes > 0) {
      final until = kid.breakAfterMinutes - state.continuousMinutes;
      if (until > 0) {
        parts.add(
          'next break in $until '
          '${until == 1 ? "minute" : "minutes"}',
        );
      }
    }
    // No limits set, or nothing left to say. Silence beats a pill reading
    // "unlimited", which is an answer to a question nobody asked.
    return parts.isEmpty ? null : parts.join(' \u00b7 ');
  }

  @override
  Widget build(BuildContext context) {
    final palette = KidPalette.of(context);
    final text = _text;
    if (text == null) return const SizedBox.shrink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 8,
      children: [
        Container(
          width: 9,
          height: 9,
          decoration: const BoxDecoration(
            color: HgColors.green,
            shape: BoxShape.circle,
          ),
        ),
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: HgText.body(size: 16, color: palette.quiet),
          ),
        ),
      ],
    );
  }
}
