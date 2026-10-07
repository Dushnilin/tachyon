const MASKED_VALUE = '*******';

const SING_BOX_MASKED_KEYS = new Set([
  'auth_key',
  'control_url',
  'exit_node',
  'hostname',
  'listen',
  'listen_port',
  'username',
  'uuid',
  'server',
  'server_name',
  'secret',
  'password',
  'private_key',
  'public_key',
  'short_id',
  'fingerprint',
  'server_port',
  'server_ports',
  'advertise_routes',
  'domain',
  'domain_suffix',
  'domain_keyword',
  'domain_regex',
  'ip_cidr',
  'source_ip_cidr',
]);

const TACHYON_MASK_AFTER_TOKEN = [
  'option proxy_string',
  'option hwid',
  'option subscription_url',
  'list subscription_urls',
  'list urltest_proxy_links',
  'list selector_proxy_links',
  'list server_users',
  'option server_uuid',
  'option server_username',
  'option server_password',
  'option mtproto_secret',
  'option hysteria2_obfs_password',
  'option reality_private_key',
  'option reality_public_key',
  'option reality_short_id',
  'list reality_short_id',
  'option yacd_secret_key',
];

const TACHYON_MASK_AFTER_TOKEN_SPACE = [
  'option outbound_json',
  'list domain',
  'list domain_suffix',
  'list domain_keyword',
  'list domain_regex',
  'list ip_cidr',
  'list source_ip_cidr',
  'list fully_routed_ips',
  'list excluded_ips',
  'option dns_server',
  'option bootstrap_dns_server',
  'list dns_server',
  'list bootstrap_dns_server',
  'option dns_mtls_client_certificate',
  'option dns_mtls_client_key',
  'option dns_mtls_ca',
  'option dns_mtls_certificate',
  'option dns_mtls_endpoint',
  'option listen',
  'option listen_port',
  'option public_host',
  'option mtproto_faketls',
  'option mtproto_domain_fronting_ip',
  'option tls_server_name',
  'option reality_handshake_server',
  'option reality_handshake_server_port',
  'option transport_host',
  'list transport_hosts',
  'option tailscale_auth_key',
  'option tailscale_control_url',
  'option tailscale_hostname',
  'list tailscale_advertise_routes',
  'option tailscale_ephemeral',
  'option tailscale_exit_node',
  'option tailscale_exit_node_allow_lan_access',
  'option mixed_proxy_username',
  'option mixed_proxy_password',
  'option ai_doctor_api_key',
  'option tuic_password',
  'option ipaddr',
  'option netmask',
  'option gateway',
  'option username',
  'option password',
  'option private_key',
  'option awg_private_key',
  'option bot_token',
  'option agent_api_token',
  'option admin_ids',
  'option url',
  'option warp_private_key',
  'option warp_access_token',
  'option masque_private_key',
  'option masque_access_token',
  'option openvpn_password',
  'option openvpn_key',
  'option openvpn_cert',
  'option openvpn_ca',
  'option user_agent',
  'option hwid_token',
  'option anytls_sni',
  'option sni',
  'option transport_path',
];

function isRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === 'object' && !Array.isArray(value);
}

function isSpaceChar(value: string) {
  return value === ' ' || value === '\t' || value === '\r' || value === '\n';
}

function maskAfterToken(line: string, token: string) {
  const position = line.indexOf(token);

  return position < 0
    ? line
    : `${line.slice(0, position)}${token} '${MASKED_VALUE}'`;
}

function maskAfterTokenSpace(line: string, token: string) {
  const position = line.indexOf(token);

  if (position < 0) {
    return line;
  }

  const spacePosition = position + token.length;

  if (
    spacePosition >= line.length ||
    !isSpaceChar(line.slice(spacePosition, spacePosition + 1))
  ) {
    return line;
  }

  return `${line.slice(0, spacePosition + 1)}'${MASKED_VALUE}'`;
}

function maskOptionPath(line: string, token: string) {
  const position = line.indexOf(token);

  if (position < 0) {
    return line;
  }

  const slashOffset = line.slice(position + token.length).indexOf('/');

  if (slashOffset < 0) {
    return line;
  }

  const slash = slashOffset + position + token.length;
  const quoteOffset = line.slice(slash + 1).indexOf("'");

  if (quoteOffset < 0) {
    return line;
  }

  const quote = quoteOffset + slash + 1;

  return `${line.slice(0, slash)}/*******'${line.slice(quote + 1)}`;
}

