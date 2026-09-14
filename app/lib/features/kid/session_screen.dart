import 'dart:async';

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:youtube_player_iframe/youtube_player_iframe.dart';

import '../../core/app_state.dart';
import '../../core/icon_library.dart';
import '../../core/models.dart';
import '../../core/protocol.dart';
import '../../core/session_socket.dart';
import '../../core/settings.dart';
import '../../core/sounds.dart';
import '../../core/speech.dart';
import '../../core/theme.dart';
import 'break_screen.dart';
import 'captions_off.dart';
import 'gilli_widget.dart';
import 'kid_palette.dart';
import 'mic_button.dart';
import 'pick_cards.dart';
import 'question_track.dart';

/// One co-watching session: the YouTube embed plus Gilli's loop
/// (pause → ask → answer → reply → resume) driven by the gateway over the
/// WebSocket. The client never decides when to ask; it only reports position.
///
/// Nothing is ever drawn over the video (SPEC 5.5). Gilli, the question and
/// the answer controls live below (phone) or beside (tablet) the player.
class SessionScreen extends StatefulWidget {
  const SessionScreen({super.key, required this.video});
  final Video video;

  @override
  State<SessionScreen> createState() => _SessionScreenState();
}

/// SPEC 7.4: "Never repeat a question more than once, in any band."
const _repeatsPerQuestion = 1;

/// The embed a child watches, with YouTube's own furniture turned off.
///
/// All of these are documented IFrame Player API parameters, which is the
/// whole reason they are used rather than anything drawn on top: the terms
/// forbid overlaying the player, not configuring it.
///
/// `showControls` is the one that matters most, and not for tidiness. The
/// control bar carried a settings menu, a captions toggle, a copy-link button
/// and a second progress bar sitting under Gilli's own — but also, on pause,
/// YouTube's "More videos" panel. Every video on a child's shelf has been
/// read against what their household said, and one tap on that panel put them
/// in an unscreened video inside the same frame. That is the allowlist gone,
/// silently, from the one screen built to enforce it.
///
/// The child loses nothing they had: Gilli decides when this pauses, the way
/// back out is the Home button in the bar above, and where they are in the
/// video is what `QuestionTrack` is for.
@visibleForTesting
const kidPlayerParams = YoutubePlayerParams(
  showControls: false,
  showFullscreenButton: false,
  showVideoAnnotations: false,
  strictRelatedVideos: true,
  enableCaption: false,
  enableKeyboard: false,
  // Nothing this app sends reaches the embed, which is what keeps a child away
  // from "Watch on YouTube", the share button and, on pause, "More videos" —
  // one tap on that panel puts them in an unscreened video inside the frame,
  // and that is the allowlist gone from the screen built to enforce it.
  //
  // This costs the tap that starts the video, and that is not free. The
  // setting is written into the wrapper before the first frame, so a browser
  // that will not autoplay sound — every mobile browser, and Safari — sits on
  // the poster waiting for a tap it can never receive. It shipped that way
  // once and the video simply never began.
  //
  // `mute` is what buys it back. Muted autoplay is permitted everywhere, so
  // playback starts on its own and needs no tap at all; the sound is turned
  // back on the moment it is playing. See `_unmuteOnce`.
  //
  // The other cost is that an ad inside the player cannot be clicked. That is
  // a deliberate trade for a screen a six-year-old is sitting in front of.
  pointerEvents: PointerEvents.none,
  mute: true,
);

/// What a child's tap on the video should do.
enum PlayerTap { nothing, pause, start }

/// The tap a child is allowed, decided in one place so it can be pinned down.
///
/// `pointerEvents: none` takes the ordinary tap away from the embed, and this
/// is what we hand back in its place. Two outcomes, and a third that matters
/// more than either: while Gilli has the video, a tap does nothing at all.
/// The pause is the question, and a child tapping past it has skipped it.
@visibleForTesting
PlayerTap playerTapFor({
  required bool gilliHasVideo,
  required bool onBreak,
  required bool ended,
  required PlayerState state,
}) {
  if (gilliHasVideo || onBreak || ended) return PlayerTap.nothing;
  if (state == PlayerState.playing) return PlayerTap.pause;
  return PlayerTap.start;
}

/// Whether the play glyph is drawn.
///
/// Never over playing video — YouTube's terms forbid an overlay there, and
/// `_trackStrip` lives under the player for the same reason. Never while Gilli
/// is asking either: a play button on the frame reads as the way out of the
/// question, which is the one thing it must not be.
@visibleForTesting
bool showsPlayGlyph({
  required bool gilliHasVideo,
  required bool onBreak,
  required bool ended,
  required bool childPaused,
  required PlayerState state,
}) {
  if (gilliHasVideo || onBreak || ended) return false;
  final stalled = state == PlayerState.unStarted || state == PlayerState.cued;
  return childPaused || stalled;
}

/// Where a drag on the track is allowed to land.
///
/// Backwards is free: a child who missed something should be able to go back
/// and see it again, and nothing is skipped by doing so.
///
/// Forwards stops at the next question they have not been asked yet. The
/// questions are the product — a scrub bar that runs past them is a skip
/// button, and a child finds that in one afternoon. So the bar drags right up
/// to the next dot and no further, which also makes the dot mean something:
/// it is where the video is going to stop for you.
@visibleForTesting
double seekTargetFor({
  required double wanted,
  required int durationS,
  required double positionS,
  required List<int> questionTimes,
  required int asked,
}) {
  final end = durationS.toDouble();
  var target = wanted.clamp(0.0, end < 0 ? 0.0 : end);
  if (target <= positionS) return target; // backwards, or standing still
  if (asked < questionTimes.length) {
    final nextQuestion = questionTimes[asked].toDouble();
    if (nextQuestion >= positionS) target = math.min(target, nextQuestion);
  }
  return target;
}

enum _Phase {
  connecting,
  watching,
  paused, // server said pause; ask is on its way
  asking, // Gilli is speaking the question
  listening, // kid may answer now
  answered, // waiting for the reply
  replying, // Gilli is replying
  ended,
  error,
}

class _SessionScreenState extends State<SessionScreen> {
  late final Kid _kid = context.read<AppState>().activeKid!;
  AgeBand get _band => _kid.band;
  bool get _preReader => _band == AgeBand.b4to6;

  late final YoutubePlayerController _yt = YoutubePlayerController.fromVideoId(
    videoId: widget.video.id,
    autoPlay: true,
    params: kidPlayerParams,
  );

  /// Kid mode's one ground, the same as the shelf this sits on top of.
  final KidPalette _palette = KidPalette.nightTime;

  final _ears = KidEars();
  GilliVoice get _voice => context.read<GilliVoice>();

