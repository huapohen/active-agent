import 'dart:async';
import 'dart:convert';

import 'package:active_office/main.dart';
import 'package:active_office/message_groups.dart';
import 'package:active_office/office_state.dart';
import 'package:active_office/ui/message_group_editor.dart';
import 'package:active_office/ui/message_group_labels.dart';
import 'package:active_office/ui/message_group_widgets.dart';
import 'package:active_office/ui/office_theme.dart' show officeTheme;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Json groupCopy(Json value) => Json.from(jsonDecode(jsonEncode(value)));

const groupRooms = <Json>[
  {'id': 'room-human', 'kind': 'direct', 'name': '人类同事单聊', 'unread_count': 0},
  {
    'id': 'room-agent',
    'kind': 'direct',
    'name': 'Agent 同事单聊',
    'unread_count': 2,
  },
  {'id': 'room-mixed', 'kind': 'group', 'name': '人机共同项目群', 'unread_count': 1},
];

Json groupSnapshot(String principal, {int revision = 1}) {
  final names = {
    'messages': '消息',
    'unread': '未读',
    'marked': '标记',
    'mentions': '@我',
    'direct': '单聊',
    'groups': '群组',
    'completed': '已完成',
    'muted': '免打扰',
    'agents': 'Agent单聊',
    'label-$principal': principal == 'human-fixture' ? '人类私有项目' : 'Agent私有项目',
  };
  final rooms = <String, List<String>>{
    'messages': groupRooms.map((room) => room['id'] as String).toList(),
    'unread': ['room-agent', 'room-mixed'],
    'mentions': ['room-mixed'],
    'direct': ['room-human', 'room-agent'],
    'groups': ['room-mixed'],
    'agents': ['room-agent'],
    'label-$principal': ['room-mixed'],
  };
  return {
    'protocol': 'message-groups/v1',
    'principal_id': principal,
    'revision': revision,
    'updated_at': '2026-09-06T09:30:00.000Z',
    'order': names.keys.toList(),
    'hidden_ids': ['muted', 'agents'],
    'shortcut_ids': ['messages', 'unread', 'mentions'],
    'groups': names.entries
        .map(
          (entry) => <String, dynamic>{
            'id': entry.key,
            'name': entry.value,
            'description': '当前身份的可见会话',
            'type': entry.key.startsWith('label-') ? 'label' : 'builtin',
            'fixed': entry.key == 'messages',
            'visible': !['muted', 'agents'].contains(entry.key),
            'available': true,
            'name_contains': null,
            'room_ids': rooms[entry.key] ?? <String>[],
            'room_count': (rooms[entry.key] ?? []).length,
            'unread_count': 0,
          },
        )
        .toList(),
  };
}

/// Only the authenticated API transport is replaced. Controller, filtering,
/// dialogs, conflict merge and shell are the real production widgets.
class MessageGroupOfficeFixture extends OfficeState {
  MessageGroupOfficeFixture() {
    endpoint = 'https://message-groups-fixture.example';
    connected = true;
    me = {'id': 'human-fixture', 'kind': 'human', 'name': '合成同事'};
    rooms = groupRooms.map(groupCopy).toList();
    principals = [
      me!,
      {'id': 'agent-fixture', 'kind': 'agent', 'name': '合成 Agent'},
    ];
    agents = [principals.last];
  }
  final values = <String, Json>{
    'human-fixture': groupSnapshot('human-fixture', revision: 7),
    'agent-fixture': groupSnapshot('agent-fixture'),
  };
  final calls = <Json>[];
  Completer<Json>? nextRead;
  bool conflictOnce = false;
  int nextLabel = 0;
  String get identity => me!['id'] as String;
  List<Json> requests(String method, [String? path]) => calls
      .where(
        (call) =>
            call['method'] == method && (path == null || call['path'] == path),
      )
      .toList();
  void switchIdentity(String id) {
    me = {
      'id': id,
      'kind': id == 'agent-fixture' ? 'agent' : 'human',
      'name': '合成身份',
    };
    notifyListeners();
  }

  void _normalize(Json value) {
    final groups = (value['groups'] as List).cast<Json>();
    value['groups'] = [
      for (final id in value['order'] as List)
        {
          ...groups.firstWhere((group) => group['id'] == id),
          'visible': !(value['hidden_ids'] as List).contains(id),
        },
    ];
  }

