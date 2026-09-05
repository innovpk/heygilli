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
