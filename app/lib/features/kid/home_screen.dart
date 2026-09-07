import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/models.dart';
import '../../core/orientation.dart';
import '../../core/protocol.dart';
import '../../core/speech.dart';
import '../../core/theme.dart';
import '../../main.dart';
import '../gate/lock_mode.dart';
import '../gate/pin_gate.dart';
import 'avatar_picker.dart';
import 'break_screen.dart';
import 'gilli_widget.dart';
import 'nothing_yet_screen.dart';
import 'session_screen.dart';

/// Kid home: rows of thumbnails from the kid's approved channels only.
/// No search, no recommendations (SPEC 6.2). Band 4_6 sees pictures only;
/// a long-press has Gilli read the title aloud (SPEC 6.3 "focused").
class KidHomeScreen extends StatefulWidget {
  const KidHomeScreen({super.key});

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

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
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

  Future<void> _open(Video video) async {
    context.read<GilliVoice>().stop();
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => SessionScreen(video: video)));
    // Coming back may mean the session ended, or that a break ran and is now
    // over: either way the watch state has moved on.
    if (mounted) _reload();
  }

  /// The child changing their own picture.
  ///
  /// Not behind the PIN: it is cosmetic and it is theirs. `editKid` refreshes
  /// the household, so the header redraws with the new face on its own.
  Future<void> _pickAvatar(Kid kid) async {
    await showAvatarPicker(context, kid);
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
      // Back never leaves kid mode; it opens the PIN gate instead. During a
      // break it does nothing at all: the break screen has its own PIN way
      // out, and back must not become a second one.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_onBreak) _tryExit();
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
              return FutureBuilder<_Home>(
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
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _Header(
                        kid: kid,
                        onExit: _tryExit,
                        onPickAvatar: _pickAvatar,
                      ),
                      // Only when the parent turned it on, and never for a
                      // pre-reader: a child who cannot read cannot type, and a
                      // box they cannot use is one more thing to poke at.
                      if (kid.searchEnabled && kid.band.showsVideoTitles)
                        _SearchBox(onChanged: _search),
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
                              return const Center(
                                child: CircularProgressIndicator(
                                  color: HgColors.mango,
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
                            return ListView(
                              padding: const EdgeInsets.fromLTRB(0, 8, 0, 24),
                              children: [
                                for (final row in home.rows)
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
  const _Header({
    required this.kid,
    required this.onExit,
    required this.onPickAvatar,
  });
  final Kid kid;
  final VoidCallback onExit;

  /// Tapping their own picture. Passed in rather than done here so the screen
  /// can reload after it changes.
  final void Function(Kid kid) onPickAvatar;

  @override
  Widget build(BuildContext context) {
    final preReader = kid.band == AgeBand.b4to6;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 12, 8),
      child: Row(
        spacing: 16,
        children: [
          // Tapping their own picture is how a child changes it. Theirs to
          // choose, not the parent's to assign, and behind no PIN: it is
          // cosmetic, it is the one thing in the app that belongs to them,
          // and a gate on it would say otherwise.
          Semantics(
            label: 'Change your picture',
            button: true,
            child: InkWell(
              onTap: () => onPickAvatar(kid),
              borderRadius: BorderRadius.circular(999),
              child: Container(
                width: 72,
                height: 72,
                decoration: const BoxDecoration(
                  color: HgColors.mango,
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                padding: kid.hasDrawableAvatar ? const EdgeInsets.all(12) : null,
                // Pre-readers get a star, not a letter: no glyphs to decode.
                // A picture they chose replaces both.
                child: kid.hasDrawableAvatar
                    ? SvgPicture.asset('assets/icons/${kid.avatar}.svg')
                    : preReader
                    ? const Icon(Icons.star_rounded, size: 44, color: HgColors.teal)
                    : Text(
                        kid.nickname.isEmpty ? '?' : kid.nickname[0].toUpperCase(),
                        style: HgText.display(size: 34, color: HgColors.teal),
                      ),
              ),
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
              color: HgColors.cream.withValues(alpha: 0.14),
              shape: const CircleBorder(),
              child: InkWell(
                onTap: onExit,
                customBorder: const CircleBorder(),
                child: const SizedBox(
                  width: 52,
                  height: 52,
                  child: Icon(
                    Icons.lock_outline_rounded,
                    size: 26,
                    color: HgColors.cream,
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

/// The child's search box. Only ever shown when a parent turned search on for
/// this kid, and never to a pre-reader.
///
/// What it searches is the point: the gateway filters the videos already
/// approved for this child and can return nothing else. There is no code path
/// from here to YouTube's search, which is what keeps the allowlist a real
/// boundary rather than a default.
class _SearchBox extends StatelessWidget {
  const _SearchBox({required this.onChanged});

  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: TextField(
        onChanged: onChanged,
        textInputAction: TextInputAction.search,
        style: HgText.body(size: 17, color: HgColors.cream),
        cursorColor: HgColors.mango,
        decoration: InputDecoration(
          // Says where it looks, so a child is not hunting for something that
          // was never here.
          hintText: 'Find one of your videos',
          hintStyle: HgText.body(size: 17, color: HgColors.sky),
          prefixIcon: const Icon(Icons.search_rounded, color: HgColors.sky),
          filled: true,
          fillColor: HgColors.ink.withValues(alpha: 0.35),
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
  Widget build(BuildContext context) => Center(
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
            style: HgText.body(size: 16, color: HgColors.sky),
          ),
        ],
      ),
    ),
  );
}
