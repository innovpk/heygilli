import 'dart:typed_data';

import 'analytics.dart';
import 'models.dart';
import 'play.dart';
import 'session_socket.dart';

/// Everything the client needs from the backend, in one interface.
///
/// [ApiClient] talks to the Python gateway; [FakeGateway] is the built-in
/// demo. Screens never know which one they have.
abstract class Gateway {
  bool get isDemo;

  Future<void> signInDev(String name);
  bool get signedIn;

  /// Drops the household token this client is holding, so the next call is
  /// unauthenticated and the app is back at sign-in.
  void forgetToken();

  /// `POST /auth/google`. Takes the **server auth code** from the device; the
  /// gateway exchanges it and keeps the refresh token (PROTOCOL). The device
  /// never stores or sends a refresh token.
  Future<Session> signInWithGoogle(String serverAuthCode, {String redirectUri});

  /// `GET /me/youtube`. `linked: false` is a normal state, not an error.
  Future<YouTubeStatus> youtubeStatus();

  /// `GET /me/youtube/subscriptions`: the parent's own subscriptions, each
  /// marked with the kids it is already approved for.
  Future<SubscriptionList> youtubeSubscriptions();

  /// `POST /kids/{kid_id}/channels/import`. Approves several channels for one
  /// kid at once. It approves channels, never videos: the Curator still
  /// screens every upload.
  /// `POST /kids/{id}/channels/import`. [profile] names the Takeout profile
  /// these channels came from, when they came from one.
  ///
  /// It is the parent saying "this profile is this child", and it is the only
  /// moment the server can attach that profile's watch-history aggregate to a
  /// kid: Takeout carries no age and no identity of its own. Omitting it on a
  /// Takeout import leaves the aggregate stranded under a profile name.
  Future<ImportResult> importChannels(
    String kidId,
    List<String> channelIds, {
    String profile,

    /// What the parent said this child likes, when these came off the
    /// starter-channel screen. Recorded on the child so the screening knows
    /// what was asked for: a channel's topics are the channel's, not each
    /// upload's, and a science channel posting quote compilations had nothing
    /// to notice it with.
    List<String> topics,
  });

  /// `POST /import/takeout`, multipart. The only route to a child's YouTube
  /// Kids subscriptions: no API exposes them. Only the subscription CSVs in
  /// the zip are read; watch and search history are ignored.
  ///
  /// [zipBytes] is the slimmed zip, not the export the parent picked: the
  /// original is stripped on the device first (`slimTakeout`), so what
  /// travels is a few kilobytes of channel lists rather than the family's
  /// whole export. [filename] is only what the upload is labelled.
  ///
  /// [includeHistory] is off unless the parent ticked the box for this one
  /// import. With it, the zip also carries `watch-history.html`, the server
  /// counts it and then discards the file and every video title in it
  /// (PROTOCOL "Watch history: opt-in, aggregate, discarded"). Search history
  /// is never included, with or without it.
  Future<TakeoutPreview> importTakeout(
    Uint8List zipBytes,
    String filename, {
    bool includeHistory,
  });

  /// `GET /kids/{id}/history`. Null when this household never opted in, which
  /// is the default and answers 404 rather than an empty insight.
  Future<HistoryInsight?> history(String kidId);

  /// `DELETE /kids/{id}/history`. One call, and the aggregate is gone.
  Future<bool> deleteHistory(String kidId);

  /// `POST /channels/reviews`. Returns whatever is cached now and lists the
  /// rest in `pending`; the caller polls with the ids still outstanding.
  Future<ChannelReviewBatch> channelReviews(List<String> channelIds);

  /// `GET /channels/{id}/review`. `refresh: true` forces a re-review.
  Future<ChannelReview> channelReview(String channelId, {bool refresh});

  /// `POST /channels/drift/check`: which of these channels are no longer what
  /// they were when the parent approved them. Re-review is rate-limited to
  /// once a week per channel server-side, so this is cheap to call on open.
  ///
  /// Information only. HeyGilli never removes a channel on its own; the drift
  /// says what changed and the parent decides (PROTOCOL "Channel drift").
  Future<DriftCheck> checkDrift(List<String> channelIds);

  /// `DELETE /kids/{kid_id}/channels/{channel_id}`. Takes one channel off one
  /// kid immediately; the review itself is cached per channel and untouched.
  Future<void> removeChannel(String kidId, String channelId);

  Future<List<Kid>> kids();
  Future<Kid> createKid({
    required String nickname,
    required int age,
    required List<String> languages,
  });

