import 'package:flutter/material.dart';

import 'office_theme.dart';

class OfficeLogin extends StatefulWidget {
  const OfficeLogin({
    super.key,
    required this.onConnect,
    required this.endpoint,
  });
  final Future<void> Function(String endpoint, String token) onConnect;
  final String endpoint;
  @override
  State<OfficeLogin> createState() => _OfficeLoginState();
}

class _OfficeLoginState extends State<OfficeLogin> {
  late final TextEditingController _endpoint = TextEditingController(
    text: widget.endpoint,
  );
  final _token = TextEditingController();
  final _form = GlobalKey<FormState>();
  bool _busy = false;
  String? _error;
  @override
  void dispose() {
    _endpoint.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    if (_busy || !_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onConnect(_endpoint.text.trim(), _token.text.trim());
      if (mounted) _token.clear();
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final desktop = constraints.maxWidth > 850;
          return Row(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  child: Center(
                    child: Container(
                      constraints: const BoxConstraints(maxWidth: 440),
                      padding: const EdgeInsets.all(35),
                      child: Form(
                        key: _form,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              width: 44,
                              height: 44,
                              decoration: BoxDecoration(
                                color: accentColor,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: const Center(
                                child: Text(
                                  '＝',
                                  style: TextStyle(
                                    fontSize: 32,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 28),
                            const Text(
                              '同席',
                              style: TextStyle(
                                fontSize: 31,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 2,
                              ),
                            ),
                            const SizedBox(height: 7),
                            const Text(
                              'Active Agent · 原生办公协作',
                              style: TextStyle(fontSize: 12, color: mutedColor),
                            ),
                            const SizedBox(height: 38),
                            const Text(
                              '进入你的工作空间',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 9),
                            const Text(
                              '人和 Agent 共享会话、任务与工作文档。',
                              style: TextStyle(fontSize: 12, color: mutedColor),
                            ),
                            const SizedBox(height: 27),
                            const Text(
                              '工作空间地址',
                              style: TextStyle(fontSize: 12),
                            ),
                            const SizedBox(height: 8),
                            TextFormField(
                              controller: _endpoint,
                              keyboardType: TextInputType.url,
                              autocorrect: false,
                              decoration: const InputDecoration(
                                hintText: 'https://your-workspace.example',
                              ),
                              validator: (v) =>
                                  Uri.tryParse(v?.trim() ?? '')?.hasScheme ==
                                      true
                                  ? null
                                  : '请输入完整工作空间地址',
                            ),
                            const SizedBox(height: 20),
                            const Text(
                              '个人访问令牌',
                              style: TextStyle(fontSize: 12),
                            ),
                            const SizedBox(height: 8),
                            TextFormField(
                              controller: _token,
                              obscureText: true,
                              autocorrect: false,
                              enableSuggestions: false,
                              decoration: const InputDecoration(
                                hintText: '使用自己的工作身份进入',
                              ),
                              validator: (v) => v?.trim().isNotEmpty == true
                                  ? null
                                  : '请输入个人访问令牌',
                              onFieldSubmitted: (_) => _connect(),
                            ),
                            if (_error != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 13),
                                child: Text(
                                  _error!,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: Colors.redAccent,
                                  ),
                                ),
                              ),
                            const SizedBox(height: 25),
                            SizedBox(
                              width: double.infinity,
                              child: FilledButton(
                                onPressed: _busy ? null : _connect,
                                child: _busy
                                    ? const SizedBox(
                                        width: 17,
                                        height: 17,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const Text('进入工作空间'),
                              ),
                            ),
                            const SizedBox(height: 21),
                            const Text(
                              '请向工作空间管理员获取个人令牌。\n个人与 Agent 使用独立身份，令牌仅用于当前会话。',
                              style: TextStyle(
                                fontSize: 11,
                                color: mutedColor,
                                height: 1.8,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              if (desktop)
                Expanded(
                  child: Container(
                    margin: const EdgeInsets.fromLTRB(0, 24, 24, 24),
                    decoration: BoxDecoration(
                      color: const Color(0xffe2e9fc),
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: 280,
                            height: 225,
                            child: Stack(
                              alignment: Alignment.center,
                              children: [
                                Container(
                                  width: 220,
                                  height: 220,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: const Color(0xffc9d5f5),
                                    ),
                                  ),
                                ),
                                Transform.rotate(
                                  angle: -.08,
                                  child: Container(
                                    width: 146,
                                    height: 160,
                                    padding: const EdgeInsets.all(20),
                                    decoration: BoxDecoration(
                                      color: Colors.white,
                                      borderRadius: BorderRadius.circular(12),
                                      boxShadow: const [
                                        BoxShadow(
                                          color: Color(0x183370ff),
                                          blurRadius: 30,
                                          offset: Offset(0, 12),
                                        ),
                                      ],
                                    ),
                                    child: const Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Icon(
                                          Icons.description_outlined,
                                          color: accentColor,
                                          size: 32,
                                        ),
                                        SizedBox(height: 18),
                                        Text(
                                          '共同文档',
                                          style: TextStyle(
                                            fontSize: 17,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        SizedBox(height: 9),
                                        Text(
                                          '工作，从这里向前',
                                          style: TextStyle(
                                            fontSize: 9,
                                            color: mutedColor,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                const Positioned(
                                  left: 9,
                                  top: 16,
                                  child: PersonAvatar(name: '人', size: 51),
                                ),
                                const Positioned(
                                  right: 4,
                                  bottom: 15,
                                  child: PersonAvatar(
                                    name: 'Agent',
                                    agent: true,
                                    size: 51,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 35),
                          const Text(
                            '让讨论，长出成果。',
                            style: TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 15),
                          const Text(
                            '消息连接彼此，文档承载共识。\n每一位成员，都能提出、参与和交付。',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 12,
                              color: Color(0xff8c99b4),
                              height: 1.9,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    ),
  );
}
