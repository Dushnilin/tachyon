import { getCheckTitle } from '../helpers/getCheckTitle';

export enum DIAGNOSTICS_CHECKS {
  DNS = 'DNS',
  TACHYON_CORE = 'TACHYON_CORE',
  NFT = 'NFT',
  FAKEIP = 'FAKEIP',
  OUTBOUNDS = 'OUTBOUNDS',
  INBOUNDS = 'INBOUNDS',
}

export function getFirewallCheckTitle(isIptables: boolean): string {
  return getCheckTitle(isIptables ? 'iptables' : 'Nftables');
}

export const DIAGNOSTICS_CHECKS_MAP: Record<
  DIAGNOSTICS_CHECKS,
  { order: number; title: string; code: DIAGNOSTICS_CHECKS }
> = {
  [DIAGNOSTICS_CHECKS.DNS]: {
    order: 1,
    title: getCheckTitle('DNS'),
    code: DIAGNOSTICS_CHECKS.DNS,
  },
  [DIAGNOSTICS_CHECKS.TACHYON_CORE]: {
    order: 2,
    title: getCheckTitle('Tachyon Core'),
    code: DIAGNOSTICS_CHECKS.TACHYON_CORE,
  },
  [DIAGNOSTICS_CHECKS.INBOUNDS]: {
    order: 3,
    title: getCheckTitle('Inbounds'),
    code: DIAGNOSTICS_CHECKS.INBOUNDS,
  },
  [DIAGNOSTICS_CHECKS.NFT]: {
    order: 4,
    title: getCheckTitle('Nftables'),
    code: DIAGNOSTICS_CHECKS.NFT,
  },
  [DIAGNOSTICS_CHECKS.OUTBOUNDS]: {
    order: 5,
    title: getCheckTitle('Outbounds'),
    code: DIAGNOSTICS_CHECKS.OUTBOUNDS,
  },
  [DIAGNOSTICS_CHECKS.FAKEIP]: {
    order: 6,
    title: getCheckTitle('FakeIP'),
    code: DIAGNOSTICS_CHECKS.FAKEIP,
  },
};
