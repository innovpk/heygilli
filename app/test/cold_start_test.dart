import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heygilli/core/api_client.dart';
import 'package:http/http.dart' as http;

/// The gateway sleeps when nobody has used it, and the first request wakes it.
///
/// A measured cold start was 11 s against an 8 s probe, so the first person to
/// open the app — exactly the person being shown it — got "Gilli can't
/// connect" while the gateway was busy coming up.
///
/// Run on a fake clock: the point is which durations are tolerated, and waiting
/// them out for real would put a minute into every test run.
void main() {
  bool? probe(Duration serverTakes) {
    bool? answer;
    fakeAsync((async) {
      ApiClient(
        baseUrl: 'http://gateway.test',
        client: _SlowClient(serverTakes),
      ).reachable().then((r) => answer = r);
      async.elapse(const Duration(minutes: 5));
    });
    return answer;
  }

  test('a gateway that is still waking up is waited for, not written off', () {
    expect(probe(const Duration(seconds: 11)), isTrue);
  });

  test('the old eight-second budget is what this has to beat', () {
    expect(probe(const Duration(seconds: 30)), isTrue);
  });

  test('a gateway that is genuinely down is still given up on', () {
    // The wait must not become forever: a dead end the parent can retry beats
    // a spinner that never resolves.
    expect(probe(const Duration(minutes: 2)), isFalse);
  });
}

/// Answers 200, but only after [delay] on whatever clock is running.
class _SlowClient extends http.BaseClient {
  _SlowClient(this.delay);

  final Duration delay;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    await Future<void>.delayed(delay);
    return http.StreamedResponse(const Stream.empty(), 200);
  }
}
