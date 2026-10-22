import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';

part 'converter.dart';
part 'generated/database.g.dart';
part 'groups.dart';
part 'icons.dart';
part 'links.dart';
part 'profiles.dart';
part 'rules.dart';
part 'scripts.dart';

@DriftDatabase(
  tables: [
    Profiles,
    Scripts,
    Rules,
    ProfileRuleLinks,
    ProxyGroups,
    IconRecords,
  ],
  daos: [ProfilesDao, ScriptsDao, RulesDao, ProxyGroupsDao, IconRecordsDao],
)
class Database extends _$Database {
  Database([QueryExecutor? executor])
    : _repairOrphans = true,
      super(executor ?? _openConnection());

  Database.forRestore(super.executor) : _repairOrphans = false;

  final bool _repairOrphans;

  @override
  int get schemaVersion => 3;

  static LazyDatabase _openConnection() {
    return LazyDatabase(() async {
      final databaseFile = File(await appPath.databasePath);
      return NativeDatabase.createInBackground(databaseFile);
    });
  }

  @override
  MigrationStrategy get migration {
    return MigrationStrategy(
      onUpgrade: (m, from, to) async {
        if (from < 2) {
          await m.createTable(proxyGroups);
          await m.createTable(iconRecords);
          await _resetOrders();
          await _migrateRules(m);
        }
      },
      beforeOpen: (details) async {
        // Repair only already-orphaned references left by older connections.
        if (_repairOrphans) {
          await transaction(() async {
            await customStatement(
              'DELETE FROM profile_rule_mapping WHERE '
              '(profile_id IS NOT NULL AND profile_id NOT IN (SELECT id FROM profiles)) '
              'OR rule_id NOT IN (SELECT id FROM rules)',
            );
            await customStatement(
              'DELETE FROM proxy_groups WHERE profile_id IS NOT NULL '
              'AND profile_id NOT IN (SELECT id FROM profiles)',
            );
          });
        }
        await customStatement('PRAGMA foreign_keys = ON');
      },
    );
  }

  Future<void> _migrateRules(Migrator m) async {
    final tableInfo = await customSelect('PRAGMA table_info(rules)').get();
    final columnNames = tableInfo
        .map((row) => row.read<String>('name'))
        .toList();
    if (columnNames.isEmpty) {
      await m.createTable(rules);
      return;
    } else if (columnNames.contains('rule_action')) {
      return;
    }
    await customStatement(
      'ALTER TABLE rules ADD COLUMN rule_action TEXT NOT NULL DEFAULT ""',
    );
    await customStatement('ALTER TABLE rules ADD COLUMN content TEXT');
    await customStatement('ALTER TABLE rules ADD COLUMN rule_target TEXT');
    await customStatement('ALTER TABLE rules ADD COLUMN rule_provider TEXT');
    await customStatement('ALTER TABLE rules ADD COLUMN sub_rule TEXT');
    await customStatement(
      'ALTER TABLE rules ADD COLUMN no_resolve INTEGER NOT NULL DEFAULT 0',
    );
    await customStatement(
      'ALTER TABLE rules ADD COLUMN src INTEGER NOT NULL DEFAULT 0',
    );
    final oldRows = await customSelect('SELECT id, value FROM rules').get();
    for (final row in oldRows) {
      final id = row.read<int>('id');
      final value = row.read<String>('value');
      final parsed = Rule.parse(value, id: id);
      await customStatement(
        'UPDATE rules SET rule_action = ?, content = ?, rule_target = ?, rule_provider = ?, sub_rule = ?, no_resolve = ?, src = ? WHERE id = ?',
        [
          parsed.ruleAction.name,
          parsed.content,
          parsed.ruleTarget,
          parsed.ruleProvider,
          parsed.subRule,
          parsed.noResolve ? 1 : 0,
          parsed.src ? 1 : 0,
          id,
        ],
      );
    }
    await customStatement('ALTER TABLE rules DROP COLUMN value');
    await m.createIndex(idxRuleTarget);
  }

  Future<void> _resetOrders() async {
    await rulesDao.resetOrders();
  }

