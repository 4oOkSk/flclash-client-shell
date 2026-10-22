import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:fl_clash/database/database.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Database db;
  setUp(() => db = Database(NativeDatabase.memory()));
  tearDown(() => db.close());

  final script = Script(id: 10, label: 'one', lastUpdateTime: DateTime(2026));
  const profile = Profile(
    id: 1,
    label: 'one',
    scriptId: 10,
    autoUpdateDuration: Duration.zero,
    order: 9,
  );
  const rule = Rule(id: 20, content: 'example.com', order: 'z');
  const link = ProfileRuleLink(
    profileId: 1,
    ruleId: 20,
    scene: RuleScene.added,
    order: 'z',
  );
  const group = ProxyGroup(
    id: 30,
    profileId: 1,
    name: 'one',
    type: GroupType.Selector,
    order: 'z',
  );

  Future<void> seed() =>
      db.restore([profile], [script], [rule], [link], [group]);

  test('merge keeps the complete existing dependency graph', () async {
    await seed();
    await db.restore(
      [const Profile(id: 2, autoUpdateDuration: Duration.zero)],
      [],
      [],
      [],
      [],
    );
    expect((await db.profilesDao.query().get()).map((p) => p.id).toSet(), {
      1,
      2,
    });
    expect(await db.scriptsDao.query().get(), [script]);
    expect((await db.rulesDao.queryAddedRules(1).get()).single.id, 20);
    expect((await db.proxyGroups.select().get()).single.name, 'one');
  });

  test('empty overwrite actually removes all previous rows', () async {
    await seed();
    await db.restore([], [], [], [], [], isOverride: true);
    expect(await db.profilesDao.query().get(), isEmpty);
    expect(await db.scriptsDao.query().get(), isEmpty);
    expect(await db.rules.select().get(), isEmpty);
    expect(await db.profileRuleLinks.select().get(), isEmpty);
    expect(await db.proxyGroups.select().get(), isEmpty);
  });

  test('restore preserves rule, link, group and profile sort keys', () async {
    await seed();
    expect((await db.profilesDao.query().get()).single.order, 9);
    expect((await db.rulesDao.queryAddedRules(1).get()).single.order, 'z');
    expect((await db.profileRuleLinks.select().get()).single.order, 'z');
    expect((await db.proxyGroups.select().get()).single.order, 'z');
  });

  test(
    'ID collision and incomplete references leave old rows unchanged',
    () async {
      await seed();
      await expectLater(
        db.restore([profile.copyWith(label: 'different')], [], [], [], []),
        throwsStateError,
      );
      await expectLater(
        db.restore(
          [],
          [],
          [],
          [link.copyWith(ruleId: 999)],
          [],
          isOverride: true,
        ),
        throwsFormatException,
      );
      expect(await db.profilesDao.query().get(), [profile]);
      expect(await db.scriptsDao.query().get(), [script]);
    },
  );

  test('foreign keys cascade groups and links on profile deletion', () async {
    await seed();
    await (db.profiles.delete()..where((p) => p.id.equals(1))).go();
    expect(await db.proxyGroups.select().get(), isEmpty);
    expect(await db.profileRuleLinks.select().get(), isEmpty);
    expect(
      (await db.customSelect('PRAGMA foreign_keys').getSingle())
          .data
          .values
          .single,
      1,
    );
  });

  test('group name collision is rejected before changing the graph', () async {
    await seed();
    await expectLater(
      db.restore([], [], [], [], [group.copyWith(id: 99)]),
      throwsFormatException,
    );
    expect((await db.proxyGroups.select().get()).single.id, group.id);
  });

  test(
    'quoted group rename changes exact list elements, preserving JSON',
    () async {
      await seed();
      await db.proxyGroups.put(
        const ProxyGroup(
          id: 31,
          profileId: 1,
          name: 'other',
          type: GroupType.Selector,
          proxies: ['one', 'one-more'],
        ).toCompanion(),
      );
      await db.proxyGroupsDao.renameProxies(
        1,
        oldName: 'one',
        newName: 'new"name',
      );
      final rows = await db.proxyGroupsDao.query(1).get();
      expect(rows.singleWhere((g) => g.id == 31).proxies, [
        'new"name',
        'one-more',
      ]);
    },
  );
}
