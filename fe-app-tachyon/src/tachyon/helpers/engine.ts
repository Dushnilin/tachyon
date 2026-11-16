export type ActiveEngine = 'tachyon-core';

/**
 * Whether a capability is available for the active core. The capability names
 * mirror core/engine.uc in the backend; the UI uses them to hide or disable
 * widgets the core cannot drive instead of showing a false "stopped".
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
 * Human label for the active engine. Kept in one place so the dashboard and
 * diagnostics views agree on the wording.
 */
export function engineLabel(_engine?: string): string {
  return 'tachyon-core';
}