  SessionSocket? _socket;
  String? _sessionId;
  StreamSubscription<ServerMessage>? _sub;
  StreamSubscription<YoutubePlayerValue>? _ytSub;
  StreamSubscription<YoutubeVideoState>? _posSub;
  Timer? _positionTimer;
  Timer? _listenWindow;
  Timer? _nudge;

  _Phase _phase = _Phase.connecting;
  String _language = 'en';
  double _positionS = 0;
  PlayerState _playerState = PlayerState.unknown;
  bool _serverPaused = false;
  bool _ended = false;

  /// True once a movement break has taken the screen. Nothing here plays,
  /// asks or ends after that.
  bool _onBreak = false;
  String? _errorText;

  AskMessage? _ask;

  /// Where this video's questions are, so the child can see them coming. The
  /// server still decides when to ask; these only draw the strip.
  List<int> _questionTimes = const [];
  int _asked = 0;

  /// Position, as something the strip alone can listen to.
  ///
  /// A `setState` twice a second would rebuild the whole screen — the player
  /// subtree included — to move a bar six pixels. The embed survives that
  /// (it is behind a GlobalKey) but nothing else about it is worth paying for.
  final _position = ValueNotifier<double>(0);

  /// True when the browser kept the video muted and a child has to ask for
  /// sound themselves.
  ///
  /// The automatic path works on every browser that lets a page unmute what it
  /// started. Where it does not — iOS is the one that matters — a silent video
  /// is a broken app that looks like a working one, so this puts a button in
  /// HeyGilli's own bar rather than leaving a child watching a mime.
  final _needsSound = ValueNotifier<bool>(false);

  /// True when the child paused it themselves. Deliberately separate from
  /// `_serverPaused`: Gilli's pause is the session working, and this one is
  /// somebody deciding they want a moment.
  bool _childPaused = false;

  /// A finger is on the question track. While it is, the strip shows where the
  /// finger is rather than where the video is, and the player is left alone
  /// until it lifts: one seek at the end instead of one per frame of a drag.
  final _scrubbing = ValueNotifier<bool>(false);

  /// What to offer at the end. Gilli's last line asks "shall we watch one
  /// more?", and until these were here the screen closed itself 1.2 seconds
  /// later — a question asked and then taken away before it could be answered.
  List<Video> _nextUp = const [];

  /// Whether to draw the play glyph — the child paused, or nothing ever
  /// started. Never true while Gilli has the video.
  final _showPlay = ValueNotifier<bool>(false);

  /// Whether the unmute has already been attempted for this session.
  bool _unmuteTried = false;

  /// How many more times the child may ask to hear this question.
  ///
  /// SPEC 7.4 allows one, and the gateway enforces the same cap — this only
  /// stops the button offering something that would be ignored. Reset when a
  /// new question arrives, and deliberately *not* when the same one comes back
  /// down: a repeat arrives as an `ask` like any other, and resetting on that
  /// would hand out an unlimited supply.
  int _repeatsLeft = _repeatsPerQuestion;

  /// True from the tap until the question comes back, so a child pressing
  /// twice does not spend two.
  bool _repeatPending = false;

  /// The word Gilli actually said out loud for this question, when it could.
  /// Null when the question carried none, and null when the device had no
  /// voice for it: in both cases the screen shows nothing extra.
  SeededWord? _seed;
  ReplyMessage? _reply;
  HintMessage? _hint;
  bool _answered = false;
  Gesture _gesture = Gesture.idle;
  int _gestureTick = 0;

  /// Bumped on every answer Gilli celebrates; see [GilliWidget.celebrateTick].
  int _celebrateTick = 0;
  Future<void> _speaking = Future.value();
  Future<void>? _replyJob;
  String _endLine = '';

  @override
  void initState() {
    super.initState();
    _ytSub = _yt.stream.listen(_onPlayerValue);
    _posSub = _yt.videoStateStream.listen((s) {
      _positionS = s.position.inMilliseconds / 1000;
      // Not while a finger is on the strip. The player reports every 100ms and
      // a seek takes longer than that to land, so following both at once is
      // the thumb being dragged one way and yanked back the other.
      if (!_scrubbing.value) _position.value = _positionS;
    });
    // Some webviews ignore autoplay; give the player one more push.
    _nudge = Timer(const Duration(seconds: 5), () {
      if (_playerState == PlayerState.unStarted ||
          _playerState == PlayerState.cued) {
        _yt.playVideo();
      }
    });
    _connect();
  }

  // ---------------------------------------------------------------- lifecycle

  Future<void> _connect() async {
    final gateway = context.read<AppState>().gateway;
    try {
      final result = await gateway.startSession(
        kidId: _kid.id,
        videoId: widget.video.id,
        device: BuildConfig.device,
      );
      // A break is running: nothing plays, so go straight to it rather than
      // showing a child a 409.
      if (result case SessionBlockedByBreak(:final activeBreak)) {
        if (mounted) _openBreak(activeBreak);
        return;
      }
      final start = (result as SessionStarted).session;
      _sessionId = start.sessionId;
      final socket = await gateway.openSession(start.sessionId);
      if (!mounted) {
        await socket.close();
        return;
      }
      _socket = socket;
      _sub = socket.messages.listen(
        _onMessage,
        onError: (Object e) => _fail('Connection lost: $e'),
      );
      // Ask the recogniser before saying hello, so the plan the server builds
      // is one this device can actually answer. A voice question on a device
      // that cannot listen is a child sitting in front of a question with no
      // way to answer it — and until now that was every question, at every age
      // above 4_6, for as long as the session lasted.
      final canListen = await _ears.init();
      if (!mounted) return;
      socket.send(HelloMessage(canListen: canListen));
      // Ready is what makes it "watching"; until then we still play.
      _positionTimer = Timer.periodic(
        const Duration(milliseconds: 500),
        (_) => _tickPosition(),
      );
    } catch (e) {
      _fail('Could not start the session: $e');
    }
  }

  void _fail(String text) {
    if (!mounted || _ended) return;
    setState(() {
      _errorText = text;
      _phase = _Phase.error;
    });
  }

  @override
  void dispose() {
    _position.dispose();
    _positionTimer?.cancel();
    _listenWindow?.cancel();
    _nudge?.cancel();
    _sub?.cancel();
    _ytSub?.cancel();
    _posSub?.cancel();
    _socket?.close();
    final id = _sessionId;
    if (id != null) {
      // Fire and forget; the screen is already going away.
      unawaited(context.read<AppState>().gateway.endSession(id));
    }
    _needsSound.dispose();
    _showPlay.dispose();
    _scrubbing.dispose();
    _ears.dispose();
    _voice.stop();
    _yt.close();
    super.dispose();
  }

