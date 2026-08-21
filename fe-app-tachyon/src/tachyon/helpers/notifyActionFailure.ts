import { logger } from '../services/logger.service';
import { showToast } from '../../helpers/showToast';

type FailureLike = {
  message?: string;
  error?: string;
  stderr?: string;
  data?: { error?: unknown } | unknown;
};

function extractMessage(response: unknown): string | null {
  if (!response || typeof response !== 'object') {
    return null;
  }

  const record = response as Record<string, unknown>;
  for (const key of ['error', 'message', 'stderr']) {
    const value = record[key];
    if (typeof value === 'string' && value.trim() !== '') {
      return value.trim();
    }
  }

  const data = record.data;
  if (data && typeof data === 'object') {
    const dataError = (data as Record<string, unknown>).error;
    if (typeof dataError === 'string' && dataError.trim() !== '') {
      return dataError.trim();
    }
  }

  return null;
}

// Diagnostic actions used to fail silently: the spinner stopped and nothing
// told the user why. Every failed shell-backed action should route through
// this helper so the failure is both logged and surfaced as a toast.
export function notifyActionFailure(
  context: string,
  response: unknown,
  fallbackLabel?: string,
) {
  logger.error('[DIAGNOSTIC]', context, response);

  const detail = extractMessage(response);
  showToast(
    (fallbackLabel ?? _('Action failed')) + (detail ? ': ' + detail : ''),
    'error',
  );
}
