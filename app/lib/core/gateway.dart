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
  Future<ImportResult> importChannels(String kidId, List<String> channelIds);

  /// `POST /import/takeout`, multipart. The only route to a child's YouTube
  /// Kids subscriptions: no API exposes them. Only the subscription CSVs in
  /// the zip are read; watch and search history are ignored.
  Future<TakeoutPreview> importTakeout(File zip);

  /// `POST /channels/reviews`. Returns whatever is cached now and lists the
  /// rest in `pending`; the caller polls with the ids still outstanding.
  Future<ChannelReviewBatch> channelReviews(List<String> channelIds);

  /// `GET /channels/{id}/review`. `refresh: true` forces a re-review.
  Future<ChannelReview> channelReview(String channelId, {bool refresh});

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

  Future<SessionStart> startSession({
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

  Future<List<ParentPrompt>> inbox();
  Future<void> decide(String promptId, String decision);
}