  // ---------------------------------------------------------------- player

  void _onPlayerValue(YoutubePlayerValue v) {
    if (v.playerState != _playerState) {
      debugPrint('[yt] ${v.playerState} error=${v.error}');
    }
    _playerState = v.playerState;
    _syncPlayGlyph();
    // Every time it starts playing, not once: the captions module is loaded
    // with the video, so a single call at the top of the session lands before
    // there is anything to unload.
    if (v.playerState == PlayerState.playing) {
      hideCaptions(_yt);
      unawaited(_unmuteOnce());
    }
    if (v.playerState == PlayerState.ended && !_ended) {
      // The gateway normally sends `end` itself; this covers a missed frame.
      Future<void>.delayed(const Duration(seconds: 2), () {
        if (mounted && !_ended) {
          _onMessage(const EndMessage(summaryTtsUrl: '', wordsSaid: []));
        }
      });
    }
  }

  void _syncPlayGlyph() {
    _showPlay.value = showsPlayGlyph(
      gilliHasVideo: _gilliHasVideo,
      onBreak: _onBreak,
      ended: _ended,
      childPaused: _childPaused,
      state: _playerState,
    );
  }

  /// The child's own tap on the video.
  ///
  /// `pointerEvents: none` keeps them away from "Watch on YouTube" and the
  /// related-videos panel, and it takes the ordinary tap with it. This gives
  /// that tap back in our own layer, where it can do two things and nothing
  /// else: pause what is playing, and start what never started.
  Future<void> _onPlayerTap() async {
    final tap = playerTapFor(
      gilliHasVideo: _gilliHasVideo,
      onBreak: _onBreak,
      ended: _ended,
      state: _playerState,
    );
    if (tap == PlayerTap.nothing) return;

    if (tap == PlayerTap.pause) {
      setState(() => _childPaused = true);
      await _yt.pauseVideo();
    } else {
      setState(() => _childPaused = false);
      // A tap is a user gesture, which is the one thing a browser that refused
      // to autoplay will accept. `_nudge` calls `playVideo()` too and cannot
      // help here: it is not a gesture, which is why a blocked video sat on
      // the poster for ever with no way out of it.
      await _yt.playVideo();
      // The same gesture is what the unmute was missing, so let it try again.
      _unmuteTried = false;
      unawaited(_unmuteOnce());
    }
    _syncPlayGlyph();
  }

  /// Where a drag would land, given the rules and where the video is.
  double _scrubTarget(double wanted) => seekTargetFor(
    wanted: wanted,
    durationS: widget.video.durationS,
    positionS: _positionS,
    questionTimes: _questionTimes,
    asked: _asked,
  );

  /// A finger moving along the question track.
  ///
  /// Nothing is asked of the player here. The strip alone follows the finger,
  /// clamped by the same rule the seek will use, so the thumb visibly refuses
  /// to go past the next question rather than sliding there and springing
  /// back. Gated like the tap: while Gilli has the video the strip shows the
  /// position and does not move.
  void _onScrub(double wanted) {
    if (_gilliHasVideo || _onBreak || _ended) return;
    _scrubbing.value = true;
    _position.value = _scrubTarget(wanted);
  }

  /// The finger came off. One seek, to wherever the strip ended up.
  Future<void> _onScrubEnd() async {
    if (!_scrubbing.value) return;
    _scrubbing.value = false;
    if (_gilliHasVideo || _onBreak || _ended) return;
    // `_position` was clamped on the way in by `_onScrub`, so this is already
    // a legal place to be.
    final target = _position.value;
    _positionS = target;
    await _yt.seekTo(seconds: target, allowSeekAhead: true);
  }

  /// Turn the sound on, once, and find out whether it worked.
  ///
  /// The video is started muted so that it starts at all (see
  /// [kidPlayerParams]). Asking is not the same as being obeyed: a browser may
  /// refuse to unmute audio the user has not asked for, and it refuses
  /// silently. So this reads the player back rather than trusting the call,
  /// and if the sound is still off it says so instead of leaving a child in
  /// front of a silent video wondering why Gilli has stopped talking.
  Future<void> _unmuteOnce() async {
    if (_unmuteTried) return;
    _unmuteTried = true;
    await _restoreSound();
  }

  Future<void> _restoreSound() async {
    try {
      await _yt.unMute();
      final stillMuted = await _yt.isMuted;
      if (mounted) _needsSound.value = stillMuted;
    } catch (e) {
      debugPrint('[yt] could not unmute: $e');
      if (mounted) _needsSound.value = true;
    }
  }

  void _tickPosition() {
    if (_serverPaused || _playerState != PlayerState.playing) return;
    _socket?.send(PositionMessage(_positionS));
  }

  // ---------------------------------------------------------------- protocol

  void _onMessage(ServerMessage m) {
    if (!mounted || _onBreak) return;
    debugPrint('[ws] ${m.runtimeType}');
    switch (m) {
      case ReadyMessage(:final language, :final questionTimes):
        setState(() {
          _language = language;
          _questionTimes = questionTimes;
          if (_phase == _Phase.connecting) _phase = _Phase.watching;
        });
      case PauseMessage():
        _serverPaused = true;
        _yt.pauseVideo();
        setState(() => _phase = _Phase.paused);
      case AskMessage():
        _handleAsk(m);
      case HintMessage():
        _handleHint(m);
      case ReplyMessage():
        _replyJob = _handleReply(m);
      case ResumeMessage():
        _handleResume();
      case BreakStartedMessage(:final movementBreak):
        _handleBreak(movementBreak);
      case EndMessage():
        _handleEnd(m);
      case ErrorMessage(:final message):
        // Never blocks the kid: shown to 7+ as a quiet line, spoken to nobody.
        if (!_preReader) setState(() => _errorText = message);
      case UnknownMessage():
        break;
    }
  }

