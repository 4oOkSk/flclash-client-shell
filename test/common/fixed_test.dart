import 'package:fl_clash/common/fixed.dart';
import 'package:test/test.dart';

void main() {
  group('FixedList', () {
    test('respects maxLength on creation', () {
      final list = FixedList(3, list: [1, 2, 3, 4, 5]);
      expect(list.length, 3);
      expect(list.list, [3, 4, 5]);
    });

    test('truncates when adding beyond maxLength', () {
      final list = FixedList(3);
      list.add(1);
      list.add(2);
      list.add(3);
      list.add(4);
      expect(list.list, [2, 3, 4]);
    });

    test('addOrReplace moves an updated item to the newest position', () {
      final list = FixedList(3, list: ['one:active', 'two:active']);

      list.addOrReplace('one:closed', (item) => item.startsWith('one:'));

      expect(list.list, ['two:active', 'one:closed']);
    });

    test('addOrReplace remains bounded and unique under high churn', () {
      final list = FixedList<String>(30);

      for (var index = 0; index < 1000; index++) {
        final id = index % 50;
        list.addOrReplace('$id:$index', (item) => item.startsWith('$id:'));
      }

      expect(list.length, 30);
      expect(
        list.list.map((item) => item.split(':').first).toSet(),
        hasLength(30),
      );
      expect(list.list.last, '49:999');
    });

    test('clear empties the list', () {
      final list = FixedList(3, list: [1, 2, 3]);
      list.clear();
      expect(list.length, 0);
      expect(list.list, isEmpty);
    });

    test('copyWith creates independent copy', () {
      final original = FixedList(3, list: [1, 2, 3]);
      final copy = original.copyWith();
      copy.add(4);
      expect(original.list, [1, 2, 3]);
      expect(copy.list, [2, 3, 4]);
    });

    test('operator [] returns correct element', () {
      final list = FixedList(5, list: [10, 20, 30]);
      expect(list[0], 10);
      expect(list[2], 30);
    });

    test('list getter returns unmodifiable view', () {
      final list = FixedList(3, list: [1, 2, 3]);
      final view = list.list;
      expect(() => view.add(4), throwsA(isA<UnsupportedError>()));
    });
  });
}