  @override
  Future<Json> officeRequest(
    String path, {
    String method = 'GET',
    Json? data,
  }) async {
    final owner = identity;
    calls.add({
      'owner': owner,
      'path': path,
      'method': method,
      'data': data == null ? null : groupCopy(data),
    });
    if (path == '/message-groups' && method == 'GET') {
      final pending = nextRead;
      nextRead = null;
      return pending == null ? groupCopy(values[owner]!) : pending.future;
    }
    final current = values[owner]!;
    if (path.startsWith('/message-groups') && method != 'GET') {
      expect(data!.containsKey('owner_id'), isFalse);
      expect(data.containsKey('principal_id'), isFalse);
      if (conflictOnce) {
        conflictOnce = false;
        current['revision'] = (current['revision'] as int) + 1;
        final serverLabel = <String, dynamic>{
          'id': 'label-from-other-device',
          'name': '另一设备新增标签',
          'type': 'label',
          'visible': true,
          'available': true,
          'room_ids': <String>[],
          'room_count': 0,
          'unread_count': 0,
        };
        (current['groups'] as List).add(serverLabel);
        (current['order'] as List).add(serverLabel['id']);
        throw OfficeException(
          409,
          '个人分组已变化。你的草稿仍在，请读取最新版本后合并',
          code: 'conflict',
        );
      }
      if (data['base_revision'] != current['revision']) {
        throw OfficeException(409, '个人分组版本冲突', code: 'conflict');
      }
      String? created;
      if (path == '/message-groups' && method == 'PATCH') {
        expect(data.keys.toSet(), {
          'base_revision',
          'order',
          'hidden_ids',
          'shortcut_ids',
        });
        for (final key in ['order', 'hidden_ids', 'shortcut_ids']) {
          current[key] = List<String>.from(data[key]);
        }
      } else if (path == '/message-groups' && method == 'POST') {
        expect(data.keys.toSet(), {
          'base_revision',
          'client_id',
          'name',
          'name_contains',
        });
        expect(data['client_id'], isNotEmpty);
        created = 'label-created-${++nextLabel}';
        (current['groups'] as List).add({
          'id': created,
          'name': data['name'],
          'name_contains': data['name_contains'],
          'type': 'label',
          'visible': true,
          'available': true,
          'room_ids': <String>[],
          'room_count': 0,
          'unread_count': 0,
        });
        (current['order'] as List).add(created);
      } else if (path.startsWith('/message-groups/')) {
        final id = path.split('/').last;
        final groups = (current['groups'] as List).cast<Json>();
        final group = groups.firstWhere((item) => item['id'] == id);
        if (method == 'DELETE') {
          groups.removeWhere((item) => item['id'] == id);
          for (final field in ['order', 'hidden_ids', 'shortcut_ids']) {
            (current[field] as List).remove(id);
          }
        } else if (method == 'PATCH') {
          for (final field in ['name', 'name_contains']) {
            if (data.containsKey(field)) group[field] = data[field];
          }
          final ids = Set<String>.from(group['room_ids'] ?? []);
          ids.addAll(List<String>.from(data['add_room_ids'] ?? []));
          ids.removeAll(List<String>.from(data['remove_room_ids'] ?? []));
          group['room_ids'] = ids.toList();
          group['room_count'] = ids.length;
        } else {
          throw StateError('Unexpected fixture method: $method $path');
        }
      } else {
        throw StateError('Unexpected fixture mutation: $method $path');
      }
      current['revision'] = (current['revision'] as int) + 1;
      _normalize(current);
      return {...groupCopy(current), 'created_group_id': ?created};
    }
    throw StateError('Unexpected fixture request: $method $path');
  }
}

class RoomGroupingOfficeFixture extends MessageGroupOfficeFixture {
  RoomGroupingOfficeFixture() {
    final current = values['human-fixture']!;
    for (final entry in {
      'label-automatic': '自动项目规则',
      'label-manual-new': '另一个手工项目',
    }.entries) {
      (current['order'] as List).add(entry.key);
      (current['groups'] as List).add({
        'id': entry.key,
        'name': entry.value,
        'type': 'label',
        'visible': true,
        'available': true,
        'name_contains': entry.key == 'label-automatic' ? '共同项目' : null,
        'room_ids': entry.key == 'label-automatic'
            ? ['room-mixed']
            : <String>[],
        'room_count': entry.key == 'label-automatic' ? 1 : 0,
        'unread_count': 0,
      });
    }
  }

