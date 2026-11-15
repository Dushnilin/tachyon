// Session-lifetime job-tracking collections grow by one entry per backend
// job; on a long-lived LuCI tab nothing pruned them. Cap oldest entries away
// once a collection exceeds the limit - the backend cleans its own state, so
// old ids never reappear.
const DEFAULT_MAX_ENTRIES = 500;

export function capSetSize<T>(set: Set<T>, max = DEFAULT_MAX_ENTRIES): void {
  while (set.size > max) {
    const oldest = set.values().next().value;
    if (oldest === undefined) {
      return;
    }
    set.delete(oldest);
  }
}

export function capMapSize<K, V>(
  map: Map<K, V>,
  max = DEFAULT_MAX_ENTRIES,
): void {
  while (map.size > max) {
    const oldest = map.keys().next().value;
    if (oldest === undefined) {
      return;
    }
    map.delete(oldest);
  }
}
