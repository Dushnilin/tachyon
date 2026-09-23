import { DIAGNOSTICS_CHECKS_MAP } from './constants';
import { TachyonShellMethods } from '../../../methods';
import { updateCheckStore } from './updateCheckStore';
import { getMeta } from '../helpers/getMeta';

export async function runSteerCheck() {
  const { order, title, code } = DIAGNOSTICS_CHECKS_MAP.STEER;

  updateCheckStore({
    order,
    code,
    title,
    description: _('Checking, please wait'),
    state: 'loading',
    items: [],
  });

  const steerChecks = await TachyonShellMethods.checkSteer();

  if (!steerChecks.success) {
    updateCheckStore({
      order,
      code,
      title,
      description: _('Cannot receive checks result'),
      state: 'error',
      items: [],
    });

    throw new Error('Steer checks failed');
  }

  const data = steerChecks.data;

  // Backend returns not_applicable when sing-box is the active engine
  if ((data as { not_applicable?: number }).not_applicable) {
    updateCheckStore({
      order,
      code,
      title,
      description: _('Not applicable for current engine'),
      state: 'skipped',
      items: [],
    });
    return;
  }

  const allGood =
    Boolean(data.steer_installed) &&
    Boolean(data.steer_service_exist) &&
    Boolean(data.steer_autostart_enabled) &&
    Boolean(data.steer_process_running);

  const atLeastOneGood =
    Boolean(data.steer_installed) ||
    Boolean(data.steer_service_exist) ||
    Boolean(data.steer_autostart_enabled) ||
    Boolean(data.steer_process_running);

  const { state, description } = getMeta({ atLeastOneGood, allGood });

  const versionSuffix = data.steer_version ? ` ${data.steer_version}` : '';
  const variantLabel = data.steer_extended ? ` (${_('extended')})` : '';

  updateCheckStore({
    order,
    code,
    title,
    description,
    state,
    items: [
      {
        state: data.steer_installed ? 'success' : 'error',
        key: _('Steer installed') + versionSuffix + variantLabel,
        value: '',
      },
      {
        state: data.steer_service_exist ? 'success' : 'error',
        key: _('Steer service exist'),
        value: '',
      },
      {
        state: data.steer_autostart_enabled ? 'success' : 'error',
        key: _('Steer autostart enabled'),
        value: '',
      },
      {
        state: data.steer_process_running ? 'success' : 'error',
        key: _('Steer process running'),
        value: '',
      },
    ],
  });

  if (!atLeastOneGood || !data.steer_process_running) {
    throw new Error('Steer checks failed');
  }
}
