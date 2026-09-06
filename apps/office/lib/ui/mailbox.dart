import 'package:flutter/material.dart';

import '../office_state.dart' hide Json;
import 'business_widgets.dart';
import 'office_dialogs.dart';
import 'office_theme.dart';

const mailFolderNames = {
  'inbox': '收件箱',
  'sent': '已发送',
  'drafts': '草稿箱',
  'archive': '归档',
  'trash': '废纸篓',
};
const mailFolderIcons = {
  'inbox': Icons.inbox_outlined,
  'sent': Icons.send_outlined,
  'drafts': Icons.drafts_outlined,
  'archive': Icons.archive_outlined,
  'trash': Icons.delete_outline,
};

class OfficeMailbox extends StatefulWidget {
  const OfficeMailbox({super.key, required this.state});
  final OfficeState state;
  @override
  State<OfficeMailbox> createState() => OfficeMailboxState();
}

class OfficeMailboxState extends State<OfficeMailbox> {
  Json? _selected;
  String? _error;
  bool _busy = false;
  final _search = TextEditingController();
  OfficeState get s => widget.state;
  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> compose([Json? draft]) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _MailComposer(state: s, draft: draft),
    );
  }

  Future<void> open(String id) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      var item = await s.getMail(id);
      if (item['status'] == 'draft') {
        if (mounted) await compose(item);
        return;
      }
      if (item['read'] != true) {
        await s.markMailRead(item, true);
        item = await s.getMail(id);
      }
      if (mounted) setState(() => _selected = item);
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _folder(String folder) async {
    setState(() {
      _busy = true;
      _error = null;
      _selected = null;
    });
    try {
      await s.loadMail(folder, query: _search.text.trim());
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _move(String folder) async {
    final selected = _selected;
    if (selected == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await s.moveMail(selected, folder);
      if (mounted) setState(() => _selected = null);
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final wide = constraints.maxWidth >= 800;
      final folders = s.mailFolders.isEmpty
          ? mailFolderNames.entries
                .map(
                  (e) => <String, dynamic>{
                    'id': e.key,
                    'name': e.value,
                    'count': 0,
                  },
                )
                .toList()
          : s.mailFolders;
      return Column(
        children: [
          BusinessHeader(
            title: '邮箱',
            subtitle: '工作空间内部往来',
            actions: [
              FilledButton.icon(
                onPressed: () => compose(),
                icon: const Icon(Icons.edit_outlined, size: 17),
                label: const Text('写邮件'),
              ),
            ],
          ),
          const Divider(height: 1),
          if (!wide)
            SizedBox(
              height: 56,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                children: folders
                    .map(
                      (folder) => Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          showCheckmark: false,
                          selected: s.mailFolder == folder['id'],
                          label: Text(
                            str(folder['name']),
                            style: const TextStyle(fontSize: 11),
                          ),
                          onSelected: _busy
                              ? null
                              : (_) => _folder(str(folder['id'])),
                        ),
                      ),
                    )
                    .toList(),
              ),
            ),
          Expanded(
            child: Row(
              children: [
                if (wide)
                  Container(
                    width: 172,
                    color: const Color(0xfff8f9fb),
                    padding: const EdgeInsets.fromLTRB(10, 18, 10, 15),
                    child: Column(
                      children: [
                        ...folders.map(
                          (folder) => Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: Material(
                              color: s.mailFolder == folder['id']
                                  ? selectedColor
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(6),
                              child: ListTile(
                                dense: true,
                                minLeadingWidth: 18,
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                ),
                                leading: Icon(
                                  mailFolderIcons[folder['id']],
                                  size: 17,
                                  color: s.mailFolder == folder['id']
                                      ? accentColor
                                      : mutedColor,
                                ),
                                title: Text(
                                  str(folder['name']),
                                  style: const TextStyle(fontSize: 12),
                                ),
                                trailing: Text(
                                  str(folder['count'], '0'),
                                  style: const TextStyle(
                                    fontSize: 10,
                                    color: mutedColor,
                                  ),
                                ),
                                onTap: _busy
                                    ? null
                                    : () => _folder(str(folder['id'])),
                              ),
                            ),
                          ),
                        ),
                        const Spacer(),
                        const Text(
                          '内部邮箱\n人和 Agent 均可收发',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 10,
                            color: mutedColor,
                            height: 1.8,
                          ),
                        ),
                      ],
                    ),
                  ),
                if (_selected == null || wide)
                  SizedBox(
                    width: wide ? 285 : constraints.maxWidth,
                    child: Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(14),
                          child: TextField(
                            controller: _search,
                            decoration: const InputDecoration(
                              hintText: '搜索当前邮件夹',
                              prefixIcon: Icon(Icons.search, size: 17),
                            ),
                            onSubmitted: (_) => _folder(s.mailFolder),
                          ),
                        ),
                        if (_busy) const LinearProgressIndicator(minHeight: 2),
                        if (_error != null)
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 14),
                            child: BusinessError(_error),
                          ),
                        Expanded(
                          child: s.mailItems.isEmpty
                              ? const EmptyOffice(
                                  title: '这里还没有邮件',
                                  subtitle: '通过写邮件，与工作空间成员正式往来。',
                                  icon: Icons.mail_outline,
                                )
                              : ListView(
                                  children: s.mailItems
                                      .map(
                                        (item) => Material(
                                          color: _selected?['id'] == item['id']
                                              ? selectedColor
                                              : Colors.white,
                                          child: InkWell(
                                            onTap: _busy
                                                ? null
                                                : () => open(str(item['id'])),
                                            child: Container(
                                              padding: const EdgeInsets.all(16),
                                              decoration: const BoxDecoration(
                                                border: Border(
                                                  bottom: BorderSide(
                                                    color: borderColor,
                                                  ),
                                                ),
                                              ),
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  Row(
                                                    children: [
                                                      if (item['read'] ==
                                                          false) ...[
                                                        const Icon(
                                                          Icons.circle,
                                                          size: 6,
                                                          color: accentColor,
                                                        ),
                                                        const SizedBox(
                                                          width: 6,
                                                        ),
                                                      ],
                                                      Expanded(
                                                        child: Text(
                                                          s.mailFolder ==
                                                                      'sent' ||
                                                                  s.mailFolder ==
                                                                      'drafts'
                                                              ? maps(item['to'])
                                                                    .map(
                                                                      (
                                                                        p,
                                                                      ) => str(
                                                                        p['name'],
                                                                      ),
                                                                    )
                                                                    .join('、')
                                                              : str(
                                                                  (item['sender']
                                                                      as Map?)?['name'],
                                                                ),
                                                          maxLines: 1,
                                                          overflow: TextOverflow
                                                              .ellipsis,
                                                          style: TextStyle(
                                                            fontSize: 12,
                                                            fontWeight:
                                                                item['read'] ==
                                                                    false
                                                                ? FontWeight
                                                                      .w700
                                                                : FontWeight
                                                                      .w500,
                                                          ),
                                                        ),
                                                      ),
                                                      const SizedBox(width: 5),
                                                      Text(
                                                        clockText(
                                                          item['sent_at'] ??
                                                              item['updated_at'],
                                                          context: context,
                                                        ),
                                                        style: const TextStyle(
                                                          fontSize: 9,
                                                          color: mutedColor,
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                  const SizedBox(height: 8),
                                                  Text(
                                                    str(item['subject']).isEmpty
                                                        ? '（无主题草稿）'
                                                        : str(item['subject']),
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: const TextStyle(
                                                      fontSize: 12,
                                                      fontWeight:
                                                          FontWeight.w500,
                                                    ),
                                                  ),
                                                  const SizedBox(height: 5),
                                                  Text(
                                                    str(item['preview']),
                                                    maxLines: 2,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: const TextStyle(
                                                      fontSize: 11,
                                                      color: mutedColor,
                                                      height: 1.6,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ),
                                        ),
                                      )
                                      .toList(),
                                ),
                        ),
                      ],
                    ),
                  ),
                if (wide) const VerticalDivider(width: 1),
                if (_selected != null)
                  Expanded(child: _detail(_selected!, compact: !wide))
                else if (wide)
                  const Expanded(
                    child: EmptyOffice(
                      title: '查看邮件',
                      subtitle: '选择一封邮件，阅读完整内容。',
                      icon: Icons.mark_email_read_outlined,
                    ),
                  ),
              ],
            ),
          ),
        ],
      );
    },
  );
  Widget _detail(Json item, {required bool compact}) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
        child: Wrap(
          spacing: 2,
          runSpacing: 3,
          children: [
            if (compact)
              IconButton(
                onPressed: () => setState(() => _selected = null),
                tooltip: '返回邮件列表',
                icon: const Icon(Icons.arrow_back),
              ),
            TextButton.icon(
              onPressed: _busy
                  ? null
                  : () => compose({
                      'to_ids': [item['sender_id']],
                      'subject': '回复：${str(item['subject'])}',
                      'body': '\n\n—— 原邮件 ——\n${str(item['body'])}',
                    }),
              icon: const Icon(Icons.reply, size: 17),
              label: const Text('回复'),
            ),
            if (item['folder'] != 'archive')
              IconButton(
                onPressed: _busy ? null : () => _move('archive'),
                tooltip: '归档',
                icon: const Icon(Icons.archive_outlined),
              ),
            if (item['folder'] != 'trash')
              IconButton(
                onPressed: _busy ? null : () => _move('trash'),
                tooltip: '移入废纸篓',
                icon: const Icon(Icons.delete_outline),
              ),
            if (item['folder'] == 'trash' || item['folder'] == 'archive')
              TextButton(
                onPressed: _busy
                    ? null
                    : () => _move(str(item['original_folder'], 'inbox')),
                child: const Text('恢复'),
              ),
            IconButton(
              onPressed: _busy
                  ? null
                  : () async {
                      try {
                        await s.markMailRead(item, false);
                        if (mounted) setState(() => _selected = null);
                      } catch (e) {
                        if (mounted) setState(() => _error = friendlyError(e));
                      }
                    },
              tooltip: '标为未读',
              icon: const Icon(Icons.mark_email_unread_outlined),
            ),
          ],
        ),
      ),
      const Divider(height: 1),
      Expanded(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                str(item['subject']),
                style: const TextStyle(
                  fontSize: 21,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 23),
              Row(
                children: [
                  PersonAvatar(
                    name: str((item['sender'] as Map?)?['name']),
                    agent: (item['sender'] as Map?)?['kind'] == 'agent',
                    size: 36,
                  ),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          str((item['sender'] as Map?)?['name']),
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        Text(
                          fullOfficeTime(item['sent_at'], context: context),
                          style: const TextStyle(
                            fontSize: 10,
                            color: mutedColor,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Text(
                '收件人：${maps(item['to']).map((p) => str(p['name'])).join('、')}',
                style: const TextStyle(fontSize: 11, color: mutedColor),
              ),
              if (maps(item['cc']).isNotEmpty)
                Text(
                  '抄送：${maps(item['cc']).map((p) => str(p['name'])).join('、')}',
                  style: const TextStyle(fontSize: 11, color: mutedColor),
                ),
              if (maps(item['bcc']).isNotEmpty)
                Text(
                  '密送：${maps(item['bcc']).map((p) => str(p['name'])).join('、')}',
                  style: const TextStyle(fontSize: 11, color: mutedColor),
                ),
              const Divider(height: 38),
              SelectableText(
                str(item['body']),
                style: const TextStyle(fontSize: 13, height: 1.9),
              ),
            ],
          ),
        ),
      ),
    ],
  );
}