  Future<void> _handleAsk(AskMessage ask) async {
    _listenWindow?.cancel();
    // The same `q` coming back down is the repeat this screen asked for, not a
    // new question, so the allowance stays where it is.
    final again = _ask?.q == ask.q;
    setState(() {
      // Counted from the question's own index, so hearing one again does not
      // move the child along the strip.
      if (!again) _asked = ask.q + 1;
      if (!again) _repeatsLeft = _repeatsPerQuestion;
      _repeatPending = false;
      _ask = ask;
      _seed = null;
      _reply = null;
      _hint = null;
      _answered = false;
      _errorText = null;
      _gesture = ask.gesture;
      _gestureTick++;
      _phase = _Phase.asking;
    });
    final text = ask.fallbackSpeech;
    var ttsUrl = ask.ttsUrl;
    if (ttsUrl.isEmpty && text != null && text.isNotEmpty) {
      try {
        final gateway = context.read<AppState>().gateway;
        ttsUrl = await gateway.speechUrl(text, slow: _preReader);
      } catch (_) {}
    }
    _speaking = _voice.say(
      url: ttsUrl,
      fallbackText: text,
      language: _ttsLanguage(text),
      slow: _preReader,
    );
    await _speaking;
    if (!mounted || _ask != ask) return;
    await _offerWord(ask);
    if (!mounted || _ask != ask) return;
    setState(() => _phase = _Phase.listening);

    // The listening window opens after the question is spoken. If nothing
    // comes back in time the client says so (`input: none`); the gateway
    // would assume it anyway after listen_ms + 1500 ms.
    _listenWindow = Timer(Duration(milliseconds: ask.listenMs + 1000), () {
      if (_ears.listening) return; // mid-utterance: let it finish
      _sendAnswer(ask, null);
    });
    if (ask.input != QuestionInput.pick && _band.autoListens) {
      // SPEC 9.2: pre-readers do not have to press anything.
      _startListening();
    }
  }

  /// `{t: "hint"}`: the child has gone quiet, so Gilli nudges. The question
  /// stays open and the window starts over, exactly as after a repeat: a hint
  /// followed by the video starting again would be worse than none.
  Future<void> _handleHint(HintMessage hint) async {
    final ask = _ask;
    if (ask == null || ask.q != hint.q || _answered || _reply != null) return;
    _listenWindow?.cancel();
    // Stop the mic first, or the recogniser hears Gilli give the hint and
    // hands that back as the child's answer.
    await _ears.stopListening();
    if (!mounted || _ask != ask || _answered) return;
    setState(() {
      _hint = hint;
      _gesture = hint.gesture;
      _gestureTick++;
      _phase = _Phase.asking;
    });
    final hintText = hint.fallbackSpeech ?? ask.fallbackSpeech;
    var hintUrl = hint.ttsUrl;
    if (hintUrl.isEmpty && hintText != null && hintText.isNotEmpty) {
      try {
        final gateway = context.read<AppState>().gateway;
        hintUrl = await gateway.speechUrl(hintText, slow: _preReader);
      } catch (_) {}
    }
    _speaking = _voice.say(
      url: hintUrl,
      fallbackText: hintText,
      language: _ttsLanguage(hintText),
      slow: _preReader,
    );
    await _speaking;
    if (!mounted || _ask != ask || _answered) return;
    setState(() => _phase = _Phase.listening);
    _listenWindow = Timer(Duration(milliseconds: hint.listenMs + 1000), () {
      if (_ears.listening) return;
      _sendAnswer(ask, null);
    });
    if (ask.input != QuestionInput.pick && _band.autoListens) {
      _startListening();
    }
  }

  /// The one word this session teaches, said after the question and before
  /// the listening window opens (PROTOCOL "Bilingual word seeding").
  ///
  /// Polly has no Urdu voice, so the term is spoken by the device. A device
  /// with no Urdu voice gets the English question and no seed: [_seed] stays
  /// null, nothing extra is said, and nothing extra is shown. A silent gap
  /// where a word should have been would be worse than not offering one.
  Future<void> _offerWord(AskMessage ask) async {
    final word = ask.word;
    if (word == null) return;
    final spoken = await _voice.saySeed(word);
    if (!mounted || _ask != ask) return;
    setState(() => _seed = spoken ? word : null);
  }

