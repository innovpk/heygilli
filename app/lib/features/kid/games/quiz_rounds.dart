import 'dart:math';

import '../../../core/icon_library.dart';
import '../../../core/models.dart';
import '../../../core/play.dart';

/// One card in a round: a picture from the icon library, or words.
class QuizCard {
  const QuizCard({this.iconId, this.text, this.label})
    : assert(iconId != null || text != null);

  /// A picture, when the card is one.
  final String? iconId;

  /// The words on the card, when it is words: a letter, a number, an answer.
  final String? text;

  /// A caption under a picture, for a child who reads.
  final String? label;

  bool get isPicture => iconId != null;
}

/// One round of a card game: what Gilli asks, what is on the table, and
/// which card is the one.
///
/// Built on the device from the level and the band, so a game never waits
/// on the gateway for a question. [prompt] is what a reader sees; [speak]
/// is what Gilli says, which spells out what the screen shows a pre-reader
/// nothing of. [showing] is a picture or a count above the cards, for
/// "how many ducks?" and the guessing clue.
class QuizRound {
  const QuizRound({
    required this.prompt,
    required this.speak,
    required this.cards,
    required this.correct,
    this.showing = const [],
    this.columns,
  });

  final String prompt;
  final String speak;
  final List<QuizCard> cards;
  final int correct;

  /// Icon ids drawn above the cards, in a row.
  final List<String> showing;

  /// Cards per row, when the game wants a grid rather than a strip.
  final int? columns;
}

/// The thirteen animals the icon library has, with a clue at three levels
/// of difficulty: what it says, what it looks like, and something a child of
/// ten might know. Nothing scary, nothing about eating anyone.
class _Animal {
  const _Animal(this.id, this.sound, this.looks, this.fact);
  final String id;
  final String sound;
  final String looks;
  final String fact;
}

const _animals = [
  _Animal(
    'icon_giraffe',
    'I am very tall and I eat leaves from the tops of trees.',
    'I have a very long neck and brown patches.',
    'My tongue is purple and I sleep standing up.',
  ),
  _Animal(
    'icon_lion',
    'I say ROAR! I have a big fluffy mane.',
    'I am a big cat with a mane, and I live in a pride.',
    'I am called the king of the jungle, but I live on the grassland.',
  ),
  _Animal(
    'icon_elephant',
    'I am very big and I have a long trunk.',
    'I have huge ears, a long trunk and two tusks.',
    'I am the biggest animal on land and I never forget a face.',
  ),
  _Animal(
    'icon_monkey',
    'I say ooh ooh aah aah and I love bananas.',
    'I swing from tree to tree with my long tail.',
    'I use my tail like an extra hand when I climb.',
  ),
  _Animal(
    'icon_fish',
    'I swim in the water. Blub blub!',
    'I have fins and scales and I breathe under water.',
    'I breathe with gills instead of lungs.',
  ),
  _Animal(
    'icon_bird',
    'I say tweet tweet and I can fly.',
    'I have feathers and wings and I lay eggs in a nest.',
    'I have hollow bones so I am light enough to fly.',
  ),
  _Animal(
    'icon_cat',
    'I say meow and I purr when I am happy.',
    'I have whiskers and I love to nap in the sun.',
    'I can see in the dark much better than you can.',
  ),
  _Animal(
    'icon_dog',
    'I say woof woof and I wag my tail.',
    'I am a best friend who loves walks and fetching sticks.',
    'My nose is so good I can smell things from far away.',
  ),
  _Animal(
    'icon_cow',
    'I say moo and I give milk.',
    'I have horns and spots and I chew grass all day.',
    'I have four parts to my stomach to digest grass.',
  ),
  _Animal(
    'icon_duck',
    'I say quack quack and I swim on the pond.',
    'I have a flat orange beak and webbed feet.',
    'My feathers are waterproof, so water rolls right off.',
  ),
  _Animal(
    'icon_frog',
    'I say ribbit and I hop hop hop.',
    'I am green, I hop, and I start life as a tadpole.',
    'I drink water through my skin instead of my mouth.',
  ),
  _Animal(
    'icon_butterfly',
    'I have pretty wings and I flutter from flower to flower.',
    'I was a caterpillar before I grew my colourful wings.',
    'I taste with my feet when I land on a flower.',
  ),
  _Animal(
    'icon_squirrel',
    'I have a big bushy tail and I love nuts. Just like Gilli!',
    'I climb trees and bury nuts to find in winter.',
    'I can forget where I buried my nuts, and trees grow from them.',
  ),
];

const _letters = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';

List<T> _shuffled<T>(List<T> xs, Random rng) => List.of(xs)..shuffle(rng);

/// [n] distinct picks from [xs], [must] among them.
List<T> _pickWith<T>(List<T> xs, int n, T must, Random rng) {
  final rest = _shuffled(xs.where((x) => x != must).toList(), rng);
  return _shuffled([must, ...rest.take(n - 1)], rng);
}

