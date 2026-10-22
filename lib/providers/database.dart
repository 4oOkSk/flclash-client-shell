import 'dart:async';

import 'package:collection/collection.dart';
import 'package:drift/drift.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/database/database.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'generated/database.g.dart';

Future<void> withRollback<T>({
  required T snapshot,
  required FutureOr<void> Function() action,
  required void Function(T snapshot) rollback,
}) async {
  try {
    await action();
  } catch (e, s) {
    rollback(snapshot);
    Error.throwWithStackTrace(e, s);
  }
}

@riverpod
Stream<List<Profile>> profilesStream(Ref ref) {
  return database.profilesDao.query().watch();
}

@riverpod
Stream<int> customRulesCount(Ref ref, int profileId) {
  return database.rulesDao.profileCustomRulesCount(profileId).watchSingle();
}

@riverpod
Stream<int> proxyGroupsCount(Ref ref, int profileId) {
  return database.proxyGroupsDao.count(profileId).watchSingle();
}

@Riverpod(keepAlive: true)
class Profiles extends _$Profiles {
  @override
  List<Profile> build() {
    return ref.watch(profilesStreamProvider).value ?? [];
  }

  void put(Profile profile) {
    final previous = List<Profile>.from(state);
    final newProfile = previous.optimizeLabel(profile);
    state = previous.copyAndPut(newProfile, (item) => item.id == newProfile.id);
    unawaited(
      withRollback(
        snapshot: previous,
        action: () => database.profiles.put(newProfile.toCompanion()),
        rollback: (v) => state = v,
      ),
    );
  }

  Future<void> del(int id) async {
    final previous = List<Profile>.from(state);
    state = previous.where((e) => e.id != id).toList();
    await withRollback(
      snapshot: previous,
      action: () => database.profiles.remove((t) => t.id.equals(id)),
      rollback: (v) => state = v,
    );
  }

  void updateProfile(int profileId, Profile Function(Profile profile) builder) {
    final index = state.indexWhere((element) => element.id == profileId);
    if (index == -1) return;
    final newProfile = builder(state[index]);
    final previous = List<Profile>.from(state);
    final next = List<Profile>.from(previous);
    next[index] = newProfile;
    state = next;
    unawaited(
      withRollback(
        snapshot: previous,
        action: () => database.profiles.put(newProfile.toCompanion()),
        rollback: (v) => state = v,
      ),
    );
  }

  void setAndReorder(List<Profile> profiles) {
    final previous = List<Profile>.from(state);
    state = List<Profile>.from(profiles);
    unawaited(
      withRollback(
        snapshot: previous,
        action: () => database.profilesDao.setAll(profiles),
        rollback: (v) => state = v,
      ),
    );
  }

  void reorder(List<Profile> profiles) {
    final previous = List<Profile>.from(state);
    final next = List<Profile>.from(profiles);
    final needUpdate = <ProfilesCompanion>[];
    next.forEachIndexed((index, item) {
      if (item.order != index) {
        needUpdate.add(item.toCompanion(index));
      }
    });
    state = next;
    unawaited(
      withRollback(
        snapshot: previous,
        action: () => database.profilesDao.putAll(needUpdate),
        rollback: (v) => state = v,
      ),
    );
  }

  @override
  bool updateShouldNotify(List<Profile> previous, List<Profile> next) {
    return !profileListEquality.equals(previous, next);
  }
}

@riverpod
class Scripts extends _$Scripts with AsyncNotifierMixin {
  @override
  Stream<List<Script>> build() {
    return database.scriptsDao.query().watch();
  }

  @override
  List<Script> get value => state.value ?? [];

  @override
  bool updateShouldNotify(
    AsyncValue<List<Script>> previous,
    AsyncValue<List<Script>> next,
  ) {
    return !scriptListEquality.equals(previous.value, next.value);
  }
}

@riverpod
Future<Script?> script(Ref ref, int? scriptId) async {
  final script = ref.watch(
    scriptsProvider.future.select((state) async {
      final scripts = await state;
      return scripts.get(scriptId);
    }),
  );
  return script;
}

@riverpod
class GlobalRules extends _$GlobalRules with AsyncNotifierMixin {
  @override
  Stream<List<Rule>> build() {
    return database.rulesDao.queryGlobalAddedRules().watch();
  }

  @override
  List<Rule> get value => state.value ?? [];

  @override
  bool updateShouldNotify(
    AsyncValue<List<Rule>> previous,
    AsyncValue<List<Rule>> next,
  ) {
    return !ruleListEquality.equals(previous.value, next.value);
  }

  void delAll(Iterable<int> ruleIds) {
    final previous = List<Rule>.from(value);
    value = List.from(previous.where((item) => !ruleIds.contains(item.id)));
    unawaited(
      withRollback(
        snapshot: previous,
        action: () => database.rulesDao.delRules(ruleIds),
        rollback: (v) => value = v,
      ),
    );
  }

