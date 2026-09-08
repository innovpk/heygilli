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
import '../../core/speech.dart';
import '../../core/theme.dart';
import 'break_screen.dart';
import 'captions_off.dart';
import 'gilli_widget.dart';
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
  // Nothing this app sends reaches the embed. Turning the controls off took
  // the bar, but "Watch on YouTube", the share button and "More videos" live
  // in a hover overlay that survives it — on a tablet nothing summons that,
  // and on the web build a mouse does. The player is not hidden, moved or
  // covered: it renders exactly as YouTube serves it, and we simply stop
  // forwarding pointer events into it.
  //
  // The cost is that an ad inside the player cannot be clicked either. That is
  // a deliberate trade for a screen a six-year-old is sitting in front of.
  pointerEvents: PointerEvents.none,
);

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

  /// False until the embed has played a single frame.
  ///
  /// Before that YouTube draws its poster over the video — the title, the
  /// channel, a share button and "Watch on YouTube" — and no player parameter
  /// turns that off. `pointerEvents: none` stops a child reaching any of it,
  /// which is why a paused player is clean: the pause overlay only appears in
  /// answer to a pointer. The poster does not need one. It is simply the
  /// state the player is in before it starts, so the only way past it is to
  /// wait for the first frame and cover what is there until then.
  final _started = ValueNotifier<bool>(false);

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
  bool _answered = false;
  Gesture _gesture = Gesture.idle;
  int _gestureTick = 0;
  Future<void> _speaking = Future.value();
  String _endLine = '';

  @override
  void initState() {
    super.initState();
    _ytSub = _yt.stream.listen(_onPlayerValue);
    _posSub = _yt.videoStateStream.listen((s) {
      _positionS = s.position.inMilliseconds / 1000;
      _position.value = _positionS;
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
      socket.send(const HelloMessage());
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
    _started.dispose();
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
    // Every time it starts playing, not once: the captions module is loaded
    // with the video, so a single call at the top of the session lands before
    // there is anything to unload.
    if (v.playerState == PlayerState.playing) hideCaptions(_yt);
    _started.value = hasStarted(_started.value, v.playerState);
    if (v.playerState == PlayerState.ended && !_ended) {
      // The gateway normally sends `end` itself; this covers a missed frame.
      Future<void>.delayed(const Duration(seconds: 2), () {
        if (mounted && !_ended) {
          _onMessage(const EndMessage(summaryTtsUrl: '', wordsSaid: []));
        }
      });
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
      case ReplyMessage():
        _handleReply(m);
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
      _answered = false;
      _errorText = null;
      _gesture = ask.gesture;
      _gestureTick++;
      _phase = _Phase.asking;
    });
    _speaking = _voice.say(
      url: ask.ttsUrl,
      fallbackText: ask.fallbackSpeech,
      language: _ttsLanguage(ask.fallbackSpeech),
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
    if (!mounted) return;
    setState(() {
      _reply = reply;
      _gesture = reply.gesture;
      _gestureTick++;
      _phase = _Phase.replying;
    });
    final line = reply.text ?? reply.modelWord;
    _speaking = _voice.say(
      url: reply.ttsUrl,
      fallbackText: line,
      language: _ttsLanguage(line),
      slow: _preReader,
    );
    await _speaking;
  }

  Future<void> _handleResume() async {
    // Let Gilli finish the sentence before the video comes back, but never
    // hold the video hostage to a TTS engine that forgets to say "done".
    await _speaking.timeout(const Duration(seconds: 8), onTimeout: () {});
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
    final line =
        end.summaryText ??
        (_preReader
            ? 'All done! Shall we watch one more?'
            : 'You watched a whole video! Want another?');
    setState(() {
      _ask = null;
      _reply = null;
      _endLine = line;
      _gesture = Gesture.cheer;
      _gestureTick++;
      _phase = _Phase.ended;
    });
    await _voice.say(
      url: end.summaryTtsUrl,
      fallbackText: line,
      language: _ttsLanguage(line),
      slow: _preReader,
    );
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    if (mounted) Navigator.of(context).maybePop();
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

  /// True whenever the video is stopped for a question. Layout keys off this:
  /// playing = video as large as possible, Gilli small; paused = video
  /// shrinks, Gilli and the answer area grow (SPEC 6.2, 6.3).
  bool get _isPaused => switch (_phase) {
    _Phase.paused ||
    _Phase.asking ||
    _Phase.listening ||
    _Phase.answered ||
    _Phase.replying => true,
    _ => false,
  };

  /// The question strip, under the player and never on it: HeyGilli plays by
  /// YouTube's rules and those forbid overlays during playback.
  Widget _trackStrip() => Padding(
    padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
    child: ValueListenableBuilder<double>(
      valueListenable: _position,
      builder: (context, seconds, _) => QuestionTrack(
        positionS: seconds,
        durationS: widget.video.durationS,
        questionTimes: _questionTimes,
        askedCount: _asked,
      ),
    ),
  );

  Widget _player(bool rounded) => ClipRRect(
    borderRadius: BorderRadius.circular(rounded ? 20 : 0),
    child: PosterCover(
      started: _started,
      child: KeyedSubtree(
        key: _playerKey,
        child: YoutubePlayer(
          controller: _yt,
          backgroundColor: HgColors.tealDeep,
          enableFullScreenOnVerticalDrag: false,
          autoFullScreen: false,
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: HgColors.teal,
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
                        ),
                        Padding(
                          padding: const EdgeInsets.only(left: 12),
                          child: AnimatedContainer(
                            duration: anim,
                            height: videoH,
                            child: _player(true),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: _trackStrip(),
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
            final gilli = GilliWidget(
              size: _stage.gilli,
              gesture: _gesture,
              gestureTick: _gestureTick,
              talking: voice.speaking,
              listening: _ears.listening,
            );
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
        return const SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(
            strokeWidth: 3,
            color: HgColors.mango,
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
                style: HgText.body(color: HgColors.sky),
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
                style: HgText.body(size: 18, color: HgColors.sky),
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
          style: HgText.body(size: 18, color: HgColors.sky),
        ),
      );
    }
    // A child who missed the question had nothing to do about it: the window
    // ran out, Gilli said "no worries" and the video started again, which reads
    // to a child as being told their answer did not matter. Offered for as long
    // as they may still answer, and it goes away once they have used their one
    // (SPEC 7.4) — a button that does nothing is worse than no button.
    if (reply == null && _phase == _Phase.listening && _repeatsLeft > 0) {
      children.add(
        _SayItAgainButton(
          showText: showText,
          onPressed: _repeatPending || _answered ? null : _onRepeat,
        ),
      );
    }
    if (showText && _errorText != null) {
      children.add(
        Text(_errorText!, style: HgText.body(size: 13, color: HgColors.coral)),
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
  const _TopBar({required this.title, required this.onHome});
  final String? title;
  final VoidCallback onHome;

  @override
  Widget build(BuildContext context) {
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
            color: HgColors.cream,
            tooltip: 'Home',
          ),
          if (title != null)
            Expanded(
              child: Text(
                title!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: HgText.body(size: 16, color: HgColors.sky),
              ),
            ),
        ],
      ),
    );
  }
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
  });
  final String? title;
  final VoidCallback onHome;
  final Widget gilli;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        spacing: 12,
        children: [
          IconButton(
            onPressed: onHome,
            icon: const Icon(
              Icons.arrow_back_rounded,
              color: HgColors.cream,
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
                style: HgText.body(size: 16, color: HgColors.sky),
              ),
            ),
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
    if (!showText) {
      return SizedBox(
        width: 76,
        height: 76,
        child: IconButton.filled(
          onPressed: onPressed,
          style: IconButton.styleFrom(
            backgroundColor: HgColors.tealDeep,
            foregroundColor: HgColors.cream,
            disabledBackgroundColor: HgColors.tealDeep,
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
          style: HgText.body(size: 17, color: HgColors.cream),
        ),
        style: OutlinedButton.styleFrom(
          foregroundColor: HgColors.cream,
          side: const BorderSide(color: HgColors.sky, width: 2),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(26),
          ),
        ),
      ),
    );
  }
}

/// Whether the embed has played a frame yet, given what it has just reported.
///
/// Latching, and that is the point: it goes true on the first `playing` and
/// stays true. A plain `state == playing` would put the cover back over every
/// pause — and Gilli pauses this player several times a video.
bool hasStarted(bool wasStarted, PlayerState state) =>
    wasStarted || state == PlayerState.playing;

/// Hides YouTube's poster — the screen the embed shows before it plays.
///
/// The poster carries the title, the channel, a share button and "Watch on
/// YouTube", and no player parameter turns any of it off. `pointerEvents:
/// none` is what keeps the *pause* overlay away, because that one only appears
/// in answer to a pointer; the poster needs no pointer, it is simply where the
/// player starts.
///
/// So this covers it, and covers nothing else. It lifts on the first frame and
/// never returns, which means it is never over playing video — not the video,
/// not an ad, and not YouTube's branding on either.
///
/// What it deliberately leaves alone: YouTube flashes the same title, logo and
/// "More videos" for about three seconds at the *start of every play*,
/// including each resume after Gilli's questions. No parameter stops that
/// either, and the only thing that would is a cover over playing video —
/// which is the line SPEC §5.5 and YouTube's terms both draw, and worth more
/// than three seconds of a logo.
class PosterCover extends StatelessWidget {
  const PosterCover({super.key, required this.started, required this.child});

  final ValueListenable<bool> started;
  final Widget child;

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      child,
      ValueListenableBuilder<bool>(
        valueListenable: started,
        // Once it has faded the spinner would otherwise go on ticking — and
        // repainting — under a transparent layer for the whole video.
        builder: (context, isStarted, _) => TickerMode(
          enabled: !isStarted,
          child: IgnorePointer(
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 200),
              opacity: isStarted ? 0 : 1,
              // Deliberately not a spinner on black: this is the first second of
              // a video the child chose, so it should read as "coming", not as
              // "something is wrong".
              child: const ColoredBox(
                color: HgColors.tealDeep,
                child: Center(
                  child: SizedBox(
                    width: 34,
                    height: 34,
                    child: CircularProgressIndicator(
                      strokeWidth: 3,
                      valueColor: AlwaysStoppedAnimation(HgColors.mango),
                      backgroundColor: HgColors.teal,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ],
  );
}
