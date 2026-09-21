import type { Tachyon } from '../types';

export type ActiveEngine = 'sing-box' | 'steer' | 'steer-extended';

/**
 * Whether a capability is available for the given engine. The capability names
 * mirror core/engine.uc in the backend; the UI uses them to hide or disable
 * widgets an engine cannot drive instead of showing a false "stopped".
 */
export function engineSupports(
  capabilities: string[] | undefined,
  feature: string,
): boolean {
  if (!Array.isArray(capabilities)) {
    return false;
  }
  return capabilities.includes(feature);
}

/**
 * Widgets that only sing-box can drive. On steer they must be hidden rather
 * than rendered as broken, because steer owns neither the Clash API nor the
 * sing-box inbounds.
 */
const SING_BOX_ONLY_WIDGETS = [
  'clash_connections',
  'clash_groups',
  'latency_groups',
  'sing_box_inbounds',
  'sing_box_version',
  'server_inbounds',
];

export function isWidgetAvailable(
  engine: string | undefined,
  widget: string,
): boolean {
  if (engine !== 'steer' && engine !== 'steer-extended') {
    return true;
  }
  return !SING_BOX_ONLY_WIDGETS.includes(widget);
}

/**
 * Human label for the active engine. Kept in one place so the dashboard, the
 * settings switch and the warnings dialog agree on the wording.
 */
export function engineLabel(engine: string | undefined): string {
  switch (engine) {
    case 'steer':
      return 'steer';
    case 'steer-extended':
      return 'steer-extended';
    case 'sing-box':
      return 'sing-box';
    default:
      return engine || 'sing-box';
  }
}

/**
 * The engines a user can switch to, given what the backend reported. Only known
 * engines are offered; installation is a separate step the backend validates.
 */
export function switchableEngines(
  info: Tachyon.EngineInfo | null | undefined,
): Tachyon.EngineDescriptor[] {
  if (!info || !Array.isArray(info.engines)) {
    return [];
  }
  return info.engines.filter((entry) => entry.known);
}

/**
 * Features that switching from `from` to `to` would park. The UI shows these as
 * a warning before the switch; an empty list means nothing is lost.
 */
export function parkedFeatures(
  plan: Tachyon.EngineSwitchPlan | null | undefined,
): string[] {
  if (!plan || !plan.plan || !Array.isArray(plan.plan.unsupported)) {
    return [];
  }
  return plan.plan.unsupported;
}
