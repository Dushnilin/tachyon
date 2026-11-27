import { Tachyon } from '../../types';
import { TACHYON_UCI_PACKAGE } from '../../../constants';

export async function getConfigSections(
  options: { forceReload?: boolean } = {},
): Promise<Tachyon.ConfigSection[]> {
  if (
    !options.forceReload &&
    typeof uci !== 'undefined' &&
    typeof uci.sections === 'function'
  ) {
    const cached = uci.sections(TACHYON_UCI_PACKAGE);
    if (Array.isArray(cached) && cached.length > 0) {
      return cached;
    }
  }

  return uci
    .load(TACHYON_UCI_PACKAGE)
    .then(() => uci.sections(TACHYON_UCI_PACKAGE));
}
