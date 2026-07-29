// Wealth Ledger — Agent 工具事件的用户可见文案。
// 只把已知工具映射成一句活动说明；未知工具统一回落，不显示内部标识。
const Map<String, String> _knownToolLabels = {
  'finwealth_query': '正在读取数据…',
  'finwealth_propose_movement': '正在整理记录…',
  'finwealth_refresh_quotes': '正在刷新估值…',
  'finwealth_suggest_memory': '正在整理偏好…',
  'finwealth_suggest_quote': '正在整理报价…',
  'finwealth_propose_holding_snapshot': '正在整理持仓…',
  'finwealth_lookup_quote_candidate': '正在查询报价…',
  'finwealth_lookup_fx_candidate': '正在查询汇率…',
};

/// 会写入报价/汇率候选的工具：完成后值得立刻重新读取候选列表。
const Set<String> _quoteCandidateTools = {
  'finwealth_lookup_quote_candidate',
  'finwealth_lookup_fx_candidate',
  'finwealth_suggest_quote',
};

bool agentToolMayCreateQuoteCandidate(String? toolName) =>
    toolName != null && _quoteCandidateTools.contains(toolName);

/// 会写入待审核候选的工具：完成后值得立刻重新读取待审核列表。
const Set<String> _pendingReviewTools = {
  'finwealth_propose_movement',
  'finwealth_propose_holding_snapshot',
};

bool agentToolMayCreatePendingReview(String? toolName) =>
    toolName != null && _pendingReviewTools.contains(toolName);

String agentToolLabel(String? toolName) =>
    _knownToolLabels[toolName] ?? '正在处理…';