class _MailComposer extends StatefulWidget {
  const _MailComposer({required this.state, this.draft});
  final OfficeState state;
  final Json? draft;
  @override
  State<_MailComposer> createState() => _MailComposerState();
}

class _MailComposerState extends State<_MailComposer> {
  late final _subject = TextEditingController(
        text: str(widget.draft?['subject']),
      ),
      _body = TextEditingController(text: str(widget.draft?['body']));
  late List<String> _to = List<String>.from(widget.draft?['to_ids'] ?? []),
      _cc = List<String>.from(widget.draft?['cc_ids'] ?? []),
      _bcc = List<String>.from(widget.draft?['bcc_ids'] ?? []);
  late Json? _saved = widget.draft?['id'] != null ? widget.draft : null;
  Json? _latest;
  String? _error;
  bool _busy = false, _dirty = false, _extras = false;
  OfficeState get s => widget.state;
  @override
  void initState() {
    super.initState();
    _subject.addListener(_changed);
    _body.addListener(_changed);
  }

  void _changed() {
    _dirty = true;
  }

  @override
  void dispose() {
    _subject.dispose();
    _body.dispose();
    super.dispose();
  }

  Future<void> _save(bool send) async {
    if (send &&
        (_to.isEmpty && _cc.isEmpty && _bcc.isEmpty ||
            _subject.text.trim().isEmpty)) {
      setState(() => _error = '请填写主题并选择收件人');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _latest = null;
    });
    try {
      final draft = await s.saveMailDraft(
        id: _saved == null ? null : str(_saved!['id']),
        baseRevision: (_saved?['revision'] as num?)?.toInt(),
        toIds: _to,
        ccIds: _cc,
        bccIds: _bcc,
        subject: _subject.text,
        body: _body.text,
      );
      _saved = draft;
      _dirty = false;
      if (send) {
        await s.sendMailDraft(draft);
      }
      if (mounted) {
        if (send) {
          Navigator.pop(context);
        } else {
          setState(() {});
          notifyOffice(context, '草稿已保存');
        }
      }
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
      if (e is OfficeException && e.status == 409 && _saved != null) {
        try {
          final latest = await s.getMail(str(_saved!['id']));
          if (mounted) setState(() => _latest = latest);
        } catch (_) {}
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _close() async {
    if (_dirty ||
        (_saved == null &&
            (_subject.text.isNotEmpty ||
                _body.text.isNotEmpty ||
                _to.isNotEmpty))) {
      final discard = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('离开写信？'),
          content: const Text('本次尚未保存的编辑将丢失。你也可以返回，先保存草稿。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('继续编辑'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('放弃本次编辑'),
            ),
          ],
        ),
      );
      if (discard != true) return;
    }
    if (mounted) Navigator.pop(context);
  }

  Widget _recipients(
    String label,
    List<String> values,
    void Function(List<String>) assign,
  ) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 55,
          child: Padding(
            padding: const EdgeInsets.only(top: 11),
            child: Text(
              label,
              style: const TextStyle(fontSize: 12, color: mutedColor),
            ),
          ),
        ),
        Expanded(
          child: Wrap(
            spacing: 5,
            runSpacing: 5,
            children: [
              ...values.map((id) {
                final p = s.principals
                    .where((p) => personId(p) == id)
                    .firstOrNull;
                return InputChip(
                  label: Text(
                    '${str(p?['name'], id)}${p?['kind'] == 'agent' ? ' · Agent' : ''}',
                    style: const TextStyle(fontSize: 11),
                  ),
                  onPressed: _busy
                      ? null
                      : () async {
                          final ids = await chooseOfficePeople(
                            context,
                            s,
                            selected: values,
                            title: '选择$label',
                          );
                          if (ids != null && mounted) {
                            setState(() {
                              assign(ids);
                              _dirty = true;
                            });
                          }
                        },
                  onDeleted: _busy
                      ? null
                      : () => setState(() {
                          assign(values.where((v) => v != id).toList());
                          _dirty = true;
                        }),
                  visualDensity: VisualDensity.compact,
                );
              }),
              TextButton.icon(
                onPressed: _busy
                    ? null
                    : () async {
                        final ids = await chooseOfficePeople(
                          context,
                          s,
                          selected: values,
                          title: '选择$label',
                        );
                        if (ids != null && mounted) {
                          setState(() {
                            assign(ids);
                            _dirty = true;
                          });
                        }
                      },
                icon: const Icon(Icons.add, size: 15),
                label: const Text('添加'),
              ),
            ],
          ),
        ),
      ],
    ),
  );
  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_dirty && !_busy,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop && !_busy) _close();
    },
    child: Dialog(
      insetPadding: EdgeInsets.all(
        MediaQuery.sizeOf(context).width < 600 ? 12 : 35,
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 780, maxHeight: 790),
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      '写邮件',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (_saved != null)
                    Text(
                      '草稿 r${_saved!['revision']}',
                      style: const TextStyle(fontSize: 10, color: mutedColor),
                    ),
                  IconButton(
                    onPressed: _busy ? null : _close,
                    tooltip: '关闭写信',
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '工作空间内部邮件',
                        style: TextStyle(fontSize: 11, color: mutedColor),
                      ),
                      const SizedBox(height: 15),
                      _recipients('收件人', _to, (value) => _to = value),
                      if (_extras || _cc.isNotEmpty || _bcc.isNotEmpty) ...[
                        _recipients('抄送', _cc, (value) => _cc = value),
                        _recipients('密送', _bcc, (value) => _bcc = value),
                      ] else
                        TextButton(
                          onPressed: () => setState(() => _extras = true),
                          child: const Text('抄送 / 密送'),
                        ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _subject,
                        maxLength: 300,
                        decoration: const InputDecoration(labelText: '主题'),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _body,
                        minLines: 9,
                        maxLines: 20,
                        maxLength: 100000,
                        decoration: const InputDecoration(
                          hintText: '写下需要正式沟通的内容',
                          counterText: '',
                        ),
                        style: const TextStyle(fontSize: 13, height: 1.8),
                      ),
                      BusinessError(_error),
                      if (_latest != null)
                        BusinessCard(
                          color: const Color(0xfffff8ed),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '服务器最新草稿 · r${_latest!['revision']}',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 12,
                                ),
                              ),
                              const SizedBox(height: 8),
                              SelectableText(
                                '${str(_latest!['subject'])}\n${str(_latest!['body'])}',
                                style: const TextStyle(fontSize: 12),
                              ),
                              const SizedBox(height: 12),
                              if (_latest!['status'] == 'draft')
                                TextButton(
                                  onPressed: () => setState(() {
                                    _saved = _latest;
                                    _latest = null;
                                    _error = '已采用最新版本号。请核对并合并上方内容，再保存或发送。';
                                    _dirty = true;
                                  }),
                                  child: const Text('保留我的编辑，以最新版本继续合并'),
                                )
                              else
                                const Text(
                                  '这封草稿已经发送，当前编辑仍保留在上方。',
                                  style: TextStyle(fontSize: 11),
                                ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  FilledButton.icon(
                    onPressed: _busy ? null : () => _save(true),
                    icon: const Icon(Icons.send_outlined, size: 17),
                    label: Text(_busy ? '处理中…' : '发送'),
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton(
                    onPressed: _busy ? null : () => _save(false),
                    child: const Text('保存草稿'),
                  ),
                  if (_saved != null) ...[
                    const Spacer(),
                    IconButton(
                      tooltip: '草稿移到废纸篓',
                      onPressed: _busy
                          ? null
                          : () async {
                              setState(() {
                                _busy = true;
                                _error = null;
                              });
                              try {
                                await s.moveMail(_saved!, 'trash');
                                _dirty = false;
                                if (context.mounted) Navigator.pop(context);
                              } catch (e) {
                                if (mounted) {
                                  setState(() => _error = friendlyError(e));
                                }
                              } finally {
                                if (mounted) setState(() => _busy = false);
                              }
                            },
                      icon: const Icon(Icons.delete_outline, size: 19),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
