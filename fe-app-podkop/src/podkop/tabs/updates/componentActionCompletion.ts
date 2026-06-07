import type { Podkop } from '../../types';

export function shouldApplyCompletedComponentActionResult(
  result: Pick<Podkop.ComponentActionResult, 'action'>,
  notify: boolean,
) {
  return result.action !== 'check_update' || notify;
}
