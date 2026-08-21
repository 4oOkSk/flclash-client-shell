import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/views/proxies/private_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('private server chooser binds only to the managed server group', () {
    const groups = [
      Group(type: GroupType.Selector, name: 'GLOBAL'),
      Group(type: GroupType.Selector, name: 'Proxy'),
      Group(type: GroupType.Selector, name: privateClientManagedServerGroup),
    ];

    expect(
      findPrivateClientPrimaryGroup(groups)?.name,
      privateClientManagedServerGroup,
    );
  });

  test('private server chooser fails closed when managed group is absent', () {
    const groups = [Group(type: GroupType.Selector, name: 'GLOBAL')];
    expect(findPrivateClientPrimaryGroup(groups), isNull);
  });
}