  /// Straight into the next one, replacing this screen rather than stacking on
  /// it: three videos in a row must not be three screens deep, and the way out
  /// of kid mode is the PIN, never the back arrow.
  void _openNext(Video video) {
    _voice.stop();
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => SessionScreen(video: video)),
    );
  }

  /// A few videos to offer at the end, from the same shelf the child came
  /// from. Failure is not worth a message: they get the shelf itself instead,
  /// which is where these came from.
  Future<void> _loadNextUp() async {
    try {
      final rows = await context.read<AppState>().gateway.home(_kid.id);
      final seen = <String>{widget.video.id};
      final out = <Video>[];
      for (final row in rows) {
        for (final v in row.videos) {
          if (seen.add(v.id)) out.add(v);
          if (out.length == 3) break;
        }
        if (out.length == 3) break;
      }
      if (mounted) setState(() => _nextUp = out);
    } catch (e) {
      debugPrint('[next-up] $e');
    }
  }

  Future<void> _startListening() async {
    final ask = _ask;
    if (ask == null || _answered || _phase != _Phase.listening) return;
    // Recognise in the language Gilli just spoke: a kid answers the question
    // in the language it was asked. The gateway scores whatever comes back.
    final heard = await _ears.listen(
      window: Duration(milliseconds: ask.listenMs),
      language: ask.fallbackSpeech == null
          ? _language
          : _ttsLanguage(ask.fallbackSpeech),
    );
    if (!mounted || _ask != ask || _answered) return;
    _sendAnswer(ask, heard);
  }

  /// Builds the `answer` message per PROTOCOL.md. The transcript goes to the
  /// gateway and nowhere else; it is not kept on this device (SPEC 7.4).
  void _sendAnswer(AskMessage ask, Heard? heard) {
    if (_answered) return;
    _answered = true;
    _listenWindow?.cancel();
    final ClientMessage msg;
    switch (ask.input) {
      case QuestionInput.copy:
        msg = heard != null && heard.heardAnything
            ? AnswerMessage.copy(ask.q)
            : AnswerMessage.none(ask.q);
      case QuestionInput.voice:
        msg = heard != null && heard.transcript.isNotEmpty
            ? AnswerMessage.voice(ask.q, heard.transcript)
            : AnswerMessage.none(ask.q);
      case QuestionInput.pick:
        msg = AnswerMessage.none(ask.q);
    }
    _socket?.send(msg);
    setState(() => _phase = _Phase.answered);
  }

  /// "Say it again". The server sends the question back down and starts the
  /// listening window over, so this only asks — it never replays anything on
  /// its own, which would mean speaking over a reply already on its way.
  Future<void> _onRepeat() async {
    final ask = _ask;
    if (ask == null || _answered || _repeatPending || _repeatsLeft <= 0) return;
    setState(() {
      _repeatPending = true;
      _repeatsLeft--;
    });
    await _voice.stop();
    // Stop the mic first, or the recogniser hears Gilli read the question and
    // hands that back as the child's answer.
    await _ears.stopListening();
    _listenWindow?.cancel();
    _socket?.send(RepeatMessage(ask.q));
  }

  void _onPick(int index) {
    final ask = _ask;
    if (ask == null || _answered) return;
    _answered = true;
    _listenWindow?.cancel();
    _socket?.send(AnswerMessage.pick(ask.q, index));
    setState(() => _phase = _Phase.answered);
  }

  Future<void> _handleReply(ReplyMessage reply) async {
    _listenWindow?.cancel();
    await _ears.stopListening();
    if (!mounted || _phase == _Phase.watching) return;
    if (reply.result.celebrates) KidSounds.instance.cheer();
    setState(() {
      _reply = reply;
      _gesture = reply.gesture;
      _gestureTick++;
      if (reply.result.celebrates) _celebrateTick++;
      _phase = _Phase.replying;
    });
    final line = reply.text ?? reply.modelWord;
    var ttsUrl = reply.ttsUrl;
    if (ttsUrl.isEmpty && line != null && line.isNotEmpty) {
      try {
        final gateway = context.read<AppState>().gateway;
        ttsUrl = await gateway.speechUrl(line, slow: _preReader);
      } catch (_) {}
    }
    _speaking = _voice.say(
      url: ttsUrl,
      fallbackText: line,
      language: _ttsLanguage(line),
      slow: _preReader,
    );
    await _speaking;
  }

  Future<void> _handleResume() async {
    // If a reply is currently in flight or being spoken, wait for it to finish
    // so the video does not resume and play while Gilli is still talking.
    final replyJob = _replyJob;
    if (replyJob != null) {
      await replyJob.timeout(const Duration(seconds: 10), onTimeout: () {});
      _replyJob = null;
    }
    // Also wait for any active voice speaking to finish before resuming.
    await _speaking.timeout(const Duration(seconds: 8), onTimeout: () {});
    // Gilli must never speak in the background over playing video.
    await _voice.stop();
    if (!mounted) return;
    setState(() {
      _serverPaused = false;
      _ask = null;
      _reply = null;
      _gesture = Gesture.idle;
      _phase = _Phase.watching;
    });
    await _yt.playVideo();
    _socket?.send(const ResumedMessage());
  }

  /// `{t: "break"}`: stop the video now and hand the screen to Gilli. The
  /// session is over as far as this screen is concerned; the break decides
  /// when anything plays again.
  Future<void> _handleBreak(BreakPeriod movementBreak) async {
    if (_onBreak || _ended) return;
    _onBreak = true;
    _serverPaused = true;
    final gateway = context.read<AppState>().gateway;
    _positionTimer?.cancel();
    _listenWindow?.cancel();
    await _yt.pauseVideo();
    await _ears.stopListening();
    await _voice.stop();
    // Nothing else is coming down this socket, and the session is over: end
    // it now rather than leaving it open behind the break.
    await _sub?.cancel();
    await _socket?.close();
    _socket = null;
    final id = _sessionId;
    _sessionId = null;
    if (id != null) unawaited(gateway.endSession(id));
    if (!mounted) return;
    _openBreak(movementBreak);
  }

  /// The break sits on top of this screen and, when it is over, everything
  /// above the kid's home is popped at once. The home screen re-checks the
  /// watch state as it comes back, so it never shows rows a break still bars.
  void _openBreak(BreakPeriod period) {
    _onBreak = true;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (routeContext) => BreakScreen(
          kid: _kid,
          breakPeriod: period,
          onFinished: () =>
              Navigator.of(routeContext).popUntil((r) => r.isFirst),
        ),
      ),
    );
  }

  Future<void> _handleEnd(EndMessage end) async {
    if (_ended) return;
    _ended = true;
    _positionTimer?.cancel();
    _listenWindow?.cancel();
    await _ears.stopListening();
    if (!mounted) return;
    setState(() {
      _ask = null;
      _reply = null;
      _endLine = '';
      _gesture = Gesture.cheer;
      _gestureTick++;
      _phase = _Phase.ended;
    });
    // SPEC update: No spoken completion sign-off voice prompt at the end of the video.
    // Transition straight to showing Next Up recommendations.
    if (!mounted) return;
    await _loadNextUp();
    if (!mounted) return;
    if (_nextUp.isEmpty) {
      // Nothing to offer, so do what this always did rather than leave a child
      // on a dead screen: back to the shelf, where there may be more.
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      if (mounted) Navigator.of(context).maybePop();
    }
  }

  String _ttsLanguage(String? text) =>
      text != null && isUrduScript(text) ? 'ur' : 'en';

  /// Sizes for the stage under the video, derived from the space it actually
  /// has: a 16:9 embed leaves a tablet in landscape only ~190 dp below it.
  /// Cards never go under 120 dp (SPEC 9.2 tap targets); on a 360 dp phone
  /// they wrap 2 + 1 instead of shrinking.
  _StageSizes _sizes(BoxConstraints box, bool wide) {
    final h = box.maxHeight;
    final w = box.maxWidth;
    if (wide) {
      // Side panel beside the paused video: gilli / cards / mic stacked.
      final gilli = (h * 0.28).clamp(88.0, 160.0);
      final mic = (h * 0.2).clamp(64.0, 108.0);
      final card = ((w - 32 - 2 * PickCards.gap) / 3).floorToDouble();
      return _StageSizes(
        gilli: gilli,
        mic: mic,
        card: card.clamp(120.0, 170.0),
      );
    }
    final card = ((w - 16 - 2 * PickCards.gap) / 3).floorToDouble();
    return _StageSizes(
      gilli: _isPaused ? (h * 0.3).clamp(96.0, 132.0) : 64,
      mic: 108,
      card: card.clamp(120.0, 150.0),
    );
  }

  late _StageSizes _stage = const _StageSizes(gilli: 132, mic: 108, card: 124);

  // ---------------------------------------------------------------- ui

  /// The embed keeps one identity across layout changes so the WebView is
  /// never recreated (that would restart the video mid-session).
  final _playerKey = GlobalKey();

  /// True whenever Gilli has stopped the video for a question or session end.
  /// Playback controls and scrubbing are disabled; stage area is active.
  bool get _gilliHasVideo =>
      _serverPaused ||
      switch (_phase) {
        _Phase.paused ||
        _Phase.asking ||
        _Phase.listening ||
        _Phase.answered ||
        _Phase.replying ||
        _Phase.ended ||
        _Phase.error => true,
        _ => false,
      };

  bool get _isPaused => _gilliHasVideo;

  /// The question strip, under the player and never on it: HeyGilli plays by
  /// YouTube's rules and those forbid overlays during playback.
  Widget _trackStrip() => Padding(
    padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
    child: ValueListenableBuilder<bool>(
      valueListenable: _scrubbing,
      builder: (context, scrubbing, _) => ValueListenableBuilder<double>(
        valueListenable: _position,
        builder: (context, seconds, _) => QuestionTrack(
          positionS: seconds,
          durationS: widget.video.durationS,
          questionTimes: _questionTimes,
          askedCount: _asked,
          scrubbing: scrubbing,
          onScrub: (_gilliHasVideo || _onBreak || _ended) ? null : _onScrub,
          onScrubEnd: (_gilliHasVideo || _onBreak || _ended) ? null : _onScrubEnd,
        ),
      ),
    ),
  );

  Widget _player(bool rounded) => ClipRRect(
    borderRadius: BorderRadius.circular(rounded ? 20 : 0),
    child: Stack(
      fit: StackFit.expand,
      children: [
        // The embed must never receive a pointer — that is the whole of
        // `pointerEvents: none`. Saying it here as well is what lets the tap
        // target below actually see a tap: on web the platform view is a DOM
        // element sitting above Flutter's scene, and it swallowed every click
        // before the gesture arena heard about it.
        IgnorePointer(
          child: KeyedSubtree(
            key: _playerKey,
            child: YoutubePlayer(
              controller: _yt,
              backgroundColor: _palette.tile,
              enableFullScreenOnVerticalDrag: false,
              autoFullScreen: false,
            ),
          ),
        ),
        // Nothing is drawn here while the video plays: YouTube's terms forbid
        // an overlay over playing video, and this one is transparent and
        // empty until the video is stopped. It is a hit target, not a skin.
        Positioned.fill(
          child: GestureDetector(
            key: const Key('player-tap'),
            behavior: HitTestBehavior.opaque,
            onTap: _onPlayerTap,
            child: ValueListenableBuilder<bool>(
              valueListenable: _showPlay,
              builder: (context, show, _) => show
                  ? const Center(child: _PlayGlyph())
                  : const SizedBox.expand(),
            ),
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    // Kid mode's one ground, the same as the shelf.
    const palette = KidPalette.nightTime;
    return KidTheme(palette: palette, child: _build(context, palette));
  }

  Widget _build(BuildContext context, KidPalette palette) {
    return Scaffold(
      backgroundColor: palette.ground,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, box) {
            final w = box.maxWidth;
            final h = box.maxHeight;
            final wide = w > h && w >= 640;
            const anim = Duration(milliseconds: 350);

            if (wide) {
              if (!_isPaused) {
                // Playing: the video takes everything above a slim bar that
                // holds the exit arrow and a small Gilli. Nothing is drawn
                // over the video itself.
                const bar = 64.0;
                final videoH = math.min(h - bar, w * 9 / 16);
                final videoW = videoH * 16 / 9;
                return Column(
                  children: [
                    Expanded(
                      child: Center(
                        child: AnimatedContainer(
                          duration: anim,
                          width: videoW,
                          height: videoH,
                          child: _player(false),
                        ),
                      ),
                    ),
                    _trackStrip(),
                    SizedBox(
                      height: bar,
                      child: _WatchBar(
                        title: _band.showsVideoTitles
                            ? widget.video.title
                            : null,
                        onHome: () => Navigator.of(context).maybePop(),
                        gilli: _smallGilli(44),
                        sound: SoundButton(
                          needsSound: _needsSound,
                          onTap: _restoreSound,
                        ),
                      ),
                    ),
                  ],
                );
              }
              // Paused: video shrinks left (pre-readers keep it larger because
              // the question is about what is on the frame), stage grows right.
              final frac = _preReader ? 0.54 : 0.44;
              final videoW = w * frac;
              final videoH = math.min(h - 56, videoW * 9 / 16);
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: videoW,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _TopBar(
                          title: _band.showsVideoTitles
                              ? widget.video.title
                              : null,
                          onHome: () => Navigator.of(context).maybePop(),
                          sound: SoundButton(
                            needsSound: _needsSound,
                            onTap: _restoreSound,
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.only(left: 12),
                          child: AnimatedContainer(
                            duration: anim,
                            height: videoH,
                            child: _player(true),
                          ),
                        ),
                        // Under the video, as it is while playing. It sat in
                        // this Row once, where it had no width to measure: the
                        // track sizes itself from the space it is given, got
                        // infinity, and the whole screen went blank at the
                        // first question.
                        Padding(
                          padding: const EdgeInsets.only(left: 12),
                          child: _trackStrip(),
                        ),
                      ],
                    ),
                  ),
                  Expanded(child: _buildStage(true)),
                ],
              );
            }

            // Portrait fallback (orientation is forced to landscape, so this is
            // rare): 16:9 video on top, small Gilli while playing, full stage
            // when paused.
            final videoH = (w * 9 / 16).clamp(0.0, h * 0.55);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _TopBar(
                  title: _band.showsVideoTitles ? widget.video.title : null,
                  onHome: () => Navigator.of(context).maybePop(),
                  sound: SoundButton(
                    needsSound: _needsSound,
                    onTap: _restoreSound,
                  ),
                ),
                SizedBox(
                  height: videoH,
                  child: Center(
                    child: AspectRatio(
                      aspectRatio: 16 / 9,
                      child: _player(false),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: _trackStrip(),
                ),
                Expanded(child: _buildStage(false)),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _smallGilli(double size) {
    final voice = context.watch<GilliVoice>();
    return ListenableBuilder(
      listenable: _ears,
      builder: (context, _) => GilliWidget(
        size: size,
        gesture: _gesture,
        gestureTick: _gestureTick,
        celebrateTick: _celebrateTick,
        talking: voice.speaking,
        listening: _ears.listening,
      ),
    );
  }

  /// Everything under (or beside) the video.
  Widget _buildStage(bool wide) {
    final voice = context.watch<GilliVoice>();
    return LayoutBuilder(
      builder: (context, box) {
        _stage = _sizes(box, wide);
        return ListenableBuilder(
          listenable: _ears,
          builder: (context, _) {
            final canRepeatGilli =
                (_phase == _Phase.asking || _phase == _Phase.listening) &&
                !_answered &&
                !_repeatPending &&
                _repeatsLeft > 0 &&
                _ask != null;
            final gilliWidget = GilliWidget(
              size: _stage.gilli,
              gesture: _gesture,
              gestureTick: _gestureTick,
              celebrateTick: _celebrateTick,
              talking: voice.speaking,
              listening: _ears.listening,
            );
            final gilli = canRepeatGilli
                ? GestureDetector(
                    key: const Key('gilli-repeat-tap'),
                    behavior: HitTestBehavior.opaque,
                    onTap: withTap(_onRepeat),
                    child: Tooltip(
                      message: 'Say it again',
                      child: gilliWidget,
                    ),
                  )
                : gilliWidget;
            final answer = _buildAnswerArea(wide);
            final mic = _needsMic ? _buildMic(_stage.mic) : null;

            if (wide) {
              // Beside the paused video: Gilli on top, answers in the middle,
              // mic at the bottom. Cards wrap 2 + 1 when the panel is narrow.
              return Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Column(
                  spacing: 8,
                  children: [
                    gilli,
                    Expanded(child: Center(child: answer)),
                    ?mic,
                  ],
                ),
              );
            }
            return Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
              child: Column(
                spacing: 10,
                children: [
                  gilli,
                  Expanded(child: Center(child: answer)),
                  ?mic,
                ],
              ),
            );
          },
        );
      },
    );
  }

  bool get _needsMic {
    final ask = _ask;
    if (ask == null || ask.input == QuestionInput.pick) return false;
    return _phase == _Phase.listening || _phase == _Phase.asking;
  }

  Widget _buildMic(double size) {
    final enabled = _phase == _Phase.listening && !_answered;
    return MicButton(
      size: size,
      listening: _ears.listening,
      enabled: enabled,
      onPressStart: _startListening,
      onPressEnd: _ears.finishNow,
    );
  }

  Widget _buildAnswerArea(bool wide) {
    final showText = _band.showsQuestionText;
    switch (_phase) {
      case _Phase.connecting:
        return SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(
            strokeWidth: 3,
            color: _palette.accent,
          ),
        );
      case _Phase.error:
        return Column(
          mainAxisSize: MainAxisSize.min,
          spacing: 12,
          children: [
            if (showText)
              Text(
                _errorText ?? 'Something went wrong.',
                textAlign: TextAlign.center,
                style: HgText.body(color: _palette.quiet),
              ),
            FilledButton.icon(
              onPressed: () => Navigator.of(context).maybePop(),
              icon: const Icon(Icons.home_rounded),
              label: const Text('Home'),
            ),
          ],
        );
      case _Phase.watching:
      case _Phase.paused:
        // Quiet while the video plays: no text for anyone, just Gilli.
        return const SizedBox.shrink();
      case _Phase.ended:
        return Column(
          mainAxisSize: MainAxisSize.min,
          spacing: 14,
          children: [
            if (showText)
              Text(
                _endLine,
                textAlign: TextAlign.center,
                style: HgText.display(size: _band.questionTextSize),
              ),
            // Gilli just asked whether they want another one. These are the
            // answer, in pictures, because the child being asked may not read.
            if (_nextUp.isNotEmpty)
              Wrap(
                spacing: 12,
                runSpacing: 12,
                alignment: WrapAlignment.center,
                children: [
                  for (final v in _nextUp)
                    _NextUpCard(video: v, onTap: tapping(() => _openNext(v))),
                ],
              ),
            SizedBox(
              height: 56,
              child: FilledButton.icon(
                onPressed: () => Navigator.of(context).maybePop(),
                icon: const Icon(Icons.home_rounded, size: 28),
                label: Text(showText ? 'Home' : ''),
              ),
            ),
          ],
        );
      case _Phase.asking:
      case _Phase.listening:
      case _Phase.answered:
      case _Phase.replying:
        return _buildQuestion(wide, showText);
    }
  }

  /// The question: text for 7+ (large for 7_8), Urdu line for Urdu sessions,
  /// pick cards or a listening hint. Band 4_6 gets cards or nothing at all;
  /// Gilli and the ring carry the whole interaction.
  Widget _buildQuestion(bool wide, bool showText) {
    final ask = _ask!;
    final reply = _reply;
    final urduLine =
        ask.textUr ??
        (_language == 'ur' && ask.text != null && isUrduScript(ask.text!)
            ? ask.text
            : null);
    final englishLine = ask.text != null && !isUrduScript(ask.text!)
        ? ask.text
        : null;

    final children = <Widget>[];
    if (showText && reply == null) {
      if (englishLine != null) {
        children.add(
          Text(
            englishLine,
            textAlign: TextAlign.center,
            style: HgText.display(size: _band.questionTextSize),
          ),
        );
      }
      if (urduLine != null) {
        children.add(
          Text(
            urduLine,
            textAlign: TextAlign.center,
            textDirection: TextDirection.rtl,
            style: HgText.urdu(size: _band.questionTextSize * 0.8),
          ),
        );
      }
    }
    // Gilli's nudge, under the question, for a child who can read it. It is
    // not the answer, so it can stay up while they think.
    final hint = _hint;
    if (showText && reply == null && hint?.text != null) {
      children.add(
        Text(
          hint!.text!,
          textAlign: TextAlign.center,
          textDirection: isUrduScript(hint.text!)
              ? TextDirection.rtl
              : TextDirection.ltr,
          style: isUrduScript(hint.text!)
              ? HgText.urdu(size: _band.questionTextSize * 0.7)
              : HgText.body(size: 20, color: _palette.quiet),
        ),
      );
    }
    // The word Gilli just said, for a child who can read it. A pre-reader is
    // covered by showText being false: they heard it, and that is the whole
    // interaction for them (SPEC 5.1).
    final seed = _seed;
    if (showText && reply == null && seed != null) {
      children.add(
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              seed.term,
              textAlign: TextAlign.center,
              textDirection: seed.isUrdu
                  ? TextDirection.rtl
                  : TextDirection.ltr,
              style: seed.isUrdu
                  ? HgText.urdu(size: _band.questionTextSize * 0.9)
                  : HgText.display(size: _band.questionTextSize * 0.9),
            ),
            if (seed.gloss.isNotEmpty)
              Text(
                seed.gloss,
                textAlign: TextAlign.center,
                style: HgText.body(size: 18, color: _palette.quiet),
              ),
          ],
        ),
      );
    }
    if (showText && reply != null && reply.text != null) {
      children.add(
        Text(
          reply.text!,
          textAlign: TextAlign.center,
          textDirection: isUrduScript(reply.text!)
              ? TextDirection.rtl
              : TextDirection.ltr,
          style: isUrduScript(reply.text!)
              ? HgText.urdu(size: 24)
              : HgText.display(size: _band.questionTextSize * 0.8),
        ),
      );
    }

    if (ask.input == QuestionInput.pick) {
      // Cards stay up through the reply so the kid sees the one they chose
      // (picked card highlighted, the others dimmed); resume clears them.
      children.add(
        PickCards(
          key: ValueKey('pick-${ask.q}'),
          options: ask.options,
          icons: context.read<IconLibrary>(),
          onPick: _onPick,
          showLabels: showText,
          enabled: _phase == _Phase.listening && !_answered,
          cardSize: _stage.card,
        ),
      );
    } else if (showText && reply == null && _phase == _Phase.listening) {
      final partial = _ears.partial;
      children.add(
        Text(
          partial.isNotEmpty
              ? 'You said: $partial'
              : (_ears.listening ? 'Listening...' : 'Hold the mic and tell me'),
          textAlign: TextAlign.center,
          style: HgText.body(size: 18, color: _palette.quiet),
        ),
      );
    }
    // A child who missed the question had nothing to do about it: the window
    // ran out, Gilli said "no worries" and the video started again, which reads
    // to a child as being told their answer did not matter. Offered for as long
    // as they may still answer, and it goes away once they have used their one
    // (SPEC 7.4) — a button that does nothing is worse than no button.
    if (reply == null &&
        (_phase == _Phase.asking || _phase == _Phase.listening) &&
        _repeatsLeft > 0) {
      children.add(
        _SayItAgainButton(
          showText: showText,
          onPressed: _repeatPending || _answered ? null : withTap(_onRepeat),
        ),
      );
    }
    if (showText && _errorText != null) {
      children.add(
        Text(
          _errorText!,
          // The kid ground is pine; rust is 2.2:1 on it.
          style: HgText.body(size: 13, color: HgColors.accentTint),
        ),
      );
    }

    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        spacing: 14,
        children: children,
      ),
    );
  }
}