function maskGlobalCheckLine(line: string) {
  let maskedLine = line;

  for (const token of TACHYON_MASK_AFTER_TOKEN) {
    maskedLine = maskAfterToken(maskedLine, token);
  }

  for (const token of TACHYON_MASK_AFTER_TOKEN_SPACE) {
    maskedLine = maskAfterTokenSpace(maskedLine, token);
  }

  maskedLine = maskOptionPath(maskedLine, "option dns_server '");
  maskedLine = maskOptionPath(maskedLine, "list dns_server '");
  return maskedLine;
}

function maskMultilineContinuation(line: string) {
  const leadingSpace = line.match(/^\s*/)?.[0] ?? '';
  const hasClosingQuote = line.includes("'");

  return `${leadingSpace}${MASKED_VALUE}${hasClosingQuote ? "'" : ''}`;
}

export function maskSingBoxConfigValue(value: unknown): unknown {
  if (Array.isArray(value)) {
    return value.map((item) => maskSingBoxConfigValue(item));
  }

  if (isRecord(value)) {
    return Object.fromEntries(
      Object.entries(value).map(([key, item]) => [
        key,
        SING_BOX_MASKED_KEYS.has(key)
          ? MASKED_VALUE
          : maskSingBoxConfigValue(item),
      ]),
    );
  }

  return value;
}

export function stringifySingBoxConfig(value: unknown) {
  return typeof value === 'string' ? value : JSON.stringify(value, null, 2);
}

export function formatMaskedSingBoxConfig(value: unknown) {
  if (typeof value === 'string') {
    try {
      return JSON.stringify(maskSingBoxConfigValue(JSON.parse(value)), null, 2);
    } catch (_error) {
      return value;
    }
  }

  return JSON.stringify(maskSingBoxConfigValue(value), null, 2);
}

export function maskGlobalCheckText(text: string = '') {
  let inMaskedMultiline = false;

  return `${text}`
    .split('\n')
    .map((line) => {
      if (inMaskedMultiline) {
        if (line.includes("'")) {
          inMaskedMultiline = false;
        }

        return maskMultilineContinuation(line);
      }

      const maskedLine = maskGlobalCheckLine(line);

      if (line.includes('option outbound_json')) {
        const firstQuote = line.indexOf("'");

        if (firstQuote >= 0 && line.slice(firstQuote + 1).indexOf("'") < 0) {
          inMaskedMultiline = true;
        }
      }

      return maskedLine;
    })
    .join('\n');
}

// Hostnames, addresses and URLs in syslog lines identify the user's provider
// infrastructure (a node shows up as `host:port` in every sing-box dial/TLS
// line) and the sites they browse. maskGlobalCheckText cannot help there: it
// only rewrites UCI `option`/`list` tokens, and log lines have none.
const LOG_URL = /[a-z][a-z0-9+.-]*:\/\/\S+/gi;
// A host is a dotted name whose last label starts with a letter, a dotted
// quad, or localhost. The alphabetic TLD is what keeps version strings
// (1.14.2-lx.8) and clock times (10:00:27) intact.
const LOG_HOST =
  '[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\\.[a-z0-9-]+)*\\.[a-z][a-z0-9-]*|\\d{1,3}(?:\\.\\d{1,3}){3}|localhost';
const LOG_HOST_PORT = new RegExp(`(${LOG_HOST})(:\\d{1,5})`, 'gi');
// `<facility>.<priority>` is syslog framing, not a host: `daemon.err` and
// `user.notice` name the facility and severity that produced the line, which is
// exactly the part a bug report needs. Refusing the match at the start of the
// token is enough — the lookbehind already rejects every later start position,
// so the tag cannot be re-entered one character in.
const LOG_SYSLOG_TAG =
  '(?:daemon|user|kern|kernel|local\\d*|auth|authpriv|cron|mail|news|syslog|ftp)\\.(?:emerg|alert|crit|err|error|warn|warning|notice|info|debug)\\b';
const LOG_BARE_HOST = new RegExp(
  `(?<![/\\w.-])(?!${LOG_SYSLOG_TAG})(${LOG_HOST})(?![/\\w-])`,
  'gi',
);

function maskLogLine(line: string) {
  return line
    .replace(LOG_URL, '*******')
    .replace(LOG_HOST_PORT, '*******$2')
    .replace(LOG_BARE_HOST, '*******');
}

export function maskLogText(text: string = '') {
  return `${text}`.split('\n').map(maskLogLine).join('\n');
}