  Json grouping = {
    'protocol': 'message-grouping/v1',
    'principal_id': 'human-fixture',
    'room_id': 'room-mixed',
    'group_ids': ['label-human-fixture', 'label-automatic'],
    'manual_group_ids': ['label-human-fixture'],
    'matched_group_ids': ['label-automatic'],
    'marked': false,
    'completed': false,
  };
  bool roomConflictOnce = true;

  @override
  Future<Json> officeRequest(
    String path, {
    String method = 'GET',
    Json? data,
  }) async {
    if (path != '/rooms/room-mixed' &&
        path != '/rooms/room-mixed/message-groups') {
      return super.officeRequest(path, method: method, data: data);
    }
    calls.add({
      'owner': identity,
      'path': path,
      'method': method,
      'data': data == null ? null : groupCopy(data),
    });
    if (path == '/rooms/room-mixed' && method == 'GET') {
      return {
        'room': {...groupRooms.last, 'message_grouping': groupCopy(grouping)},
        'tasks': [
          {'id': 'task-unchanged', 'status': 'open'},
        ],
      };
    }
    expect(path, '/rooms/room-mixed/message-groups');
    expect(method, 'PATCH');
    expect(data!.keys.toSet(), {
      'base_revision',
      'group_ids',
      'marked',
      'completed',
    });
    final current = values[identity]!;
    expect(data['base_revision'], current['revision']);
    if (roomConflictOnce) {
      roomConflictOnce = false;
      current['revision'] = (current['revision'] as int) + 1;
      throw OfficeException(409, '个人归组已变化，保留选择后读取最新版本', code: 'conflict');
    }
    grouping = {
      ...grouping,
      'manual_group_ids': List<String>.from(data['group_ids']),
      'group_ids': [...List<String>.from(data['group_ids']), 'label-automatic'],
      'marked': data['marked'],
      'completed': data['completed'],
    };
    current['revision'] = (current['revision'] as int) + 1;
    return {...groupCopy(current), 'room_grouping': groupCopy(grouping)};
  }
}