/// Thin bar above the video: a home button and, for readers, the title.
class _TopBar extends StatelessWidget {
  const _TopBar({required this.title, required this.onHome, this.sound});
  final String? title;
  final VoidCallback onHome;
  final Widget? sound;

  @override
  Widget build(BuildContext context) {
    final palette = KidPalette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 16, 4),
      child: Row(
        spacing: 8,
        children: [
          IconButton(
            onPressed: onHome,
            iconSize: 30,
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            icon: const Icon(Icons.arrow_back_rounded),
            color: palette.onGround,
            tooltip: 'Home',
          ),
          if (title != null)
            Expanded(
              child: Text(
                title!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: HgText.body(size: 16, color: palette.quiet),
              ),
            )
          else
            const Spacer(),
          ?sound,
        ],
      ),
    );
  }
}

/// One offer at the end of a video: a thumbnail big enough for a small hand,
/// and no text, because the child deciding may not read.
class _NextUpCard extends StatelessWidget {
  const _NextUpCard({required this.video, required this.onTap});

  final Video video;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: video.title,
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Image.network(
          video.thumb,
          width: 148,
          height: 83,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => Container(
            width: 148,
            height: 83,
            color: HgColors.teal,
            child: const Icon(Icons.play_arrow_rounded, color: HgColors.cream),
          ),
        ),
      ),
    ),
  );
}