/// The word (English label) of an icon, lower case, for the letter game.
String _word(IconLibrary icons, String id) =>
    (icons.byId(id)?.en ?? id.replaceFirst('icon_', '')).toLowerCase();

// ---------------------------------------------------------------- letters

QuizRound abcRound(int level, AgeBand band, Random rng, IconLibrary icons) {
  switch (band) {
    case AgeBand.b4to6:
      // Find the big letter. Three to choose from, four once it is easy.
      final n = level >= 3 ? 4 : 3;
      final target = _letters[rng.nextInt(26)];
      final cards = _pickWith(_letters.split(''), n, target, rng);
      return QuizRound(
        prompt: 'Find the letter $target',
        speak: 'Find the letter $target!',
        cards: [for (final c in cards) QuizCard(text: c)],
        correct: cards.indexOf(target),
      );
    case AgeBand.b7to8:
      if (level <= 2) {
        // Small letters, which look less like their big ones than a
        // seven-year-old is given credit for.
        final target = _letters[rng.nextInt(26)];
        final cards = _pickWith(_letters.split(''), 4, target, rng);
        return QuizRound(
          prompt: 'Find the small letter ${target.toLowerCase()}',
          speak: 'Find the small letter $target!',
          cards: [for (final c in cards) QuizCard(text: c.toLowerCase())],
          correct: cards.indexOf(target),
        );
      }
      return _neighbourRound(rng, step: 1, cards: 4);
    case AgeBand.b9to11:
      if (level <= 2) {
        // Which word starts with the letter: pictures with their names.
        final ids = icons.all.map((e) => e.id).toList();
        final pool = _shuffled(ids, rng);
        final targetId = pool.first;
        final first = _word(icons, targetId)[0];
        final others = pool
            .skip(1)
            .where((id) => _word(icons, id)[0] != first)
            .take(3)
            .toList();
        final cards = _shuffled([targetId, ...others], rng);
        return QuizRound(
          prompt: 'Which one starts with ${first.toUpperCase()}?',
          speak: 'Which of these starts with ${first.toUpperCase()}?',
          cards: [
            for (final id in cards)
              QuizCard(iconId: id, label: _word(icons, id)),
          ],
          correct: cards.indexOf(targetId),
        );
      }
      return _neighbourRound(rng, step: level >= 4 ? 2 : 1, cards: 4);
  }
}

/// "Which letter comes after M?" and, further on, two letters along or
/// before rather than after.
QuizRound _neighbourRound(Random rng, {required int step, required int cards}) {
  final after = rng.nextBool();
  final base = after ? rng.nextInt(26 - step) : step + rng.nextInt(26 - step);
  final target = _letters[after ? base + step : base - step];
  final from = _letters[base];
  final howFar = step == 1 ? '' : ' $step letters';
  final way = after ? 'after' : 'before';
  final options = _pickWith(_letters.split(''), cards, target, rng);
  return QuizRound(
    prompt: 'Which letter comes$howFar $way $from?',
    speak: 'Which letter comes$howFar $way $from?',
    cards: [for (final c in options) QuizCard(text: c)],
    correct: options.indexOf(target),
  );
}

// ---------------------------------------------------------------- numbers

const _numberIcons = [
  'icon_one',
  'icon_two',
  'icon_three',
  'icon_four',
  'icon_five',
];

QuizRound sumsRound(int level, AgeBand band, Random rng, IconLibrary icons) {
  switch (band) {
    case AgeBand.b4to6:
      // How many? Count the pictures, tap the number. Up to three to begin
      // with, up to five once counting is going well.
      final most = level >= 3 ? 5 : 3;
      final count = 1 + rng.nextInt(most);
      final animal = _animals[rng.nextInt(_animals.length)].id;
      final name = _word(icons, animal);
      final plural = count == 1 ? name : '${name}s';
      final numbers = _pickWith(
        [for (var i = 1; i <= most; i++) i],
        3,
        count,
        rng,
      );
      return QuizRound(
        prompt: 'How many $plural?',
        speak: 'How many $plural can you see?',
        showing: List.filled(count, animal),
        cards: [for (final n in numbers) QuizCard(iconId: _numberIcons[n - 1])],
        correct: numbers.indexOf(count),
      );
    case AgeBand.b7to8:
      // Adding and taking away inside ten, then twenty; times at the top.
      if (level >= 5) return _timesRound(rng, tables: const [2, 5, 10]);
      final top = level <= 2 ? 10 : 20;
      return _plusMinusRound(rng, top: top);
    case AgeBand.b9to11:
      if (level <= 1) return _plusMinusRound(rng, top: 100);
      if (level <= 3) {
        return _timesRound(rng, tables: [for (var t = 2; t <= 12; t++) t]);
      }
      return rng.nextBool()
          ? _divideRound(rng)
          : _timesRound(rng, tables: [for (var t = 6; t <= 12; t++) t]);
  }
}