  void put(Rule rule) {
    final previous = List<Rule>.from(value);
    final newRule = rule.autoOrder(rule, null, previous.firstOrNull?.order);
    value = previous.copyAndPut(newRule, (rule) => rule.id == newRule.id);
    unawaited(
      withRollback(
        snapshot: previous,
        action: () => database.rulesDao.putGlobalRule(newRule),
        rollback: (v) => value = v,
      ),
    );
  }

  void order(int oldIndex, int newIndex) {
    final previous = List<Rule>.from(value);
    final item = previous[oldIndex];
    final nextItems = previous.copyAndReorder(oldIndex, newIndex);
    value = nextItems;
    final preOrder = nextItems.safeGet(newIndex - 1)?.order;
    final nextOrder = nextItems.safeGet(newIndex + 1)?.order;
    final newOrder = indexing.generateKeyBetween(preOrder, nextOrder)!;
    unawaited(
      withRollback(
        snapshot: previous,
        action: () =>
            database.rulesDao.orderGlobalRule(ruleId: item.id, order: newOrder),
        rollback: (v) => value = v,
      ),
    );
  }
}

@riverpod
class ProfileAddedRules extends _$ProfileAddedRules with AsyncNotifierMixin {
  @override
  Stream<List<Rule>> build(int profileId) {
    return database.rulesDao.queryProfileAddedRules(profileId).watch();
  }

  @override
  List<Rule> get value => state.value ?? [];

  @override
  bool updateShouldNotify(
    AsyncValue<List<Rule>> previous,
    AsyncValue<List<Rule>> next,
  ) {
    return !ruleListEquality.equals(previous.value, next.value);
  }

  void put(Rule rule) {
    final previous = List<Rule>.from(value);
    final newRule = rule.autoOrder(rule, null, previous.firstOrNull?.order);
    value = previous.copyAndPut(newRule, (rule) => rule.id == newRule.id);
    unawaited(
      withRollback(
        snapshot: previous,
        action: () => database.rulesDao.putProfileAddedRule(profileId, newRule),
        rollback: (v) => value = v,
      ),
    );
  }

  void delAll(Iterable<int> ruleIds) {
    final previous = List<Rule>.from(value);
    value = List.from(previous.where((item) => !ruleIds.contains(item.id)));
    unawaited(
      withRollback(
        snapshot: previous,
        action: () => database.rulesDao.delRules(ruleIds),
        rollback: (v) => value = v,
      ),
    );
  }

  void order(int oldIndex, int newIndex) {
    final previous = List<Rule>.from(value);
    final item = previous[oldIndex];
    final nextItems = previous.copyAndReorder(oldIndex, newIndex);
    value = nextItems;
    final preOrder = nextItems.safeGet(newIndex - 1)?.order;
    final nextOrder = nextItems.safeGet(newIndex + 1)?.order;
    final newOrder = indexing.generateKeyBetween(preOrder, nextOrder)!;
    unawaited(
      withRollback(
        snapshot: previous,
        action: () => database.rulesDao.orderProfileAddedRule(
          profileId,
          ruleId: item.id,
          order: newOrder,
        ),
        rollback: (v) => value = v,
      ),
    );
  }
}

@riverpod
class ProfileCustomRules extends _$ProfileCustomRules with AsyncNotifierMixin {
  @override
  Stream<List<Rule>> build(int profileId) {
    return database.rulesDao.queryProfileCustomRules(profileId).watch();
  }

  @override
  List<Rule> get value => state.value ?? [];

  @override
  bool updateShouldNotify(
    AsyncValue<List<Rule>> previous,
    AsyncValue<List<Rule>> next,
  ) {
    return !ruleListEquality.equals(previous.value, next.value);
  }

  void put(Rule rule) {
    final previous = List<Rule>.from(value);
    final newRule = rule.autoOrder(rule, null, previous.firstOrNull?.order);
    value = previous.copyAndPut(newRule, (rule) => rule.id == newRule.id);
    unawaited(
      withRollback(
        snapshot: previous,
        action: () =>
            database.rulesDao.putProfileCustomRule(profileId, newRule),
        rollback: (v) => value = v,
      ),
    );
  }

  void delAll(Iterable<int> ruleIds) {
    final previous = List<Rule>.from(value);
    value = List.from(previous.where((item) => !ruleIds.contains(item.id)));
    unawaited(
      withRollback(
        snapshot: previous,
        action: () => database.rulesDao.delRules(ruleIds),
        rollback: (v) => value = v,
      ),
    );
  }

