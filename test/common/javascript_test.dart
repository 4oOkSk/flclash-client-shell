import 'package:fl_clash/common/javascript.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'script evaluator gets an isolated snapshot without changing caller data',
    () async {
      final config = <String, dynamic>{'rules': <String>[]};
      final result = await handleEvaluate(
        'main',
        config,
        evaluator: (script, snapshot) async {
          expect(script, 'main');
          expect(snapshot['proxy-providers'], isEmpty);
          (snapshot['rules'] as List).add('MATCH,REJECT');
          return snapshot;
        },
      );
      expect(result['rules'], ['MATCH,REJECT']);
      expect(config, {'rules': <String>[]});
    },
  );

  test(
    'executor failures propagate instead of applying a no-script result',
    () async {
      await expectLater(
        handleEvaluate(
          'bad',
          {},
          evaluator: (_, _) async {
            throw StateError('interrupted');
          },
        ),
        throwsStateError,
      );
    },
  );
}
