import { getConfigSections } from './getConfigSections';

export async function getClashApiSecret() {
  const sections = await getConfigSections();

  const settings = sections.find((section) => section['.type'] === 'settings');

  return settings?.yacd_secret_key || '';
}

export async function isDirectClashApiExposed(): Promise<boolean> {
  const loc = typeof window !== 'undefined' ? window.location : undefined;
  const host = loc?.hostname || '';
  if (host === '127.0.0.1' || host === 'localhost' || host === '::1') {
    return true;
  }
  const sections = await getConfigSections();
  const settings = sections.find((section) => section['.type'] === 'settings');
  return settings?.enable_yacd !== '0';
}
