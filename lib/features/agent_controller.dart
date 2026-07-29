// Wealth Ledger — Agent 会话控制器。
// 打开会话先拉消息快照再接 SSE：快照里已结束的助手消息以快照文本为准并忽略其
// delta；仍在进行的消息由 delta 重建。断线后按已应用的最大 cursor 续接，
// 因此重连补发不会重复拼接。
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/types.dart';
import '../data/api_mock_repositories.dart'
    show
        ApiForbiddenException,
        ApiServiceUnavailableException,
        ApiUnauthorizedException,
        ApiValidationException;
import '../data/providers.dart';
import '../data/repositories.dart';
import '../data/view_models.dart';
import 'agent_tool_labels.dart';

class AgentChatState {
  const AgentChatState({
    this.conversationId,
    this.messages = const [],
    this.cursor = 0,
    this.loading = false,
    this.loadFailed = false,
    this.streamOnline = false,
    this.activity,
    this.activeRunId,
    this.runError,
    this.sending = false,
  });

  final Id? conversationId;
  final List<AgentMessageVm> messages;

  /// 已完整应用的最大 SSE cursor；重连时从这里续接。
  final int cursor;
  final bool loading;
  final bool loadFailed;
  final bool streamOnline;

  /// 当前工具活动的用户可见说明（无内部 tool 名）。
  final String? activity;
  final Id? activeRunId;
  final String? runError;
  final bool sending;

  bool get busy => activeRunId != null;

  AgentChatState copyWith({
    Id? conversationId,
    List<AgentMessageVm>? messages,
    int? cursor,
    bool? loading,
    bool? loadFailed,
    bool? streamOnline,
    Object? activity = _keep,
    Object? activeRunId = _keep,
    Object? runError = _keep,
    bool? sending,
  }) => AgentChatState(
    conversationId: conversationId ?? this.conversationId,
    messages: messages ?? this.messages,
    cursor: cursor ?? this.cursor,
    loading: loading ?? this.loading,
    loadFailed: loadFailed ?? this.loadFailed,
    streamOnline: streamOnline ?? this.streamOnline,
    activity: activity == _keep ? this.activity : activity as String?,
    activeRunId: activeRunId == _keep ? this.activeRunId : activeRunId as Id?,
    runError: runError == _keep ? this.runError : runError as String?,
    sending: sending ?? this.sending,
  );

  static const Object _keep = Object();
}

/// 服务端 run.failed 的 code → 一句中文短提示（不外露内部标识）。
String agentRunErrorMessage(String? code) => switch (code) {
  'agent_model_not_configured' => '服务器尚未配置模型',
  'agent_run_cancelled' => '已停止本次运行',
  _ => '这次没能完成，请重试',
};

class AgentChatController extends Notifier<AgentChatState> {
  StreamSubscription<AgentEventVm>? _sub;

  /// 快照里已结束的助手消息：其正文以快照为准，忽略重放的 delta。
  final Set<Id> _finalized = {};
  bool _closed = false;

  @override
  AgentChatState build() {
    // Riverpod 会跨重建复用同一个 Notifier 实例，因此每次 build 都要把失效标记
    // 复位：否则provider 一旦重建过，之后所有 open() 都会被误判成"已销毁"
    // 而静默失败（Android 上表现为点了会话却不切换）。
    _closed = false;
    ref.onDispose(() {
      _closed = true;
      _sub?.cancel();
    });
    return const AgentChatState();
  }

  AgentRepository get _repo => ref.read(agentRepositoryProvider);

  /// 打开（或切换到）一个会话：重置状态 → 拉快照 → 接 SSE。
  Future<void> open(Id conversationId) async {
    if (_closed) return;
    // 不 await 取消：旧订阅的收尾不该挡住会话切换（真机上表现为点了没反应）。
    unawaited(_sub?.cancel() ?? Future<void>.value());
    _sub = null;
    _finalized.clear();
    if (_closed) return; // 面板已销毁：不再触碰已释放的 Ref
    state = AgentChatState(conversationId: conversationId, loading: true);
    await _loadSnapshot();
    if (_closed || state.loadFailed) return;
    _subscribe();
  }

  Future<void> reload() async {
    final id = state.conversationId;
    if (id != null) await open(id);
  }

  Future<void> _loadSnapshot() async {
    final id = state.conversationId;
    if (id == null) return;
    try {
      final messages = await _repo.listMessages(id);
      if (_closed || state.conversationId != id) return;
      final normalized = <AgentMessageVm>[];
      Id? runningRunId;
      for (final m in messages) {
        final ended =
            m.status == AgentMessageStatus.completed ||
            m.status == AgentMessageStatus.failed;
        if (m.role == AgentMessageRole.assistant && ended) {
          _finalized.add(m.id);
          normalized.add(m);
          continue;
        }
        if (m.role == AgentMessageRole.assistant) {
          // 未结束的助手消息由 delta 重建，避免与重放事件重复拼接。
          runningRunId = m.runId ?? runningRunId;
          normalized.add(m.copyWith(text: ''));
          continue;
        }
        normalized.add(m);
      }
      state = state.copyWith(
        messages: normalized,
        loading: false,
        loadFailed: false,
        activeRunId: runningRunId,
      );
    } catch (_) {
      if (_closed) return;
      state = state.copyWith(loading: false, loadFailed: true);
    }
  }

  void _subscribe() {
    final id = state.conversationId;
    if (id == null || _closed) return;
    final after = state.cursor == 0 ? null : state.cursor;
    _sub?.cancel();
    _sub = _repo
        .events(id, after: after)
        .listen(
          _apply,
          onError: (_) => _handleDisconnect(),
          onDone: _handleDisconnect,
          cancelOnError: true,
        );
    state = state.copyWith(streamOnline: true);
  }