Future<void> groupSurface(
  WidgetTester tester,
  Size size,
  Widget child, {
  double keyboard = 0,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
  await tester.pumpWidget(MaterialApp(theme: officeTheme(), home: child));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'single conversation grouping keeps automatic tags immutable and personal choices through a CAS retry',
    (tester) async {
      final state = RoomGroupingOfficeFixture();
      final controller = OfficeMessageGroups(state);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        tester.view.resetViewInsets();
        controller.dispose();
        state.dispose();
      });
      await controller.readLatest();
      await groupSurface(
        tester,
        const Size(390, 844),
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  showOfficeRoomGrouping(context, controller, groupRooms.last),
              child: const Text('打开会话归组'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开会话归组'));
      await tester.pumpAndSettle();
      CheckboxListTile check(String name) => tester.widget<CheckboxListTile>(
        find.widgetWithText(CheckboxListTile, name),
      );
      SwitchListTile toggle(String name) => tester.widget<SwitchListTile>(
        find.widgetWithText(SwitchListTile, name),
      );
      expect(check('人类私有项目').value, isTrue);
      expect(check('自动项目规则').value, isTrue);
      expect(check('自动项目规则').onChanged, isNull);
      expect(find.text('由名称规则自动加入；编辑规则后才能移出。'), findsOneWidget);
      expect(check('另一个手工项目').value, isFalse);
      await tester.tap(find.text('标记'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('已完成'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('人类私有项目'));
      await tester.tap(find.text('人类私有项目'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('另一个手工项目'));
      await tester.tap(find.text('另一个手工项目'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存归组'));
      await tester.pumpAndSettle();
      expect(check('人类私有项目').value, isFalse);
      expect(check('另一个手工项目').value, isTrue);
      expect(toggle('标记').value, isTrue);
      expect(toggle('已完成').value, isTrue);
      expect(check('自动项目规则').onChanged, isNull);
      await tester.ensureVisible(find.text('读取最新归组并保留选择'));
      await tester.tap(find.text('读取最新归组并保留选择'));
      await tester.pumpAndSettle();
      expect(check('人类私有项目').value, isFalse);
      expect(check('另一个手工项目').value, isTrue);
      expect(toggle('标记').value, isTrue);
      expect(toggle('已完成').value, isTrue);
      expect(check('自动项目规则').value, isTrue);
      expect(check('自动项目规则').onChanged, isNull);
      await tester.tap(find.text('保存归组'));
      await tester.pumpAndSettle();
      expect(find.text('保存归组'), findsNothing);
      final writes = state.requests('PATCH');
      expect(writes, hasLength(2));
      expect(
        writes.map((call) => call['path']),
        everyElement('/rooms/room-mixed/message-groups'),
      );
      expect(
        writes.map((call) => call['owner']),
        everyElement('human-fixture'),
      );
      expect(writes.map((call) => call['data']['base_revision']), [7, 8]);
      for (final call in writes) {
        expect(call['data']['group_ids'], ['label-manual-new']);
        expect(call['data']['marked'], isTrue);
        expect(call['data']['completed'], isTrue);
      }
      expect(state.requests('GET', '/rooms/room-mixed'), hasLength(2));
      expect(state.requests('POST'), isEmpty);
      expect(state.requests('DELETE'), isEmpty);
      expect(state.grouping['group_ids'], [
        'label-manual-new',
        'label-automatic',
      ]);
      expect(state.rooms, groupRooms);
      expect(controller.revision, 9);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final size in [const Size(390, 844), const Size(1512, 982)]) {
    testWidgets(
      '${size.width.toInt()}px shell opens real groups and filters human Agent direct and mixed conversations',
      (tester) async {
        final state = MessageGroupOfficeFixture();
        state.values['human-fixture']!['hidden_ids'] = ['muted'];
        state._normalize(state.values['human-fixture']!);
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
          tester.view.resetViewInsets();
          state.dispose();
        });
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        await tester.pumpWidget(ActiveOfficeApp(state: state));
        await tester.pumpAndSettle();
        for (final room in groupRooms) {
          expect(find.text(room['name'] as String), findsOneWidget);
        }
        Future<void> choose(String label) async {
          if (find.byType(OfficeMessageGroupPanel).evaluate().isEmpty) {
            await tester.tap(find.byTooltip('消息分组'));
            await tester.pumpAndSettle();
          }
          final panel = find.byType(OfficeMessageGroupPanel);
          expect(panel, findsOneWidget);
          final width = tester.getSize(panel).width;
          if (size.width < 760) {
            expect(width, closeTo(size.width * .80, 1));
            expect(tester.getTopLeft(panel).dx, 0);
          } else {
            expect(width, inInclusiveRange(140, 200));
          }
          final choice = find.descendant(of: panel, matching: find.text(label));
          await tester.ensureVisible(choice);
          await tester.tap(choice);
          await tester.pumpAndSettle();
          if (size.width < 760) {
            expect(find.byType(OfficeMessageGroupPanel), findsNothing);
          }
        }

        await choose('单聊');
        expect(find.text('人类同事单聊'), findsOneWidget);
        expect(find.text('Agent 同事单聊'), findsOneWidget);
        expect(find.text('人机共同项目群'), findsNothing);
        await choose('Agent单聊');
        expect(find.text('人类同事单聊'), findsNothing);
        expect(find.text('Agent 同事单聊'), findsOneWidget);
        expect(find.text('人机共同项目群'), findsNothing);
        await choose('群组');
        expect(find.text('人机共同项目群'), findsOneWidget);
        expect(find.text('人类同事单聊'), findsNothing);
        expect(find.text('Agent 同事单聊'), findsNothing);
        expect(tester.takeException(), isNull);
        expect(state.requests('PATCH'), isEmpty);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    '390px keyboard keeps label draft through CAS retry, then adds human Agent and mixed rooms, renames and deletes only the label',
    (tester) async {
      final state = MessageGroupOfficeFixture()..conflictOnce = true;
      final controller = OfficeMessageGroups(state);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        tester.view.resetViewInsets();
        controller.dispose();
        state.dispose();
      });
      await controller.readLatest();
      Json label() => controller.groups.firstWhere(
        (item) => (item['id'] as String).startsWith('label-created-'),
      );
      await groupSurface(
        tester,
        const Size(390, 844),
        Scaffold(
          body: Builder(
            builder: (context) => Column(
              children: [
                TextButton(
                  onPressed: () =>
                      showOfficeMessageLabelEditor(context, controller),
                  child: const Text('创建测试标签'),
                ),
                TextButton(
                  onPressed: () =>
                      showOfficeMessageLabelRooms(context, controller, label()),
                  child: const Text('加入测试会话'),
                ),
                TextButton(
                  onPressed: () => showOfficeMessageLabelEditor(
                    context,
                    controller,
                    label: label(),
                  ),
                  child: const Text('修改测试标签'),
                ),
                TextButton(
                  onPressed: () =>
                      deleteOfficeMessageLabel(context, controller, label()),
                  child: const Text('删除测试标签'),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.tap(find.text('创建测试标签'));
      await tester.pumpAndSettle();
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '需要保留的项目草稿');
      await tester.enterText(find.byType(TextField).last, '共同项目');
      await tester.ensureVisible(find.text('保存标签'));
      await tester.tap(find.text('保存标签'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        '需要保留的项目草稿',
      );
      expect(
        tester.widget<TextField>(find.byType(TextField).last).controller!.text,
        '共同项目',
      );
      expect(find.text('新建标签'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('读取最新版本并保留输入'));
      await tester.tap(find.text('读取最新版本并保留输入'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存标签'));
      await tester.pumpAndSettle();
      final creates = state.requests('POST', '/message-groups');
      expect(creates.map((call) => call['data']['base_revision']), [7, 8]);
      expect(
        creates.first['data']['client_id'],
        creates.last['data']['client_id'],
      );
      expect(creates.last['data']['name'], '需要保留的项目草稿');
      expect(creates.last['data']['name_contains'], '共同项目');
      expect(find.text('新建标签'), findsNothing);
      final id = label()['id'] as String;
      tester.view.resetViewInsets();
      await tester.pumpAndSettle();
      await tester.tap(find.text('加入测试会话'));
      await tester.pumpAndSettle();
      for (final name in ['人类同事单聊', 'Agent 同事单聊', '人机共同项目群']) {
        await tester.tap(find.text(name));
        await tester.pumpAndSettle();
      }
      expect(find.text('已选：3 个会话'), findsOneWidget);
      await tester.tap(find.text('添加会话'));
      await tester.pumpAndSettle();
      expect(
        state
            .requests('PATCH', '/message-groups/$id')
            .last['data']['add_room_ids'],
        unorderedEquals(['room-human', 'room-agent', 'room-mixed']),
      );
      await tester.tap(find.text('修改测试标签'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '已核对的项目标签');
      await tester.tap(find.text('保存标签'));
      await tester.pumpAndSettle();
      expect(label()['name'], '已核对的项目标签');
      await tester.tap(find.text('删除测试标签'));
      await tester.pumpAndSettle();
      expect(find.text('只移除你的标签与归组关系，会话和消息会保留。'), findsOneWidget);
      await tester.tap(find.text('删除标签'));
      await tester.pumpAndSettle();
      expect(state.requests('DELETE').single['path'], '/message-groups/$id');
      expect(controller.group(id), isNull);
      expect(state.rooms.map((room) => room['id']), [
        'room-human',
        'room-agent',
        'room-mixed',
      ]);
      expect(state.values['agent-fixture']!['revision'], 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'an open editor cannot save one identity draft using another identity at the same revision',
    (tester) async {
      final state = MessageGroupOfficeFixture();
      state.values['agent-fixture']!['revision'] = 7;
      final controller = OfficeMessageGroups(state);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        tester.view.resetViewInsets();
        controller.dispose();
        state.dispose();
      });
      await controller.readLatest();
      await groupSurface(
        tester,
        const Size(390, 844),
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  showOfficeMessageGroupEditor(context, controller),
              child: const Text('打开编辑器'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开编辑器'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byTooltip('隐藏单聊'));
      await tester.tap(find.byTooltip('隐藏单聊'));
      await tester.pumpAndSettle();
      state.switchIdentity('agent-fixture');
      await controller.readLatest();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.text('保存'), findsNothing);
      expect(find.byType(OfficeMessageGroupEditor), findsNothing);
      expect(state.requests('PATCH'), isEmpty);
      expect(state.values['agent-fixture']!['hidden_ids'], ['muted', 'agents']);
      expect(find.textContaining('当前身份已变化'), findsWidgets);
      expect(find.text('人类私有项目'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test('server room membership filters include human and Agent direct rooms and mixed groups', () async {
    final state = MessageGroupOfficeFixture();
    final controller = OfficeMessageGroups(state);
    addTearDown(() {
      controller.dispose();
      state.dispose();
    });
    await controller.readLatest();
    expect(controller.filteredRooms.map((room) => room['id']), [
      'room-human',
      'room-agent',
      'room-mixed',
    ]);
    controller.select('direct');
    expect(controller.filteredRooms.map((room) => room['id']), [
      'room-human',
      'room-agent',
    ]);
    controller.select('agents');
    expect(controller.filteredRooms.map((room) => room['id']), ['room-agent']);
    controller.select('groups');
    expect(controller.filteredRooms.map((room) => room['id']), ['room-mixed']);
    controller.select('unread');
    expect(controller.filteredRooms.map((room) => room['id']), [
      'room-agent',
      'room-mixed',
    ]);
  });

  test('identity switch clears private groups immediately and accepts a lower revision for the new principal', () async {
    final state = MessageGroupOfficeFixture();
    final controller = OfficeMessageGroups(state);
    addTearDown(() {
      controller.dispose();
      state.dispose();
    });
    await controller.readLatest();
    controller.select('label-human-fixture');
    expect(controller.revision, 7);
    state.switchIdentity('agent-fixture');
    expect(controller.loaded, isFalse);
    expect(controller.labels, isEmpty);
    expect(controller.selectedId, 'messages');
    await controller.readLatest();
    expect(controller.revision, 1);
    expect(controller.snapshot['principal_id'], 'agent-fixture');
    expect(controller.labels.single['name'], 'Agent私有项目');
    expect(controller.group('label-human-fixture'), isNull);
    await controller.saveLayout(
      baseRevision: 1,
      order: controller.order,
      hiddenIds: ['direct'],
      shortcutIds: ['messages', 'agents'],
    );
    expect(state.values['human-fixture']!['revision'], 7);
    expect(state.values['human-fixture']!['shortcut_ids'], [
      'messages',
      'unread',
      'mentions',
    ]);
    expect(state.requests('PATCH').single['owner'], 'agent-fixture');
  });

  test(
    'a previous identity slow response cannot overwrite new private groups',
    () async {
      final state = MessageGroupOfficeFixture();
      final controller = OfficeMessageGroups(state);
      addTearDown(() {
        controller.dispose();
        state.dispose();
      });
      await controller.readLatest();
      final delayed = Completer<Json>();
      state.nextRead = delayed;
      final oldRead = controller.readLatest().then<Object>(
        (value) => value,
        onError: (Object error) => error,
      );
      state.switchIdentity('agent-fixture');
      await controller.readLatest();
      delayed.complete(groupSnapshot('human-fixture', revision: 99));
      await oldRead;
      expect(controller.snapshot['principal_id'], 'agent-fixture');
      expect(controller.revision, 1);
      expect(controller.group('label-human-fixture'), isNull);
    },
  );

  testWidgets(
    '390px group editor preserves local choices across CAS conflict and merges a new server label',
    (tester) async {
      final state = MessageGroupOfficeFixture()..conflictOnce = true;
      final controller = OfficeMessageGroups(state);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        tester.view.resetViewInsets();
        controller.dispose();
        state.dispose();
      });
      await controller.readLatest();
      await groupSurface(
        tester,
        const Size(390, 844),
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  showOfficeMessageGroupEditor(context, controller),
              child: const Text('打开编辑器'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开编辑器'));
      await tester.pumpAndSettle();
      expect(find.byType(OfficeMessageGroupEditor), findsOneWidget);
      final fixed = tester.widget<IconButton>(
        find
            .ancestor(
              of: find.byTooltip('隐藏消息'),
              matching: find.byType(IconButton),
            )
            .first,
      );
      expect(fixed.onPressed, isNull);
      await tester.ensureVisible(find.byTooltip('隐藏单聊'));
      await tester.tap(find.byTooltip('隐藏单聊'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byTooltip('添加常用分组'));
      await tester.tap(find.byTooltip('添加常用分组'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Agent单聊').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.byType(OfficeMessageGroupEditor), findsOneWidget);
      expect(state.requests('PATCH').single['data']['base_revision'], 7);
      expect(
        state.requests('PATCH').single['data']['hidden_ids'],
        contains('direct'),
      );
      await tester.scrollUntilVisible(
        find.text('读取最新分组'),
        250,
        scrollable: find
            .descendant(
              of: find.byType(OfficeMessageGroupEditor),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.tap(find.text('读取最新分组'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('保留我的编辑并采用新版本'),
        250,
        scrollable: find
            .descendant(
              of: find.byType(OfficeMessageGroupEditor),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.tap(find.text('保留我的编辑并采用新版本'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.byType(OfficeMessageGroupEditor), findsNothing);
      final writes = state.requests('PATCH');
      expect(writes.map((call) => call['data']['base_revision']), [7, 8]);
      expect(writes.last['data']['hidden_ids'], contains('direct'));
      expect(writes.last['data']['shortcut_ids'], contains('agents'));
      expect(writes.last['data']['order'], contains('label-from-other-device'));
      expect(controller.revision, 9);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