  Future<void> restore(
    List<Profile> profiles,
    List<Script> scripts,
    List<Rule> rules,
    List<ProfileRuleLink> links,
    List<ProxyGroup> proxyGroups, {
    bool isOverride = false,
  }) async {
    await transaction(() async {
      final currentProfiles = isOverride
          ? <Profile>[]
          : await profilesDao.query().get();
      final currentScripts = isOverride
          ? <Script>[]
          : await scriptsDao.query().get();
      final currentRules = isOverride
          ? <Rule>[]
          : (await this.rules.select().get()).map((r) => r.toRule()).toList();
      final currentGroups = isOverride
          ? <ProxyGroup>[]
          : (await this.proxyGroups.select().get())
                .map((g) => g.toProxyGroup())
                .toList();
      // Identical IDs may merge. Different objects sharing an ID require an
      // explicit overwrite instead of silently damaging unrelated data.
      void check<T>(
        Iterable<T> incoming,
        Map<int, T> current,
        int Function(T) id,
        T Function(T) comparable,
      ) {
        final seen = <int>{};
        for (final item in incoming) {
          final key = id(item);
          if (!seen.add(key)) {
            throw FormatException('Duplicate backup ID: $key');
          }
          final old = current[key];
          if (old != null && comparable(old) != comparable(item)) {
            throw StateError('Backup ID conflicts with existing data: $key');
          }
        }
      }

      check(
        profiles,
        {for (final p in currentProfiles) p.id: p},
        (p) => p.id,
        (p) => p.copyWith(order: null),
      );
      check(
        scripts,
        {for (final s in currentScripts) s.id: s},
        (s) => s.id,
        (s) => s,
      );
      check(
        rules,
        {for (final r in currentRules) r.id: r},
        (r) => r.id,
        (r) => r.copyWith(order: null),
      );
      check(
        proxyGroups,
        {for (final g in currentGroups) g.id: g},
        (g) => g.id,
        (g) => g.copyWith(order: null),
      );
      final profileIds = {
        ...currentProfiles.map((p) => p.id),
        ...profiles.map((p) => p.id),
      };
      final scriptIds = {
        ...currentScripts.map((s) => s.id),
        ...scripts.map((s) => s.id),
      };
      final ruleIds = {
        ...currentRules.map((r) => r.id),
        ...rules.map((r) => r.id),
      };
      final linkIds = <String>{};
      for (final profile in profiles) {
        if (profile.scriptId != null && !scriptIds.contains(profile.scriptId)) {
          throw const FormatException('Missing backup script reference');
        }
      }
      for (final link in links) {
        if (!linkIds.add(link.key) ||
            !ruleIds.contains(link.ruleId) ||
            (link.profileId != null && !profileIds.contains(link.profileId))) {
          throw const FormatException('Invalid backup rule reference');
        }
      }
      for (final group in proxyGroups) {
        if (group.profileId != null && !profileIds.contains(group.profileId)) {
          throw const FormatException('Missing backup group profile');
        }
        if (group.name.isEmpty ||
            [...currentGroups, ...proxyGroups].any(
              (other) =>
                  other.id != group.id &&
                  other.profileId == group.profileId &&
                  other.name == group.name,
            )) {
          throw const FormatException('Duplicate or empty backup group name');
        }
      }
      if (isOverride) {
        await delete(profileRuleLinks).go();
        await delete(this.proxyGroups).go();
        await delete(this.profiles).go();
        await delete(this.rules).go();
        await delete(this.scripts).go();
      }
      await batch((b) {
        b.insertAllOnConflictUpdate(
          this.profiles,
          profiles.map((p) => p.toCompanion()),
        );
        b.insertAllOnConflictUpdate(
          this.scripts,
          scripts.map((s) => s.toCompanion()),
        );
        b.insertAllOnConflictUpdate(
          this.rules,
          rules.map((r) => r.toCompanion()),
        );
        b.insertAllOnConflictUpdate(
          profileRuleLinks,
          links.map((l) => l.toCompanion()),
        );
        b.insertAllOnConflictUpdate(
          this.proxyGroups,
          proxyGroups.map((g) => g.toCompanion()),
        );
      });
    });
  }

  Future<void> setProfileCustomData(
    int profileId,
    List<ProxyGroup> groups,
    List<Rule> rules,
  ) async {
    await batch((b) {
      proxyGroupsDao.setAllWithBatch(profileId, b, groups);
      rulesDao.setCustomRulesWithBatch(profileId, b, rules);
    });
  }
}

extension TableInfoExt<Tbl extends Table, Row> on TableInfo<Tbl, Row> {
  void setAll(
    Batch batch,
    Iterable<Insertable<Row>> items, {
    required Expression<bool> Function(Tbl tbl) deleteFilter,
    bool preDelete = false,
  }) async {
    if (preDelete) {
      batch.deleteWhere(this, deleteFilter);
    }
    batch.insertAllOnConflictUpdate(this, items);
    if (!preDelete) {
      batch.deleteWhere(this, deleteFilter);
    }
  }

  Selectable<int?> get count {
    final countExp = countAll();
    final query = select().addColumns([countExp]);
    return query.map((row) => row.read(countExp));
  }

  Future<int> remove(Expression<bool> Function(Tbl tbl) filter) async {
    return (delete()..where(filter)).go();
  }

  Future<int> put(Insertable<Row> item) async {
    return insertOnConflictUpdate(item);
  }
}

extension SimpleSelectStatementExt<T extends HasResultSet, D>
    on SimpleSelectStatement<T, D> {
  Selectable<int> get count {
    final countExp = countAll();
    final query = addColumns([countExp]);
    return query.map((row) => row.read(countExp)!);
  }
}

extension JoinedSelectStatementExt<T extends HasResultSet, D>
    on JoinedSelectStatement<T, D> {
  Selectable<int> get count {
    final countExp = countAll();
    addColumns([countExp]);
    return map((row) => row.read(countExp)!);
  }
}

final database = Database();