  /// `PATCH /kids/{id}`. Correct a child's nickname, age or languages.
  ///
  /// Changing the age re-derives the band on the server, which is the point of
  /// the edit: the band decides what the Curator screens for and whether the
  /// child is read to or shown text.
  Future<Kid> editKid(
    String kidId, {
    String? nickname,
    int? age,
    List<String>? languages,
    String? avatar,
  });

  /// `GET /starter-channels`. Channels to offer a household that has none.
  ///
  /// The alternative was asking a parent who has just arrived to request a
  /// Takeout export from Google and wait for it. Suggestions only: nothing is
  /// approved until the parent says so.
  Future<StarterChannels> starterChannels({
    required String band,
    List<String> topics,
  });

  /// `GET /channels/search`. Channels on YouTube matching what the parent
  /// typed.
  ///
  /// A parent searching is not a child searching: what comes back is a
  /// suggestion they then approve, and every upload from an approved channel
  /// is still screened. Throws when the search cannot run at all — a daily
  /// limit or a key that may not search — because a parent would retype their
  /// query for ever against an empty list.
  Future<List<StarterChannel>> searchChannels(String query);

  /// `GET /kids/{id}/prompts`. The questions written for this child's band,
  /// each with whether they are asked it.
  Future<List<KidPrompt>> prompts(String kidId);

  /// `PUT /kids/{id}/prompts`. Sends the ids the parent turned OFF, whole:
  /// unticking the last one has to be distinguishable from sending nothing.
  Future<List<KidPrompt>> savePrompts(String kidId, List<String> disabled);

  /// `DELETE /kids/{id}`. This child and everything about them.
  ///
  /// Irreversible, and the server asks for their nickname back before it will
  /// do it — a stray call cannot take a child's history with it.
  Future<void> deleteKid(String kidId, String confirmNickname);

  /// `DELETE /me`. This household and everything in it.
  Future<void> deleteHousehold();

  Future<List<Channel>> channels(String kidId);
  Future<Channel> addChannel(String kidId, String url);

  /// `POST /kids/{id}/curate`. Screen this kid's approved channels again.
  ///
  /// Curation used to run only when channels were imported, so a run that came
  /// back with nothing — the server could not read a transcript, the model was
  /// briefly down — left the child's home empty with nothing a parent could
  /// press. Returns as soon as the run is queued, not when it finishes.
  Future<void> curateNow(String kidId);

  /// `GET /kids/{id}/home`. [query] filters the child's *approved* videos
  /// and nothing else; the gateway ignores it unless the parent enabled
  /// search for this kid.
  Future<List<HomeRow>> home(String kidId, {String query});

  /// `GET /kids/{id}/state`. Checked before anything is offered to watch, and
  /// again when the kid screen is reopened, so a break survives the app being
  /// killed mid-break.
  /// `POST /tts`. A url for a line this app composed itself, so a screen
  /// Gilli speaks sounds like Gilli rather than like the device.
  ///
  /// Returns "" when the server has no voice to give, which is not a failure:
  /// the caller speaks the words on-device, exactly as it did before.
  Future<String> speechUrl(String text, {bool slow});

  Future<WatchState> watchState(String kidId);

  /// `PATCH /kids/{id}/limits`. Omitted fields are left as they are.
  /// 0 means "no limit" for daily and max-video minutes, and "never" for the
  /// break interval (PROTOCOL).
  Future<Kid> updateLimits(
    String kidId, {
    int? dailyMinutes,
    int? breakAfterMinutes,
    int? breakMinutes,
    int? maxVideoMinutes,
    bool? breakIsFirm,
    bool? searchEnabled,
  });

  /// `PUT /kids/{id}/break-messages`: replaces the lines Gilli reads out at
  /// break time with exactly what the parent saved. An empty list is a real
  /// setting — a quiet break — not a missing one.
  Future<Kid> saveBreakMessages(String kidId, List<BreakMessage> messages);

  /// `POST /kids/{id}/break-messages/suggest`: drafts for the parent to read,
  /// edit and save, or throw away. Nothing here has reached a child, and the
  /// only route to one is [saveBreakMessages].
  Future<List<BreakMessage>> suggestBreakMessages(String kidId);

  /// `POST /kids/{id}/break/ack`: the child says they did the task. Records
  /// it and nothing more; the break still ends on its own timer.
  Future<BreakPeriod> ackBreak(String kidId);

  /// `POST /kids/{id}/break/override`: a parent ends a break early, behind
  /// the PIN.
  Future<void> overrideBreak(String kidId);

  /// `POST /sessions`. Answers 409 with the active break when one is running,
  /// which is a [SessionBlockedByBreak], not an error.
  Future<SessionStartResult> startSession({
    required String kidId,
    required String videoId,
    required String device,
  });
  Future<SessionSocket> openSession(String sessionId);
  Future<void> endSession(String sessionId);

