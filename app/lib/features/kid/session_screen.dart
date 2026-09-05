import 'dart:async';

import 'dart:math' as math;

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
import 'gilli_widget.dart';
import 'mic_button.dart';
import 'pick_cards.dart';

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
    params: const YoutubePlayerParams(
      showFullscreenButton: false,
      strictRelatedVideos: true,
      enableCaption: false,
    ),
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
  String? _errorText;

  AskMessage? _ask;
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
    _posSub = _yt.videoStateStream.listen(
      (s) => _positionS = s.position.inMilliseconds / 1000,
    );
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
      final start = await gateway.startSession(
        kidId: _kid.id,
        videoId: widget.video.id,
        device: BuildConfig.device,
      );
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
    if (!mounted) return;
    debugPrint('[ws] ${m.runtimeType}');
    switch (m) {
      case ReadyMessage(:final language):
        setState(() {
          _language = language;
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
    setState(() {
      _ask = ask;
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

  Widget _player(bool rounded) => ClipRRect(
    borderRadius: BorderRadius.circular(rounded ? 20 : 0),
    child: KeyedSubtree(
      key: _playerKey,
      child: YoutubePlayer(
        controller: _yt,
        backgroundColor: HgColors.tealDeep,
        enableFullScreenOnVerticalDrag: false,
        autoFullScreen: false,
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
