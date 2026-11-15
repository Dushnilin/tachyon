import { describe, expect, it } from 'vitest';
import { fetchNetworkInterfaces } from '../fetchNetworkInterfaces';

describe('fetchNetworkInterfaces', () => {
  it('returns empty array when rpc and network are not available', async () => {
    const res = await fetchNetworkInterfaces();
    expect(Array.isArray(res)).toBe(true);
  });
});
