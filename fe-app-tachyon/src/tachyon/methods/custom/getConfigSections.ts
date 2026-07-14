import { Tachyon } from '../../types';
import { TACHYON_UCI_PACKAGE } from '../../../constants';

export async function getConfigSections(): Promise<Tachyon.ConfigSection[]> {
  return uci
    .load(TACHYON_UCI_PACKAGE)
    .then(() => uci.sections(TACHYON_UCI_PACKAGE));
}
