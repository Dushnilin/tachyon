import { beforeEach, describe, expect, it, vi } from 'vitest';

const listReleases = vi.hoisted(() => vi.fn());
vi.mock('../../../methods', () => ({
  TachyonShellMethods: { componentListReleases: listReleases },
}));

describe('release notes lookup', () => {
  beforeEach(() => {
    vi.resetModules();
    listReleases.mockReset();
  });

  const latest = { tag: 'v2.1', body: 'Latest changes' };
  const selected = { tag: 'v2.0', body: 'Earlier changes' };
  const release = (tag: string) => ({ tag, body: `Notes for ${tag}` });
  const page = (prefix: string, count = 5) =>
    Array.from({ length: count }, (_, index) => release(`${prefix}-${index}`));

  it('prefers an exact tag before the optional v-prefix fallback', async () => {
    const { getReleaseForNotes } = await import('../releaseNotes');
    const exact = release('v2.0');
    const withoutPrefix = release('2.0');
    listReleases.mockResolvedValueOnce({
      success: true,
      data: [latest, withoutPrefix, exact],
    });

    expect(await getReleaseForNotes('tachyon', 'v2.0')).toEqual(exact);
    expect(listReleases).toHaveBeenCalledTimes(1);
    expect(listReleases).toHaveBeenCalledWith('tachyon', 5, 1);
  });

  it('prefers an exact tag on a later page over an earlier compatible tag', async () => {
    const { getReleaseForNotes } = await import('../releaseNotes');
    const exact = release('v2.0');
    const withoutPrefix = release('2.0');
    listReleases
      .mockResolvedValueOnce({
        success: true,
        data: [withoutPrefix, ...page('newer', 4)],
      })
      .mockResolvedValueOnce({ success: true, data: [exact] });

    expect(await getReleaseForNotes('tachyon', 'v2.0')).toEqual(exact);
    expect(listReleases.mock.calls).toEqual([
      ['tachyon', 5, 1],
      ['tachyon', 5, 2],
    ]);
  });

  it('matches a tag when only the optional v prefix differs', async () => {
    const { getReleaseForNotes } = await import('../releaseNotes');
    const prefixed = release('v2.0');
    listReleases
      .mockResolvedValueOnce({ success: true, data: [prefixed] })
      .mockResolvedValueOnce({ success: true, data: [] });

    expect(await getReleaseForNotes('tachyon', '2.0')).toEqual(prefixed);
  });

  it('uses the release URL tag to resolve a display version', async () => {
    const { getReleaseForNotes } = await import('../releaseNotes');
    const tagged = release('v2.0');
    listReleases.mockResolvedValueOnce({
      success: true,
      data: [release('2.0'), tagged],
    });

    expect(
      await getReleaseForNotes(
        'tachyon',
        '2.0',
        'https://github.com/example/tachyon/releases/tag/%762.0',
      ),
    ).toEqual(tagged);
    expect(listReleases).toHaveBeenCalledTimes(1);
  });

  it.each([
    'https://github.com/example/tachyon/releases/tag/v2.1',
    'https://github.com/example/tachyon/releases/tag/%xx',
  ])(
    'keeps the requested version with an unrelated or invalid URL',
    async (url) => {
      const { getReleaseForNotes } = await import('../releaseNotes');
      listReleases.mockResolvedValueOnce({
        success: true,
        data: [latest, selected],
      });

      expect(await getReleaseForNotes('tachyon', 'v2.0', url)).toEqual(
        selected,
      );
    },
  );

  it('matches a selected tag on a later page', async () => {
    const { getReleaseForNotes } = await import('../releaseNotes');
    const secondPage = [selected];
    listReleases
      .mockResolvedValueOnce({ success: true, data: page('page-one') })
      .mockResolvedValueOnce({ success: true, data: secondPage });

    expect(await getReleaseForNotes('tachyon', selected.tag)).toEqual(selected);
    expect(listReleases.mock.calls).toEqual([
      ['tachyon', 5, 1],
      ['tachyon', 5, 2],
    ]);
  });

  it('finds an exact tag on the last allowed picker page', async () => {
    const { getReleaseForNotes } = await import('../releaseNotes');
    listReleases.mockImplementation(async (_component, _count, pageNumber) => ({
      success: true,
      data: pageNumber === 20 ? [selected] : page(`older-${pageNumber}`),
    }));

    expect(await getReleaseForNotes('tachyon', selected.tag)).toEqual(selected);
    expect(listReleases).toHaveBeenCalledTimes(20);
  });

  it('stops at the first empty page', async () => {
    const { getReleaseForNotes } = await import('../releaseNotes');
    listReleases
      .mockResolvedValueOnce({ success: true, data: page('page-one') })
      .mockResolvedValueOnce({ success: true, data: [] });

    expect(await getReleaseForNotes('tachyon', 'missing-tag')).toBeUndefined();
    expect(listReleases).toHaveBeenCalledTimes(2);
  });

  it('stops at the undated local-build fallback', async () => {
    const { getReleaseForNotes } = await import('../releaseNotes');
    listReleases.mockResolvedValueOnce({
      success: true,
      data: [
        {
          tag: 'v2.0-local',
          body: 'Local build',
          published: '',
          release_url: 'https://github.com/example/tachyon/releases',
        },
      ],
    });

    expect(await getReleaseForNotes('tachyon', 'older-tag')).toBeUndefined();
    expect(listReleases).toHaveBeenCalledTimes(1);
  });

  it('keeps a real match when the local build placeholder uses the requested tag', async () => {
    const { getReleaseForNotes } = await import('../releaseNotes');
    const compatible = release('2.0');
    listReleases
      .mockResolvedValueOnce({ success: true, data: [compatible] })
      .mockResolvedValueOnce({
        success: true,
        data: [
          {
            tag: 'v2.0',
            body: 'Local build',
            published: '',
            release_url: 'https://github.com/example/tachyon/releases',
          },
        ],
      });

    expect(await getReleaseForNotes('tachyon', 'v2.0')).toEqual(compatible);
  });

  it('uses the first release when no version was supplied', async () => {
    const { getReleaseForNotes } = await import('../releaseNotes');
    listReleases.mockResolvedValueOnce({ success: true, data: [latest] });

    expect(await getReleaseForNotes('tachyon', '')).toEqual(latest);
    expect(listReleases).toHaveBeenCalledTimes(1);
  });

  it('does not reuse stale latest results after a channel change', async () => {
    const { getReleaseForNotes } = await import('../releaseNotes');
    listReleases
      .mockResolvedValueOnce({ success: true, data: [selected] })
      .mockResolvedValueOnce({ success: true, data: [latest] });

    expect(await getReleaseForNotes('tachyon', '')).toEqual(selected);
    expect(await getReleaseForNotes('tachyon', '')).toEqual(latest);
    expect(listReleases).toHaveBeenCalledTimes(2);
  });

  it('propagates failed lookups without unrelated notes', async () => {
    const { getReleaseForNotes } = await import('../releaseNotes');
    listReleases.mockResolvedValueOnce({ success: false, error: 'offline' });

    await expect(getReleaseForNotes('tachyon', 'v2.0')).rejects.toThrow(
      'offline',
    );
  });

  it('keeps a compatible tag already found when a later request fails', async () => {
    const { getReleaseForNotes } = await import('../releaseNotes');
    const compatible = release('2.0');
    listReleases
      .mockResolvedValueOnce({ success: true, data: [compatible] })
      .mockResolvedValueOnce({ success: false, error: 'offline' });

    expect(await getReleaseForNotes('tachyon', 'v2.0')).toEqual(compatible);
  });

  it('stops at the bounded search limit for very old tags', async () => {
    const { getReleaseForNotes } = await import('../releaseNotes');
    listReleases.mockImplementation(async () => ({
      success: true,
      data: page('not-the-tag'),
    }));

    expect(
      await getReleaseForNotes('tachyon', 'older-than-search-window'),
    ).toBeUndefined();
    expect(listReleases).toHaveBeenCalledTimes(20);
  });
});
