// Wealth Ledger — Agent 全屏页（移动端）。返回键直接退回上一页。
import 'package:flutter/material.dart';

import '../shared/widgets.dart';
import 'agent_panel.dart';

class AgentPage extends StatelessWidget {
  const AgentPage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('助手')),
    body: const SafeArea(child: ContentMaxWidth(child: AgentPanel())),
  );
}