/// Three answer cards around the right one: near misses, never the same.
List<int> _answers(int right, Random rng, {required int spread}) {
  final wrong = <int>{};
  var guard = 0;
  while (wrong.length < 2 && guard++ < 50) {
    final delta = (1 + rng.nextInt(spread)) * (rng.nextBool() ? 1 : -1);
    final w = right + delta;
    if (w >= 0 && w != right) wrong.add(w);
  }
  var fill = right + 1;
  while (wrong.length < 2) {
    if (fill != right) wrong.add(fill);
    fill++;
  }
  return _shuffled([right, ...wrong], rng);
}

QuizRound _sum(String shown, String spoken, int right, Random rng, int spread) {
  final options = _answers(right, rng, spread: spread);
  return QuizRound(
    prompt: shown,
    speak: spoken,
    cards: [for (final n in options) QuizCard(text: '$n')],
    correct: options.indexOf(right),
  );
}

QuizRound _plusMinusRound(Random rng, {required int top}) {
  final a = rng.nextInt(top + 1);
  final b = rng.nextInt(top + 1);
  if (rng.nextBool()) {
    final x = max(a, b);
    final y = min(a, b);
    return _sum(
      '$x − $y = ?',
      'What is $x take away $y?',
      x - y,
      rng,
      top >= 100 ? 10 : 3,
    );
  }
  final x = min(a, top - b);
  return _sum(
    '$x + $b = ?',
    'What is $x plus $b?',
    x + b,
    rng,
    top >= 100 ? 10 : 3,
  );
}

QuizRound _timesRound(Random rng, {required List<int> tables}) {
  final t = tables[rng.nextInt(tables.length)];
  final n = 1 + rng.nextInt(12);
  return _sum('$t × $n = ?', 'What is $t times $n?', t * n, rng, t);
}

QuizRound _divideRound(Random rng) {
  final d = 2 + rng.nextInt(11);
  final q = 1 + rng.nextInt(12);
  return _sum('${d * q} ÷ $d = ?', 'What is ${d * q} shared by $d?', q, rng, 2);
}

// ---------------------------------------------------------------- animals

QuizRound guessAnimalRound(
  int level,
  AgeBand band,
  Random rng,
  IconLibrary icons,
) {
  final animal = _animals[rng.nextInt(_animals.length)];
  final clue = switch (band) {
    AgeBand.b4to6 => animal.sound,
    AgeBand.b7to8 => level >= 4 ? animal.fact : animal.looks,
    AgeBand.b9to11 => level >= 3 ? animal.fact : animal.looks,
  };
  final n = band == AgeBand.b4to6 ? 3 : (level >= 3 ? 4 : 3);
  final cards = _pickWith(
    _animals.map((a) => a.id).toList(),
    n,
    animal.id,
    rng,
  );
  return QuizRound(
    prompt: '$clue Who am I?',
    speak: '$clue Who am I?',
    cards: [
      for (final id in cards) QuizCard(iconId: id, label: _word(icons, id)),
    ],
    correct: cards.indexOf(animal.id),
  );
}

QuizRound spotAnimalRound(
  int level,
  AgeBand band,
  Random rng,
  IconLibrary icons,
) {
  final animal = _animals[rng.nextInt(_animals.length)];
  final n = switch (band) {
    AgeBand.b4to6 => level >= 3 ? 6 : 4,
    AgeBand.b7to8 => level >= 4 ? 9 : 6,
    AgeBand.b9to11 => level >= 3 ? 12 : 9,
  };
  final cards = _pickWith(
    _animals.map((a) => a.id).toList(),
    n,
    animal.id,
    rng,
  );
  final name = _word(icons, animal.id);
  final urdu = icons.byId(animal.id)?.ur ?? '';
  return QuizRound(
    prompt: 'Find the $name!',
    speak: 'Find the $name!',
    cards: [for (final id in cards) QuizCard(iconId: id, label: urdu)],
    correct: cards.indexOf(animal.id),
    columns: n <= 4 ? 2 : (n <= 9 ? 3 : 4),
  );
}

/// The round builder for each card game.
QuizRound buildQuizRound(
  PlayGame game,
  int level,
  AgeBand band,
  Random rng,
  IconLibrary icons,
) => switch (game) {
  PlayGame.abc => abcRound(level, band, rng, icons),
  PlayGame.sums => sumsRound(level, band, rng, icons),
  PlayGame.guessAnimal => guessAnimalRound(level, band, rng, icons),
  PlayGame.spotAnimal => spotAnimalRound(level, band, rng, icons),
  PlayGame.findGilli ||
  PlayGame.catchGilli => throw ArgumentError('$game is not a card game'),
};
