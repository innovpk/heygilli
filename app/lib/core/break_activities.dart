/// The things a child might do while the screen is paused, as the setup
/// question offers them. Mirrors `BREAK_ACTIVITIES` in the gateway's
/// starter_channels.py, which is where the list is decided.
const breakActivityLabels = {
  'stretch': 'Have a stretch',
  'jump': 'Star jumps',
  'water': 'Get a drink of water',
  'window': 'Look out of the window',
  'draw': 'Draw something',
  'tidy': 'Tidy one thing',
  'walk': 'Walk about',
  'pet': 'Say hello to a pet',
};

/// A picture for each, from the icons the app already ships: the parent picks
/// from them during setup, and a pre-reader, who reads nothing on the break
/// screen, is shown the one Gilli is asking for.
const breakActivityIcons = {
  'stretch': 'tree',
  'jump': 'star',
  'water': 'water',
  'window': 'sun',
  'draw': 'triangle',
  'tidy': 'house',
  'walk': 'leaf',
  'pet': 'cat',
};
