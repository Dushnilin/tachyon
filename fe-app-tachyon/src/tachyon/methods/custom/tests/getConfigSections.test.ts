import { beforeEach, describe, expect, it, vi } from 'vitest';
import { TACHYON_UCI_PACKAGE } from '../../../../constants';
import { getConfigSections } from '../getConfigSections';

describe('getConfigSections', () => {
  const cachedSections = [{ '.name': 'main', '.type': 'section' }];
  let uciLoadMock: ReturnType<typeof vi.fn>;
  let uciSectionsMock: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    uciLoadMock = vi.fn().mockResolvedValue(undefined);
    uciSectionsMock = vi.fn().mockReturnValue(cachedSections);
    (globalThis as Record<string, unknown>).uci = {
      load: uciLoadMock,
      sections: uciSectionsMock,
    };
  });

  it('returns cached sections without calling uci.load when uci already has sections in memory', async () => {
    const result = await getConfigSections();

    expect(result).toEqual(cachedSections);
    expect(uciSectionsMock).toHaveBeenCalledWith(TACHYON_UCI_PACKAGE);
    expect(uciLoadMock).not.toHaveBeenCalled();
  });

  it('calls uci.load when uci memory cache is empty', async () => {
    const loadedSections = [{ '.name': 'settings', '.type': 'settings' }];
    uciSectionsMock.mockReturnValueOnce([]).mockReturnValueOnce(loadedSections);

    const result = await getConfigSections();

    expect(uciLoadMock).toHaveBeenCalledWith(TACHYON_UCI_PACKAGE);
    expect(result).toEqual(loadedSections);
  });

  it('calls uci.load when forceReload is true even if sections exist in memory', async () => {
    const refreshedSections = [{ '.name': 'fresh', '.type': 'section' }];
    uciSectionsMock.mockReturnValue(refreshedSections);

    const result = await getConfigSections({ forceReload: true });

    expect(uciLoadMock).toHaveBeenCalledWith(TACHYON_UCI_PACKAGE);
    expect(result).toEqual(refreshedSections);
  });
});