/// The play glyph, drawn only on a video that is not playing: the child
/// paused it, or nothing ever started and a tap is the only thing that can
/// begin it.
class _PlayGlyph extends StatelessWidget {
  const _PlayGlyph();

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: const BoxDecoration(
      color: Color(0xB3000000),
      shape: BoxShape.circle,
    ),
    child: const Padding(
      padding: EdgeInsets.all(18),
      child: Icon(Icons.play_arrow_rounded, size: 44, color: Colors.white),
    ),
  );
}

/// "Tap for sound", for the browsers that will not unmute on their own.
///
/// Deliberately loud: a pre-reader cannot be told what it is for in words, and
/// a silent video is the failure they are least able to explain to anybody. It
/// disappears the moment the sound is on.
///
/// It lives in HeyGilli's own bar, never over the player — SPEC §5.5.
class SoundButton extends StatelessWidget {
  const SoundButton({super.key, required this.needsSound, required this.onTap});

  final ValueListenable<bool> needsSound;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: needsSound,
    builder: (context, muted, _) => muted
        ? Semantics(
            button: true,
            label: 'Turn the sound on',
            child: GestureDetector(
              onTap: onTap,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: HgColors.mango,
                  borderRadius: BorderRadius.circular(24),
                ),
                // White, not ink: ink on rust is 2.6:1.
                child: const Icon(
                  Icons.volume_off_rounded,
                  color: HgColors.white,
                  size: 26,
                ),
              ),
            ),
          )
        : const SizedBox.shrink(),
  );
}