  void order(int oldIndex, int newIndex) {
    final previous = List<Rule>.from(value);
    final item = previous[oldIndex];
    final nextItems = previous.copyAndReorder(oldIndex, newIndex);
    value = nextItems;
    final preOrder = nextItems.safeGet(newIndex - 1)?.order;
    final nextOrder = nextItems.safeGet(newIndex + 1)?.order;
    final newOrder = indexing.generateKeyBetween(preOrder, nextOrder)!;
    unawaited(
      withRollback(
        snapshot: previous,
        action: () => database.rulesDao.orderProfileCustomRule(
          profileId,
          ruleId: item.id,
          order: newOrder,
        ),
        rollback: (v) => value = v,
      ),
    );
  }
}

@riverpod
class ProxyGroups extends _$ProxyGroups with AsyncNotifierMixin {
  @override
  Stream<List<ProxyGroup>> build(int profileId) {
    return database.proxyGroupsDao.query(profileId).watch();
  }

  @override
  bool updateShouldNotify(
    AsyncValue<List<ProxyGroup>> previous,
    AsyncValue<List<ProxyGroup>> next,
  ) {
    return !proxyGroupsEquality.equals(previous.value, next.value);
  }

  void del(String name) {
    final previous = List<ProxyGroup>.from(value);
    value = List.from(previous.where((item) => item.name != name));
    unawaited(
      withRollback(
        snapshot: previous,
        action: () => database.proxyGroups.remove(
          (t) => t.profileId.equals(profileId) & t.name.equals(name),
        ),
        rollback: (v) => value = v,
      ),
    );
  }

  bool put(ProxyGroup proxyGroup) {
    final previous = List<ProxyGroup>.from(value);
    final index = previous.indexWhere((item) => item.id == proxyGroup.id);
    if (previous.any(
      (item) => item.id != proxyGroup.id && item.name == proxyGroup.name,
    )) {
      return false;
    }
    final icon = proxyGroup.icon?.value;
    if (icon != null) {
      database.iconRecordsDao.put(icon);
    }
    final next = List<ProxyGroup>.from(previous);
    if (index != -1) {
      next[index] = proxyGroup;
    } else {
      next.add(
        proxyGroup.copyWith(
          order: indexing.generateKeyBetween(null, proxyGroup.order),
        ),
      );
    }
    value = next;
    unawaited(
      withRollback(
        snapshot: previous,
        action: () => database.transaction(() async {
          final oldName = index == -1 ? null : previous[index].name;
          if (oldName != null && oldName != proxyGroup.name) {
            await database.rulesDao.renameCustomRuleTarget(
              profileId,
              oldName: oldName,
              newName: proxyGroup.name,
            );
            await database.proxyGroupsDao.renameProxies(
              profileId,
              oldName: oldName,
              newName: proxyGroup.name,
            );
          }
          await database.proxyGroups.put(proxyGroup.toCompanion(profileId));
        }),
        rollback: (v) => value = v,
      ),
    );
    return true;
  }

  void order(int oldIndex, int newIndex) {
    final previous = List<ProxyGroup>.from(value);
    final item = previous[oldIndex];
    final nextItems = previous.copyAndReorder(oldIndex, newIndex);
    value = nextItems;
    final preOrder = nextItems.safeGet(newIndex - 1)?.order;
    final nextOrder = nextItems.safeGet(newIndex + 1)?.order;
    final newOrder = indexing.generateKeyBetween(preOrder, nextOrder)!;
    unawaited(
      withRollback(
        snapshot: previous,
        action: () => database.proxyGroupsDao.order(
          profileId,
          proxyGroup: item,
          order: newOrder,
        ),
        rollback: (v) => value = v,
      ),
    );
  }

  @override
  List<ProxyGroup> get value => state.value ?? [];
}

@riverpod
class ProfileDisabledRuleIds extends _$ProfileDisabledRuleIds
    with AsyncNotifierMixin {
  @override
  List<int> get value => state.value ?? [];

  @override
  Stream<List<int>> build(int profileId) {
    return database.rulesDao
        .queryProfileDisabledRules(profileId)
        .map((item) => item.id)
        .watch();
  }

  @override
  bool updateShouldNotify(
    AsyncValue<List<int>> previous,
    AsyncValue<List<int>> next,
  ) {
    return !intListEquality.equals(previous.value, next.value);
  }

  void _put(int ruleId) {
    final newList = List<int>.from(value);
    final index = newList.indexWhere((item) => item == ruleId);
    if (index != -1) {
      newList[index] = ruleId;
    } else {
      newList.insert(0, ruleId);
    }
    value = newList;
  }

  void del(int ruleId) {
    final previous = List<int>.from(value);
    value = List.from(previous.where((item) => item != ruleId));
    unawaited(
      withRollback(
        snapshot: previous,
        action: () => database.rulesDao.delDisabledLink(profileId, ruleId),
        rollback: (v) => value = v,
      ),
    );
  }

  void put(int ruleId) {
    final previous = List<int>.from(value);
    _put(ruleId);
    unawaited(
      withRollback(
        snapshot: previous,
        action: () => database.rulesDao.putDisabledLink(profileId, ruleId),
        rollback: (v) => value = v,
      ),
    );
  }
}
