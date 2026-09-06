import 'dart:io';

import 'analytics.dart';
import 'models.dart';
import 'session_socket.dart';

/// Everything the client needs from the backend, in one interface.
///
/// [ApiClient] talks to the Python gateway; [FakeGateway] is the built-in
/// demo. Screens never know which one they have.
abstract class Gateway {
  bool get isDemo;

  Future<void> signInDev(String name);
  bool get signedIn;

  /// `POST /auth/google`. Takes the **server auth code** from the device; the
  /// gateway exchanges it and keeps the refresh token (PROTOCOL). The device
  /// never stores or sends a refresh token.
  Future<Session> signInWithGoogle(String serverAuthCode);

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
  });

  /// `POST /import/takeout`, multipart. The only route to a child's YouTube
  /// Kids subscriptions: no API exposes them. Only the subscription CSVs in
  /// the zip are read; watch and search history are ignored.
  ///
  /// [includeHistory] is off unless the parent ticked the box for this one
  /// import. With it, the zip also carries `watch-history.html`, the server
  /// counts it and then discards the file and every video title in it
  /// (PROTOCOL "Watch history: opt-in, aggregate, discarded"). Search history
  /// is never included, with or without it.
  Future<TakeoutPreview> importTakeout(File zip, {bool includeHistory});

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

  Future<List<Channel>> channels(String kidId);
  Future<Channel> addChannel(String kidId, String url);

  Future<List<HomeRow>> home(String kidId);

  /// `GET /kids/{id}/state`. Checked before anything is offered to watch, and
  /// again when the kid screen is reopened, so a break survives the app being
  /// killed mid-break.
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
  Future<List<PolicyQuestion>> policyQuestions(String kidId);

  Future<List<ParentPrompt>> inbox();
  Future<void> decide(String promptId, String decision);
}
