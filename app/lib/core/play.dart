import 'dart:math';

import 'models.dart';

/// Gilli's games, as `POST /kids/{id}/play` names them.
enum PlayGame {
  /// He hides behind one of a few trees; the child taps trees to find him.
  findGilli('find'),

  /// He pops up here and there; the child taps him before he ducks away.
  catchGilli('catch');

  const PlayGame(this.wire);
  final String wire;

  static PlayGame fromWire(String? s) =>
      PlayGame.values.where((g) => g.wire == s).firstOrNull ?? findGilli;
}

/// Rounds in one game, and times Gilli pops up in one round of "Catch".
/// The gateway decides; these are the same numbers for when it cannot.
const roundsPerGame = 5;
const popsPerRound = 5;

/// What happened in one round. The whole of what the app reports: no speech,
/// nothing typed, nothing about the child.
class PlayRound {
  const PlayRound({
    required this.round,
    this.won = false,
    this.taps = 0,
    this.caught = 0,
    this.level = 1,
  });

  final int round;
  final bool won;

  /// "Find": taps it took, the right tree included.
  final int taps;

  /// "Catch": times he was caught, out of [popsPerRound].
  final int caught;
  final int level;

  Map<String, dynamic> toJson() => {
    'round': round,
    'won': won,
    'taps': taps,
    'caught': caught,
    'level': level,
  };
}

/// The next round, or the end of the game.
///
/// The Playmate agent picks the level and Gilli's line; the gateway turns the
/// level into these numbers, clamped for the child's age band, and picks where
/// he hides.
class PlayTurn {
  const PlayTurn({
    required this.game,
    this.round = 0,
    this.done = false,
    this.level = 1,
    this.trees = 0,
    this.spot = 0,
    this.peek = false,
    this.pops = 0,
    this.showMs = 0,
    this.line = '',
    this.ttsUrl = '',
    this.roundsLeftToday = 0,
    this.decidedBy = 'rule',
  });

  factory PlayTurn.fromJson(Map<String, dynamic> j) => PlayTurn(
    game: PlayGame.fromWire(j['game'] as String?),
    round: (j['round'] as num?)?.toInt() ?? 0,
    done: j['done'] == true,
    level: (j['level'] as num?)?.toInt() ?? 1,
    trees: (j['trees'] as num?)?.toInt() ?? 0,
    spot: (j['spot'] as num?)?.toInt() ?? 0,
    peek: j['peek'] == true,
    pops: (j['pops'] as num?)?.toInt() ?? 0,
    showMs: (j['show_ms'] as num?)?.toInt() ?? 0,
    line: j['line'] as String? ?? '',
    ttsUrl: j['tts_url'] as String? ?? '',
    roundsLeftToday: (j['rounds_left_today'] as num?)?.toInt() ?? 0,
    decidedBy: j['decided_by'] as String? ?? 'rule',
  );

  /// A round worked out on the device, by the same rule the gateway falls
  /// back to. Used when the gateway is slow or out of reach: a child who
  /// tapped the last tree should not stand watching a spinner.
  factory PlayTurn.local(
    PlayGame game,
    List<PlayRound> rounds,
    AgeBand band, {
    Random? rng,
    int roundsLeftToday = 1,
  }) {
    final r = rng ?? Random();
    if (rounds.length >= roundsPerGame || roundsLeftToday <= 0) {
      return PlayTurn(
        game: game,
        done: true,
        roundsLeftToday: max(0, roundsLeftToday),
        line: roundsLeftToday <= 0
            ? 'Gilli is sleepy now. More games tomorrow!'
            : 'That was fun! Back to your videos.',
      );
    }
    final level = _ruleLevel(game, rounds);
    final lines = rounds.isEmpty
        ? (game == PlayGame.findGilli ? _findStart : _catchStart)
        : (_struggled(rounds.last, game) ? _afterMiss : _afterWin);
    final line = lines[r.nextInt(lines.length)];
    if (game == PlayGame.findGilli) {
      final trees = min(_treesByLevel[level]!, _maxTrees[band]!);
      return PlayTurn(
        game: game,
        round: rounds.length + 1,
        level: level,
        trees: trees,
        spot: r.nextInt(trees),
        peek: band == AgeBand.b4to6 || level <= 2,
        line: line,
        roundsLeftToday: roundsLeftToday - 1,
      );
    }
    return PlayTurn(
      game: game,
      round: rounds.length + 1,
      level: level,
      pops: popsPerRound,
      showMs: max(_showMsByLevel[level]!, _minShowMs[band]!),
      line: line,
      roundsLeftToday: roundsLeftToday - 1,
    );
  }

  final PlayGame game;

  /// The round about to start; 0 once the game is over.
  final int round;
  final bool done;
  final int level;
  final int trees;
  final int spot;

  /// His tail pokes out beside the right tree.
  final bool peek;
  final int pops;
  final int showMs;
  final String line;
  final String ttsUrl;
  final int roundsLeftToday;

  /// "agent" when the Playmate agent chose the level and the line.
  final String decidedBy;

  PlayTurn withTtsUrl(String url) => PlayTurn(
    game: game,
    round: round,
    done: done,
    level: level,
    trees: trees,
    spot: spot,
    peek: peek,
    pops: pops,
    showMs: showMs,
    line: line,
    ttsUrl: url,
    roundsLeftToday: roundsLeftToday,
    decidedBy: decidedBy,
  );
}

const _treesByLevel = {1: 3, 2: 4, 3: 5, 4: 6, 5: 8};
const _maxTrees = {AgeBand.b4to6: 4, AgeBand.b7to8: 6, AgeBand.b9to11: 8};
const _showMsByLevel = {1: 2200, 2: 1800, 3: 1400, 4: 1100, 5: 850};
const _minShowMs = {
  AgeBand.b4to6: 1600,
  AgeBand.b7to8: 1100,
  AgeBand.b9to11: 850,
};

const _findStart = [
  'Ready or not, I am hiding!',
  'Shh! Where did I go?',
  'I found a new tree. Find me!',
];
const _catchStart = [
  'Catch me if you can!',
  'I am quick today. Try and catch me!',
  'Here I come, zoom zoom!',
];
const _afterWin = [
  'You found me! Again, again!',
  'Got me! I will hide better now.',
  'Hee hee! You are good at this.',
];
const _afterMiss = [
  'I was so sneaky! One more go.',
  'Hee hee, I was hiding well. Try again!',
];

bool _struggled(PlayRound r, PlayGame game) =>
    game == PlayGame.findGilli ? (!r.won || r.taps >= 4) : r.caught <= 2;

bool _breezed(PlayRound r, PlayGame game) => game == PlayGame.findGilli
    ? (r.won && r.taps <= 1)
    : r.caught >= popsPerRound - 1;

int _ruleLevel(PlayGame game, List<PlayRound> rounds) {
  if (rounds.isEmpty) return 1;
  final last = rounds.last;
  var level = last.level;
  if (_breezed(last, game)) {
    level++;
  } else if (_struggled(last, game)) {
    level--;
  }
  return level.clamp(1, 5);
}
