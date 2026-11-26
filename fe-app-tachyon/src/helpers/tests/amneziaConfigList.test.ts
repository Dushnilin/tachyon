import { describe, expect, it } from 'vitest';
import {
  applyAmneziaConfTextUpdate,
  applyAmneziaFileUpload,
  dedupeAmneziaEntries,
  parseAmneziaEntryMeta,
  promoteAmneziaEntryToPrimary,
  removeAmneziaEntryAt,
} from '../amneziaConfigList';
import { splitAmneziaTextEntries } from '../../validators/validateVpnUrl';

const SAMPLE_CONF_A = [
  '[Interface]',
  'PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
  'Address = 10.8.0.2/32',
  'Jc = 4',
  '[Peer]',
  'PublicKey = BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=',
  'Endpoint = 198.51.100.10:51820',
].join('\n');

const SAMPLE_CONF_B = [
  '[Interface]',
  'PrivateKey = CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC=',
  'Address = 10.8.0.3/32',
  '[Peer]',
  'PublicKey = DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD=',
  'Endpoint = 203.0.113.20:51821',
].join('\n');

describe('amneziaConfigList', () => {
  it('replaces existing config when pasting new AWG text by default', () => {
    const oldEntry = JSON.stringify({
      name: 'YOUTUBE_AWG',
      config: SAMPLE_CONF_A,
    });
    const res = applyAmneziaConfTextUpdate({
      currentConfigs: [oldEntry],
      pastedText: SAMPLE_CONF_B,
      defaultName: 'YOUTUBE_AWG',
      appendMode: false,
      splitEntries: splitAmneziaTextEntries,
    });

    expect(res.clearText).toBe(true);
    expect(res.nextConfigs).toHaveLength(1);
    const meta = parseAmneziaEntryMeta(res.nextConfigs[0], 0);
    expect(meta.endpoint).toBe('203.0.113.20:51821');
    expect(meta.protocol).toBe('WireGuard');
  });

  it('appends new config without duplicates only when appendMode is enabled', () => {
    const oldEntry = JSON.stringify({ name: 'WARP_1', config: SAMPLE_CONF_A });
    const res = applyAmneziaConfTextUpdate({
      currentConfigs: [oldEntry],
      pastedText: SAMPLE_CONF_B,
      defaultName: 'WARP_2',
      appendMode: true,
      splitEntries: splitAmneziaTextEntries,
    });

    expect(res.nextConfigs).toHaveLength(2);
    expect(parseAmneziaEntryMeta(res.nextConfigs[0], 0).endpoint).toBe(
      '198.51.100.10:51820',
    );
    expect(parseAmneziaEntryMeta(res.nextConfigs[1], 1).endpoint).toBe(
      '203.0.113.20:51821',
    );

    const dup = applyAmneziaConfTextUpdate({
      currentConfigs: res.nextConfigs,
      pastedText: SAMPLE_CONF_B,
      defaultName: 'WARP_2_DUP',
      appendMode: true,
      splitEntries: splitAmneziaTextEntries,
    });
    expect(dup.nextConfigs).toHaveLength(2);
  });

  it('keeps currentConfigs unchanged when pastedText is empty', () => {
    const oldEntry = JSON.stringify({ name: 'WARP_1', config: SAMPLE_CONF_A });
    const res = applyAmneziaConfTextUpdate({
      currentConfigs: [oldEntry],
      pastedText: '   \n  ',
      defaultName: 'WARP_1',
      appendMode: false,
      splitEntries: splitAmneziaTextEntries,
    });

    expect(res.clearText).toBe(true);
    expect(res.nextConfigs).toEqual([oldEntry]);
  });

  it('replaces on file upload by default and appends when appendMode is true', () => {
    const oldEntry = JSON.stringify({ name: 'old', config: SAMPLE_CONF_A });
    const replaced = applyAmneziaFileUpload({
      currentConfigs: [oldEntry],
      loadedFiles: [{ name: 'new_warp', config: SAMPLE_CONF_B }],
      appendMode: false,
    });
    expect(replaced).toHaveLength(1);
    expect(parseAmneziaEntryMeta(replaced[0], 0).name).toBe('new_warp');

    const appended = applyAmneziaFileUpload({
      currentConfigs: [oldEntry],
      loadedFiles: [{ name: 'new_warp', config: SAMPLE_CONF_B }],
      appendMode: true,
    });
    expect(appended).toHaveLength(2);
  });

  it('removes individual entries and promotes selected entry to primary position', () => {
    const first = JSON.stringify({ name: 'first', config: SAMPLE_CONF_A });
    const second = JSON.stringify({ name: 'second', config: SAMPLE_CONF_B });

    const promoted = promoteAmneziaEntryToPrimary([first, second], 1);
    expect(promoted).toEqual([second, first]);

    const afterRemove = removeAmneziaEntryAt(promoted, 1);
    expect(afterRemove).toEqual([second]);
    expect(removeAmneziaEntryAt(afterRemove, 0)).toEqual([]);
  });

  it('parses AmneziaWG, WireGuard and vpn:// metadata and deduplicates identical bodies', () => {
    const a1 = JSON.stringify({ name: 'one', config: SAMPLE_CONF_A });
    const a2 = JSON.stringify({ name: 'two', config: `${SAMPLE_CONF_A}\n` });
    expect(dedupeAmneziaEntries([a1, a2])).toHaveLength(1);

    expect(parseAmneziaEntryMeta(a1, 0)).toMatchObject({
      name: 'one',
      endpoint: '198.51.100.10:51820',
      protocol: 'AmneziaWG',
      isVpnLink: false,
    });
    expect(parseAmneziaEntryMeta('vpn://AAAA1234', 1)).toMatchObject({
      name: 'Amnezia #2',
      protocol: 'Amnezia (vpn://)',
      isVpnLink: true,
    });
  });
});