  void _handleDisconnect() {
    if (_closed) return;
    state = state.copyWith(streamOnline: false);
  }

  /// 手动重连（断线提示上的动作）：从已应用的 cursor 之后续接。
  void reconnect() {
    if (state.streamOnline) return;
    _subscribe();
  }

  void _apply(AgentEventVm event) {
    if (_closed) return;
    switch (event.type) {
      case AgentEventType.runQueued:
        _ensurePlaceholders(event);
        state = state.copyWith(activeRunId: event.runId, runError: null);
      case AgentEventType.runStarted:
        _setStatus(event.assistantMessageId, AgentMessageStatus.streaming);
        state = state.copyWith(activeRunId: event.runId);
      case AgentEventType.messageDelta:
        _appendDelta(event.assistantMessageId, event.delta ?? '');
      case AgentEventType.toolStarted:
        state = state.copyWith(activity: agentToolLabel(event.toolName));
      case AgentEventType.toolCompleted:
        state = state.copyWith(activity: null);
      case AgentEventType.runCompleted:
        _setStatus(event.assistantMessageId, AgentMessageStatus.completed);
        if (event.assistantMessageId != null) {
          _finalized.add(event.assistantMessageId!);
        }
        state = state.copyWith(
          activeRunId: null,
          activity: null,
          runError: null,
        );
        // Agent 的账务产出只会落到既有待审核列表，这里只刷新入口计数。
        ref.invalidate(aiPendingProvider);
        ref.invalidate(overviewProvider);
      case AgentEventType.runFailed:
        _setStatus(event.assistantMessageId, AgentMessageStatus.failed);
        if (event.assistantMessageId != null) {
          _finalized.add(event.assistantMessageId!);
        }
        state = state.copyWith(
          activeRunId: null,
          activity: null,
          runError: agentRunErrorMessage(event.code),
        );
      case AgentEventType.unknown:
        break;
    }
    if (event.cursor > state.cursor) {
      state = state.copyWith(cursor: event.cursor);
    }
  }

  void _ensurePlaceholders(AgentEventVm event) {
    final id = state.conversationId;
    if (id == null) return;
    final next = [...state.messages];
    void ensure(Id? messageId, AgentMessageRole role) {
      if (messageId == null) return;
      if (next.any((m) => m.id == messageId)) return;
      next.add(
        AgentMessageVm(
          id: messageId,
          conversationId: id,
          role: role,
          text: '',
          status: AgentMessageStatus.queued,
          createdAt: '',
          runId: event.runId,
        ),
      );
    }

    ensure(event.userMessageId, AgentMessageRole.user);
    ensure(event.assistantMessageId, AgentMessageRole.assistant);
    state = state.copyWith(messages: next);
  }

  void _setStatus(Id? messageId, AgentMessageStatus status) {
    if (messageId == null) return;
    state = state.copyWith(
      messages: [
        for (final m in state.messages)
          if (m.id == messageId) m.copyWith(status: status) else m,
      ],
    );
  }

  void _appendDelta(Id? messageId, String delta) {
    if (messageId == null || delta.isEmpty) return;
    // 已结束的消息以快照/最终文本为准，重放的 delta 直接丢弃。
    if (_finalized.contains(messageId)) return;
    var found = false;
    final next = [
      for (final m in state.messages)
        if (m.id == messageId)
          () {
            found = true;
            return m.copyWith(
              text: m.text + delta,
              status: m.status == AgentMessageStatus.queued
                  ? AgentMessageStatus.streaming
                  : m.status,
            );
          }()
        else
          m,
    ];
    if (!found) return;
    state = state.copyWith(messages: next);
  }

  /// 发送一条消息。同一次点击只产生一个请求；busy 时依然允许排队。
  /// 返回 null 表示成功，否则是一句用户可见的失败说明（草稿与附件不清空）。
  Future<String?> send({
    required String text,
    List<Id> attachmentIds = const [],
  }) async {
    final id = state.conversationId;
    if (id == null || state.sending) return null;
    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;
    state = state.copyWith(sending: true, runError: null);
    try {
      final accepted = await _repo.sendMessage(
        id,
        text: trimmed,
        attachmentIds: attachmentIds,
      );
      _ensurePlaceholders(
        AgentEventVm(
          cursor: state.cursor,
          type: AgentEventType.runQueued,
          runId: accepted.runId,
          userMessageId: accepted.userMessageId,
          assistantMessageId: accepted.assistantMessageId,
        ),
      );
      // 用户消息内容本地即时可见；助手占位保持 queued 直到 SSE 推进。
      state = state.copyWith(
        messages: [
          for (final m in state.messages)
            if (m.id == accepted.userMessageId)
              m.copyWith(text: trimmed, status: AgentMessageStatus.completed)
            else
              m,
        ],
        activeRunId: accepted.runId,
      );
      return null;
    } on ApiServiceUnavailableException {
      return '服务暂时不可用，请重试';
    } on ApiUnauthorizedException {
      return '登录已失效，请重新登录后重试';
    } on ApiForbiddenException {
      return '当前账号没有该能力';
    } on ApiValidationException catch (e) {
      return e.userMessage;
    } catch (_) {
      return '发送失败，请重试';
    } finally {
      if (!_closed) state = state.copyWith(sending: false);
    }
  }

  /// 停止当前运行。
  Future<void> cancel() async {
    final runId = state.activeRunId;
    if (runId == null) return;
    try {
      await _repo.cancelRun(runId);
    } catch (_) {
      // 取消失败不改变本地状态；run.failed / run.completed 仍以服务端事件为准。
    }
  }
}

final agentChatProvider = NotifierProvider<AgentChatController, AgentChatState>(
  AgentChatController.new,
);