/// Gilli, mic and pick-card sizes for the current stage box.
class _StageSizes {
  const _StageSizes({
    required this.gilli,
    required this.mic,
    required this.card,
  });
  final double gilli;
  final double mic;
  final double card;
}

/// Slim bar under the playing video: exit arrow, small Gilli, title for 7+.
class _WatchBar extends StatelessWidget {
  const _WatchBar({
    required this.title,
    required this.onHome,
    required this.gilli,
    required this.sound,
  });
  final String? title;
  final VoidCallback onHome;
  final Widget gilli;
  final Widget sound;

  @override
  Widget build(BuildContext context) {
    final palette = KidPalette.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        spacing: 12,
        children: [
          IconButton(
            onPressed: onHome,
            icon: Icon(
              Icons.arrow_back_rounded,
              color: palette.onGround,
              size: 28,
            ),
          ),
          gilli,
          if (title != null)
            Expanded(
              child: Text(
                title!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: HgText.body(size: 16, color: palette.quiet),
              ),
            )
          else
            const Spacer(),
          sound,
        ],
      ),
    );
  }
}

/// "Say it again", in a size a four-year-old can hit (SPEC 9.2 tap targets).
///
/// Icon-only for pre-readers, who have no text anywhere on this screen: the
/// replay arrow is the whole of what they get, and it is the same arrow they
/// have seen on every video player they have ever been handed.
class _SayItAgainButton extends StatelessWidget {
  const _SayItAgainButton({required this.showText, required this.onPressed});
  final bool showText;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = KidPalette.of(context);
    if (!showText) {
      return SizedBox(
        width: 76,
        height: 76,
        child: IconButton.filled(
          onPressed: onPressed,
          style: IconButton.styleFrom(
            backgroundColor: palette.chip,
            foregroundColor: palette.onGround,
            disabledBackgroundColor: palette.chip,
          ),
          icon: const Icon(Icons.replay_rounded, size: 40),
          tooltip: 'Say it again',
        ),
      );
    }
    return SizedBox(
      height: 52,
      child: OutlinedButton.icon(
        onPressed: onPressed,
        icon: const Icon(Icons.replay_rounded, size: 24),
        label: Text(
          'Say it again',
          style: HgText.body(size: 17, color: palette.onGround),
        ),
        style: OutlinedButton.styleFrom(
          foregroundColor: palette.onGround,
          side: BorderSide(color: palette.quiet, width: 2),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(26),
          ),
        ),
      ),
    );
  }
}
