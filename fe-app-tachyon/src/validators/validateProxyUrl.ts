import { ValidationResult } from './types';
import { validateShadowsocksUrl } from './validateShadowsocksUrl';
import { validateVlessUrl } from './validateVlessUrl';
import { validateVmessUrl } from './validateVmessUrl';
import { validateTrojanUrl } from './validateTrojanUrl';
import { validateSocksUrl } from './validateSocksUrl';
import { validateHysteria2Url } from './validateHysteriaUrl';
import { validateTuicUrl } from './validateTuicUrl';
import { validateHttpProxyUrl } from './validateHttpProxyUrl';

/**
 * Scheme dispatch, longest prefix first so that a longer scheme can never be
 * swallowed by a shorter one. Adding a protocol is one row.
 */
const DISPATCH: {
  prefixes: string[];
  validate: (url: string) => ValidationResult;
}[] = [
  { prefixes: ['ss://'], validate: validateShadowsocksUrl },
  { prefixes: ['vless://'], validate: validateVlessUrl },
  { prefixes: ['vmess://'], validate: validateVmessUrl },
  { prefixes: ['trojan://'], validate: validateTrojanUrl },
  {
    prefixes: ['socks4://', 'socks4a://', 'socks5://'],
    validate: validateSocksUrl,
  },
  { prefixes: ['http://', 'https://'], validate: validateHttpProxyUrl },
  { prefixes: ['hysteria2://', 'hy2://'], validate: validateHysteria2Url },
  { prefixes: ['tuic://'], validate: validateTuicUrl },
];

/**
 * Routes a pasted share link to its scheme validator.
 *
 * Input is untrusted. The scheme match is case-sensitive on purpose: share
 * links are generated in lower case, and accepting "SS://" would let a
 * lookalike through a filter that only lowercases one side. No prefix here
 * overlaps another, so ordering only matters for readability.
 */
export function validateProxyUrl(url: string): ValidationResult {
  const trimmedUrl = url.trim();

  for (const { prefixes, validate } of DISPATCH) {
    for (const prefix of prefixes) {
      if (trimmedUrl.startsWith(prefix)) {
        return validate(trimmedUrl);
      }
    }
  }

  return {
    valid: false,
    message: _(
      'URL must start with vless://, vmess://, ss://, trojan://, socks4://, socks4a://, socks5://, http://, https://, hysteria2://, hy2://, or tuic://',
    ),
  };
}
