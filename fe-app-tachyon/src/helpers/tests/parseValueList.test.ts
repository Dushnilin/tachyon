import { describe, expect, it } from 'vitest';
import { parseValueList } from '../parseValueList';

describe('parseValueList', () => {
  it('handles empty and null values gracefully', () => {
    expect(parseValueList('')).toEqual([]);
    expect(parseValueList(null)).toEqual([]);
    expect(parseValueList(undefined)).toEqual([]);
    expect(parseValueList([])).toEqual([]);
  });

  it('parses comma-separated and space-separated values', () => {
    expect(parseValueList('example.com, test.org sub.net')).toEqual([
      'example.com',
      'test.org',
      'sub.net',
    ]);
  });

  it('strips full-line and inline // comments', () => {
    const input = `
// ====== Xiaomi ======
xiaomi.com // main portal
mi.com
# Russian comment
4pda.to # tech forum
`;
    expect(parseValueList(input)).toEqual(['xiaomi.com', 'mi.com', '4pda.to']);
  });

  it('preserves proxy URLs with protocol schemes (://) and hash fragments (#node)', () => {
    const input = `
vless://uuid@example.com:443?type=grpc&security=reality#Node1
hysteria2://pass@example.com:8443#Lossless // with inline comment
https://my-sub.net/token#subscription
`;
    expect(parseValueList(input)).toEqual([
      'vless://uuid@example.com:443?type=grpc&security=reality#Node1',
      'hysteria2://pass@example.com:8443#Lossless',
      'https://my-sub.net/token#subscription',
    ]);
  });

  it('strips visual divider lines like ====== or ------', () => {
    const input = `
====== Xiaomi ======
xiaomi.com
------
mi.com
`;
    expect(parseValueList(input)).toEqual(['Xiaomi', 'xiaomi.com', 'mi.com']);
  });

  it('handles array inputs with mixed strings and comments', () => {
    const input = [
      '// ====== Xiaomi ======',
      'xiaomi.com',
      'mi.com // mobile',
      '# ignore me',
    ];
    expect(parseValueList(input)).toEqual(['xiaomi.com', 'mi.com']);
  });

  it('strips prefixed comments like full://... or keyword:#...', () => {
    const input = `
full://ignored-comment
keyword:#ignored-comment
full:google.com
keyword:xiaomi
`;
    expect(parseValueList(input)).toEqual([
      'full:google.com',
      'keyword:xiaomi',
    ]);
  });
});
