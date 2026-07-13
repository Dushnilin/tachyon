import type { Tachyon } from '../../types';

export function shouldApplyCompletedComponentActionResult(
  result: Pick<Tachyon.ComponentActionResult, 'action'>,
  notify: boolean,
) {
  return result.action !== 'check_update' || notify;
}
