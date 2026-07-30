// Wealth Ledger — 报价刷新结果的用户可见文案。
// 服务端 message 是英文实现细节（例如 instrument has no public-provider symbol），
// 只能出现在低强调详情里；主界面与 Snackbar 一律用这里的短中文。
import '../data/view_models.dart';

/// 单条失败 → 短中文。目标币种取自接口返回的 targetId（BASE/QUOTE），不硬编码。
String quoteRefreshErrorText(QuoteRefreshErrorVm error) {
  final message = error.message.toLowerCase();
  final missingSymbol =
      message.contains('symbol') &&
      (message.contains('no ') || message.contains('missing'));
  if (error.targetType == 'fx_pair') {
    final target = _fxTargetCurrency(error.targetId);
    return target == null ? '暂时无法完成换算' : '暂时无法换算为 $target';
  }
  if (error.targetType == 'instrument') {
    return missingSymbol ? '无法识别该资产' : '暂时没有可用报价';
  }
  return '刷新失败，请重试';
}

/// `BTC/CNY` → `CNY`；形状不符时返回 null，由调用方退化成不带币种的文案。
String? _fxTargetCurrency(String? targetId) {
  final raw = targetId?.trim() ?? '';
  if (raw.isEmpty) return null;
  final parts = raw.split('/');
  if (parts.length != 2) return null;
  final quote = parts[1].trim();
  return quote.isEmpty ? null : quote;
}

/// 整次刷新的一句话结果。有失败时只带第一条的短中文，绝不带服务端英文。
String quoteRefreshResultText(QuoteRefreshResultVm result) {
  final summary = '${result.quoteCount} 项行情 / ${result.fxRateCount} 项汇率';
  final first = result.errorDetails.isEmpty
      ? null
      : quoteRefreshErrorText(result.errorDetails.first);
  final suffix = first == null ? '' : '：$first';
  return switch (result.status) {
    'success' =>
      result.errorDetails.isEmpty ? '报价已刷新：$summary' : '报价已刷新，部分项目待补$suffix',
    'partial_success' => '部分报价未刷新，继续使用缓存$suffix',
    'offline' => '当前离线或暂无行情来源$suffix',
    'failed' => '报价刷新失败$suffix',
    _ => result.hasProblems ? '报价刷新完成但有待补项$suffix' : '报价已刷新：$summary',
  };
}

/// 刷新抛异常（网络/鉴权等）时的一句话；不拼接异常原文。
const String kQuoteRefreshFailureText = '报价刷新失败，请重试';

/// 低强调详情里的一行：短中文 + 目标标识；服务端英文只在这里出现。
String quoteRefreshErrorDetailText(QuoteRefreshErrorVm error) {
  final target = error.targetId;
  final head = target == null || target.isEmpty
      ? quoteRefreshErrorText(error)
      : '${quoteRefreshErrorText(error)}（$target）';
  return error.message.isEmpty ? head : '$head\n${error.message}';
}