  Future<Digest> digest(String kidId, String date);
  Future<Digest> runDigest(String kidId);

  /// Rolling window for the parent Progress screen. `days` is 7-90.
  Future<Analytics> analytics(String kidId, {int days = 14});

  /// `GET /kids/{id}/revisits`: the shaky concepts, and which of them a later
  /// session has quietly come back to.
  ///
  /// Parent-side only. The child is never told a question is a revisit, so
  /// nothing this returns may reach a kid screen (PROTOCOL "Revisiting a
  /// shaky concept").
  Future<List<RevisitConcept>> revisits(String kidId);

  /// `GET /kids/{id}/words`: the words Gilli has offered this child in their
  /// other language, and which have come back (PROTOCOL "Bilingual word
  /// seeding"). Empty for a household with one language, which is normal.
  Future<List<WordSeed>> words(String kidId);

  /// `GET /kids/{id}/policy`. An empty policy is a real answer: the Curator
  /// then screens on age-band defaults alone.
  Future<Policy> policy(String kidId);

  /// `PUT /kids/{id}/policy`. Replaces the answers with exactly what the
  /// parent chose. Only answered questions are sent — an unanswered one
  /// carries no weight (PROTOCOL) and must not arrive as a silent "fine".
  Future<Policy> savePolicy(
    String kidId, {
    required List<PolicyAnswer> answers,
    required String notes,
  });

  /// `POST /kids/{id}/policy/questions`: questions worth asking *this*
  /// household, drawn from what this child already watches. Proposals only —
  /// nothing here changes screening until the parent answers and saves.
  Future<PolicyQuestions> policyQuestions(String kidId);

  Future<List<ParentPrompt>> inbox();
  Future<void> decide(String promptId, String decision);

  /// `POST /kids/{id}/preferences`: what this child likes. The server picks
  /// the channels to look in and starts screening their uploads.
  ///
  /// The parent is not asked to vouch for a channel's entire future output
  /// from a one-line blurb before seeing anything it makes — which they had no
  /// way to check, and which was wrong twice in a list of twenty-six.
  Future<int> setPreferences(
    String kidId,
    List<String> topics, {
    List<String> breakActivities,
  });

  /// `POST /kids/{id}/videos/{videoId}/ask`: a question about one video,
  /// answered from what is actually known about it.
  ///
  /// Decides nothing. The screening writes a few sentences and then the parent
  /// decides, which works when their question is the one it happened to answer
  /// and not otherwise. [history] is the earlier turns of this conversation,
  /// oldest first — held here rather than on the server, so no record of what a
  /// parent was worried about is kept anywhere.
  Future<VideoAnswer> askAboutVideo(
    String kidId,
    String videoId,
    String question, {
    List<(String, String)> history,
  });

  /// `GET /kids/{id}/videos/{v}/questions`: what this parent has added.
  Future<List<ParentQuestion>> parentQuestions(String kidId, String videoId);

  /// `POST /kids/{id}/videos/{v}/questions`: one question of the parent's own.
  ///
  /// Asked as written. Nothing rewrites it and no model sees it before the
  /// child does — a parent who typed a sentence for their own child should get
  /// that sentence back, not an improved one.
  Future<ParentQuestion> addParentQuestion(
    String kidId,
    String videoId,
    String text, {
    int? tSec,
    bool yesNo,
  });

  /// `DELETE /kids/{id}/videos/{v}/questions/{q}`.
  Future<void> removeParentQuestion(
    String kidId,
    String videoId,
    String questionId,
  );

  /// `GET /kids/{id}/review`: everything screened for this child, with what
  /// the Curator made of each one and how far the run has got.
  Future<ReviewQueue> reviewQueue(String kidId);

  /// What Gilli makes of a video or channel link, read against this child's
  /// answers. A few a day per household; changes nothing the child can see.
  Future<LinkCheck> checkLink(String kidId, String url);

  /// `POST /kids/{id}/play`: the next round of one of Gilli's games, decided
  /// by the Playmate agent from how the rounds so far went. 409 during a
  /// break or once the day is spent, like watching.
  Future<PlayTurn> playTurn(
    String kidId,
    PlayGame game,
    List<PlayRound> rounds,
  );

  /// `POST /kids/{id}/review`: the parent's answers, in one go. Whole
  /// channels are approved at a time, so one call per video would be a screen
  /// full of spinners over a gateway that may be asleep.
  Future<void> reviewDecide(
    String kidId, {
    List<String> approve,
    List<String> hide,
  });
}
