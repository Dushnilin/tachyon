/**
 * Formats and localizes backend service status messages (zapret, zapret2, byedpi, tailscale)
 * into localized, user-friendly messages for the LuCI dashboard.
 */
export function formatServiceStatusMessage(msg: string): string {
  if (!msg) return '';

  const normalMatch = msg.match(/^([a-zA-Z0-9_-]+) provider status is normal$/);
  if (normalMatch) {
    const provider = normalMatch[1];
    return `${_('Provider status is normal')}: ${provider}`;
  }

  const notReadyWithDetailMatch = msg.match(
    /^action=([^ ]+) is configured, but the Tachyon-managed ([^ ]+) runtime is not ready \((.+)\)$/,
  );
  if (notReadyWithDetailMatch) {
    const [, action, bin, detail] = notReadyWithDetailMatch;
    return `${_('Action is configured, but runtime is not ready')} (${action} -> ${bin}): ${detail}`;
  }

  const notReadyMatch = msg.match(
    /^action=([^ ]+) is configured, but the Tachyon-managed ([^ ]+) runtime is not ready$/,
  );
  if (notReadyMatch) {
    const [, action, bin] = notReadyMatch;
    return `${_('Action is configured, but runtime is not ready')} (${action} -> ${bin})`;
  }

  const notAvailablePathMatch = msg.match(
    /^action=([^ ]+) is configured, but (.+) (?:provider|ciadpi) is not available at (.+)$/,
  );
  if (notAvailablePathMatch) {
    const [, action, provider, path] = notAvailablePathMatch;
    return `${_('Action is configured, but binary is not available')} (${action} -> ${provider}): ${path}`;
  }

  const overlapMatch = msg.match(
    /^external NFQUEUE rules overlap with the Tachyon (.+) range (.+)$/,
  );
  if (overlapMatch) {
    const [, provider, range] = overlapMatch;
    return `${_('External NFQUEUE rules overlap with Tachyon')} ${provider} (${range})`;
  }

  if (
    msg ===
    'legacy zapret runtime paths are still present and should be migrated'
  ) {
    return _(
      'Legacy zapret runtime paths are still present and should be migrated',
    );
  }

  const unexpectedProcessesMatch = msg.match(
    /^unexpected Tachyon-managed ([^ ]+) processes are running without matching action=([^ ]+) rules$/,
  );
  if (unexpectedProcessesMatch) {
    const [, bin, action] = unexpectedProcessesMatch;
    return `${_('Unexpected background processes')} (${bin}, action=${action})`;
  }

  if (msg.startsWith('standalone ')) {
    return _(
      'Standalone service is active alongside Tachyon; policy or port conflicts are possible',
    );
  }

  const packageInstalledNoBinMatch = msg.match(
    /^(.+) package is installed, but (?:the provider binary|ciadpi) is not available at (.+)$/,
  );
  if (packageInstalledNoBinMatch) {
    const [, provider, path] = packageInstalledNoBinMatch;
    return `${_('Package is installed, but binary missing')} (${provider}): ${path}`;
  }

  const notInstalledMatch = msg.match(
    /^(.+) (?:provider|package) is not installed; (?:action=([^ ]+) is unavailable|native Tailscale is unavailable)$/,
  );
  if (notInstalledMatch) {
    const [, provider, action] = notInstalledMatch;
    return `${_('Package is not installed')} (${provider})${action ? `: action=${action} ${_('is unavailable')}` : ''}`;
  }

  if (msg.includes('ciadpi has restarted after exiting')) {
    return _(
      'ByeDPI restarted after exiting; strategy or traffic load may be unstable',
    );
  }

  if (
    msg.includes(
      'native Tailscale is configured, but the tailscale package is missing',
    )
  ) {
    return _(
      'Native Tailscale is configured, but tailscale package is missing',
    );
  }
  if (
    msg.includes(
      'native Tailscale is configured, but tailscaled is not running',
    )
  ) {
    return _(
      'Native Tailscale is configured, but tailscaled is not running for every section',
    );
  }
  if (msg.includes('no server section uses native mode')) {
    return _(
      'Tailscale package is installed, but no server section uses native mode',
    );
  }

  return _(msg);
}
