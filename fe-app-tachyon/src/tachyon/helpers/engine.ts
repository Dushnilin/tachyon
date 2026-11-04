import type { Tachyon } from '../types';

export type ActiveEngine = 'tachyon-core' | 'sing-box';

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

export function isWidgetAvailable(
  _engine: string | undefined,
  _widget: string,
): boolean {
  return true;
}

/**
 * Human label for the active engine. Kept in one place so the dashboard, the
 * settings switch and the warnings dialog agree on the wording.
 */
export function engineLabel(engine: string | undefined): string {
  switch (engine) {
    case 'tachyon-core':
      return 'tachyon-core';
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
