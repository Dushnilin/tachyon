export interface SubscriptionJobTargetLike {
  section?: string;
  source_selector?: string;
  source_index?: string;
  resolved_target?: string;
}

export function getSubscriptionUpdateTargetKey(
  sectionName: string,
  selector?: number | string,
): string {
  const sec = String(sectionName || '').trim();
  const sel =
    selector === undefined || selector === null ? '' : String(selector).trim();
  if (!sec || !sel) {
    return '';
  }

  return `${sec}::${sel}`;
}

export function getSubscriptionJobTargetSelector(
  state?: SubscriptionJobTargetLike,
): string {
  if (!state) {
    return '';
  }

  const section = String(state.section || '').trim();
  const sourceSelector = String(state.source_selector || '').trim();
  if (sourceSelector) {
    return sourceSelector;
  }

  const sourceIndex = String(state.source_index || '').trim();
  if (sourceIndex) {
    return sourceIndex;
  }

  const resolvedTarget = String(state.resolved_target || '').trim();
  if (
    resolvedTarget &&
    (!section || resolvedTarget.toLowerCase() !== section.toLowerCase())
  ) {
    return resolvedTarget;
  }

  return '';
}

export function isSubscriptionTargetUpdating(
  sectionName: string,
  updatingTargets?: Record<string, boolean>,
  sourceIndex?: number,
  sourceId?: string,
): boolean {
  if (!updatingTargets || !sectionName) {
    return false;
  }

  const trimmedSourceId = typeof sourceId === 'string' ? sourceId.trim() : '';
  if (trimmedSourceId) {
    const idKey = getSubscriptionUpdateTargetKey(sectionName, trimmedSourceId);
    if (idKey && updatingTargets[idKey]) {
      return true;
    }
  }

  if (typeof sourceIndex === 'number' && sourceIndex > 0) {
    const idxKey = getSubscriptionUpdateTargetKey(sectionName, sourceIndex);
    if (idxKey && updatingTargets[idxKey]) {
      return true;
    }
  }

  return false;
}
