/// Shared limit/offset pagination contract for all list tools (issue #31).
///
/// Every list tool accepts `limit` (default [listDefaultLimit], at most
/// [listMaxLimit]) and `offset` (default 0). Values outside the declared
/// range are rejected by the catalog input schema before dispatch
/// (INVALID_ARGUMENT); the helpers below clamp defensively so direct
/// callback invocations that bypass `gcm_call` still behave sanely.
///
/// Responses carry a uniform envelope alongside the item list:
/// `total` (items after filtering), `returned` (items on this page),
/// `hasMore`, and `nextOffset` (null when there is no next page).
library;

/// Default page size for list tools.
const listDefaultLimit = 50;

/// Maximum accepted page size; larger values are rejected by the input
/// schema (INVALID_ARGUMENT) rather than silently clamped.
const listMaxLimit = 500;

/// How many identifier previews a list summary may show before folding the
/// rest behind an ellipsis.
const listSummaryPreviewCount = 5;

/// Parsed `limit`/`offset` pair for one list call.
typedef ListPageArguments = ({int limit, int offset});

/// Reads `limit`/`offset` from tool arguments, applying the shared defaults
/// and defensive clamps (schema validation enforces the real bounds).
ListPageArguments listPageArguments(Map<String, Object?> args) {
  final limit = args['limit'];
  final offset = args['offset'];
  return (
    limit: limit is int ? limit.clamp(1, listMaxLimit) : listDefaultLimit,
    offset: offset is int && offset > 0 ? offset : 0,
  );
}

/// Returns the page of [items] selected by [limit]/[offset] (possibly empty).
List<T> listPageSlice<T>(
  List<T> items, {
  required int limit,
  required int offset,
}) {
  if (offset >= items.length) return <T>[];
  final end = offset + limit;
  return items.sublist(offset, end > items.length ? items.length : end);
}

/// Builds the uniform pagination envelope for a page.
Map<String, Object?> listPageEnvelope({
  required int total,
  required int returned,
  required int offset,
}) {
  final hasMore = offset + returned < total;
  return <String, Object?>{
    'total': total,
    'returned': returned,
    'hasMore': hasMore,
    'nextOffset': hasMore ? offset + returned : null,
  };
}

/// Formats up to [listSummaryPreviewCount] identifier previews for a list
/// summary. Returns an empty string when there is nothing to preview,
/// otherwise `'：a、b、c'` (or with a trailing `'、…'` when more items exist
/// on the page than were previewed).
String listSummaryPreview(Iterable<String> identifiers) {
  final list = identifiers.toList(growable: false);
  if (list.isEmpty) return '';
  final preview = list.take(listSummaryPreviewCount).join('、');
  final folded = list.length > listSummaryPreviewCount ? '、…' : '';
  return '：$preview$folded';
}
