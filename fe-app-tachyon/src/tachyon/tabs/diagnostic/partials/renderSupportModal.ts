import { renderButton } from '../../../../partials';
import {
  renderCheckIcon24,
  renderCopyIcon24,
  renderLinkIcon24,
  renderHeartIcon24,
  renderSparklesIcon,
  renderCreditCardIcon,
  renderQrCodeIcon,
  renderCoinsIcon,
  renderGemIcon,
} from '../../../../icons';
import { showToast } from '../../../../helpers/showToast';
import { tr } from '../../../helpers/i18n';

interface CryptoItem {
  name: string;
  badge: string;
  icon: string | (() => SVGElement);
  accent: string;
  address: string;
}

const CRYPTO_LIST: CryptoItem[] = [
  {
    name: 'Bitcoin',
    badge: 'BTC',
    icon: '₿',
    accent: '#f59e0b',
    address: 'bc1q9ehdv7y9g948jejyflkq7xmau3tytgunxgh35h',
  },
  {
    name: 'Ethereum',
    badge: 'ETH / ERC-20',
    icon: 'Ξ',
    accent: '#0a84ff',
    address: '0x6CB7a4547eD62EF64990D5C6B5D9fdA58EB223E6',
  },
  {
    name: 'TON',
    badge: 'TON',
    icon: () => renderGemIcon(14),
    accent: '#0ea5e9',
    address: 'UQDPhLRjMz5KltDLACAT3YXXHDVEtIDOHky2i33ZIOtsMEoR',
  },
  {
    name: 'Solana',
    badge: 'SOL',
    icon: '◎',
    accent: '#10b981',
    address: '3csTGaNeU9KjhCKHEKAU3XLS5UfVjEeBVhXihpsETZwh',
  },
];

const CLOUDTIPS_URL = 'https://pay.cloudtips.ru/p/449c5ef9';
const OZON_SBP_URL =
  'https://finance.ozon.ru/apps/sbp/ozonbankpay/019af2ed-d158-77a9-a698-2805a5e61be5';
const BOOSTY_URL = 'https://boosty.to/tachyon';

async function copyTextToClipboard(text: string): Promise<boolean> {
  try {
    if (navigator.clipboard && window.isSecureContext) {
      await navigator.clipboard.writeText(text);
      return true;
    }
  } catch {
    // Fallback to execCommand
  }

  try {
    const ta = document.createElement('textarea');
    ta.value = text;
    ta.style.position = 'fixed';
    ta.style.left = '-9999px';
    ta.style.top = '0';
    document.body.appendChild(ta);
    ta.focus();
    ta.select();
    const successful = document.execCommand('copy');
    document.body.removeChild(ta);
    return successful;
  } catch {
    return false;
  }
}

export function renderSupportModal(): void {
  const introBlock = E(
    'div',
    {
      style:
        'display: flex; align-items: center; gap: 14px; padding: 14px 16px; border-radius: 10px; background: var(--tachyon-bg-card-elevated, rgba(148, 163, 184, 0.06)); border: 1px solid var(--tachyon-border-subtle, rgba(148, 163, 184, 0.18));',
    },
    [
      E(
        'div',
        {
          style:
            'width: 40px; height: 40px; border-radius: 8px; background: var(--tachyon-accent-soft, rgba(124, 134, 255, 0.12)); border: 1px solid var(--tachyon-accent-border, rgba(124, 134, 255, 0.24)); display: flex; align-items: center; justify-content: center; font-size: 18px; flex-shrink: 0;',
        },
        [renderHeartIcon24()],
      ),
      E(
        'p',
        {
          style:
            'margin: 0; font-size: 13px; line-height: 1.5; color: var(--tachyon-text-main, var(--text-color-high, inherit));',
        },
        _(
          'If Tachyon powers your daily networking and keeps your connection fast and secure, consider supporting ongoing development!',
        ),
      ),
    ],
  );

  const stylePrimarySupportButton = (btn: HTMLElement): HTMLElement => {
    btn.style.width = '100%';
    btn.style.justifyContent = 'center';
    btn.style.whiteSpace = 'nowrap';
    btn.style.minHeight = '34px';
    return btn;
  };

  // Boosty card (primary Bento tile)
  const boostyCard = E(
    'div',
    {
      style:
        'display: flex; flex-direction: column; justify-content: space-between; gap: 12px; padding: 14px 16px; border-radius: 10px; background: var(--tachyon-bg-card-elevated, rgba(148, 163, 184, 0.05)); border: 1px solid var(--tachyon-border-subtle, rgba(148, 163, 184, 0.2));',
    },
    [
      E(
        'div',
        { style: 'display: flex; align-items: flex-start; gap: 12px;' },
        [
          E(
            'div',
            {
              style:
                'width: 36px; height: 36px; border-radius: 8px; background: rgba(241, 95, 44, 0.12); border: 1px solid rgba(241, 95, 44, 0.26); display: flex; align-items: center; justify-content: center; color: #f15f2c; flex-shrink: 0;',
            },
            [renderSparklesIcon(18)],
          ),
          E(
            'div',
            {
              style:
                'display: flex; flex-direction: column; gap: 3px; min-width: 0;',
            },
            [
              E(
                'div',
                {
                  style:
                    'font-weight: 600; font-size: 14px; color: var(--tachyon-text-main, inherit);',
                },
                'Boosty',
              ),
              E(
                'div',
                {
                  style:
                    'font-size: 12px; line-height: 1.4; color: var(--tachyon-text-muted, var(--text-color-medium, #94a3b8));',
                },
                _('Subscriptions, one-time donations and exclusives'),
              ),
            ],
          ),
        ],
      ),
      stylePrimarySupportButton(
        renderButton({
          classNames: ['cbi-button-apply'],
          icon: renderLinkIcon24,
          text: tr('Открыть Boosty', 'Support on Boosty'),
          onClick: () => {
            window.open(BOOSTY_URL, '_blank', 'noopener,noreferrer');
          },
        }),
      ),
    ],
  );

  // CloudTips card (primary Bento tile)
  const cloudTipsCard = E(
    'div',
    {
      style:
        'display: flex; flex-direction: column; justify-content: space-between; gap: 12px; padding: 14px 16px; border-radius: 10px; background: var(--tachyon-bg-card-elevated, rgba(148, 163, 184, 0.05)); border: 1px solid var(--tachyon-border-subtle, rgba(148, 163, 184, 0.2));',
    },
    [
      E(
        'div',
        { style: 'display: flex; align-items: flex-start; gap: 12px;' },
        [
          E(
            'div',
            {
              style:
                'width: 36px; height: 36px; border-radius: 8px; background: rgba(14, 165, 233, 0.12); border: 1px solid rgba(14, 165, 233, 0.26); display: flex; align-items: center; justify-content: center; flex-shrink: 0; color: #0ea5e9;',
            },
            [renderCreditCardIcon(18)],
          ),
          E(
            'div',
            {
              style:
                'display: flex; flex-direction: column; gap: 3px; min-width: 0;',
            },
            [
              E(
                'div',
                {
                  style:
                    'font-weight: 600; font-size: 14px; color: var(--tachyon-text-main, inherit);',
                },
                tr('Карты РФ / СБП', 'Cards / SBP'),
              ),
              E(
                'div',
                {
                  style:
                    'font-size: 12px; line-height: 1.4; color: var(--tachyon-text-muted, var(--text-color-medium, #94a3b8));',
                },
                _('Quick donation via Russian bank cards or SBP'),
              ),
            ],
          ),
        ],
      ),
      stylePrimarySupportButton(
        renderButton({
          classNames: ['cbi-button-save'],
          icon: renderLinkIcon24,
          text: tr('Открыть CloudTips', 'Support on CloudTips'),
          onClick: () => {
            window.open(CLOUDTIPS_URL, '_blank', 'noopener,noreferrer');
          },
        }),
      ),
    ],
  );

  // Ozon Bank SBP card (primary Bento tile)
  const ozonSbpCard = E(
    'div',
    {
      style:
        'display: flex; flex-direction: column; justify-content: space-between; gap: 12px; padding: 14px 16px; border-radius: 10px; background: var(--tachyon-bg-card-elevated, rgba(148, 163, 184, 0.05)); border: 1px solid var(--tachyon-border-subtle, rgba(148, 163, 184, 0.2));',
    },
    [
      E(
        'div',
        { style: 'display: flex; align-items: flex-start; gap: 12px;' },
        [
          E(
            'div',
            {
              style:
                'width: 36px; height: 36px; border-radius: 8px; background: rgba(59, 130, 246, 0.12); border: 1px solid rgba(59, 130, 246, 0.26); display: flex; align-items: center; justify-content: center; flex-shrink: 0; color: #3b82f6;',
            },
            [renderQrCodeIcon(18)],
          ),
          E(
            'div',
            {
              style:
                'display: flex; flex-direction: column; gap: 3px; min-width: 0;',
            },
            [
              E(
                'div',
                {
                  style:
                    'font-weight: 600; font-size: 14px; color: var(--tachyon-text-main, inherit);',
                },
                tr('СБП (Ozon Банк)', 'SBP (Ozon Bank)'),
              ),
              E(
                'div',
                {
                  style:
                    'font-size: 12px; line-height: 1.4; color: var(--tachyon-text-muted, var(--text-color-medium, #94a3b8));',
                },
                tr(
                  'Мгновенный перевод по СБП без комиссии',
                  'Instant SBP transfer without fees',
                ),
              ),
            ],
          ),
        ],
      ),
      stylePrimarySupportButton(
        renderButton({
          classNames: ['cbi-button-save'],
          icon: renderLinkIcon24,
          text: tr('Открыть СБП', 'Support via SBP'),
          onClick: () => {
            window.open(OZON_SBP_URL, '_blank', 'noopener,noreferrer');
          },
        }),
      ),
    ],
  );

  const primaryBentoRow = E(
    'div',
    {
      style:
        'display: grid; grid-template-columns: repeat(auto-fit, minmax(195px, 1fr)); gap: 12px;',
    },
    [boostyCard, ozonSbpCard, cloudTipsCard],
  );

  // Crypto 2x2 Bento grid
  const cryptoItemsContainer = E('div', {
    style:
      'display: grid; grid-template-columns: repeat(auto-fit, minmax(240px, 1fr)); gap: 10px;',
  });

  CRYPTO_LIST.forEach((item) => {
    const copyBtn = renderButton({
      classNames: ['cbi-button-action'],
      icon: renderCopyIcon24,
      text: _('Copy Address'),
      onClick: async () => {
        const ok = await copyTextToClipboard(item.address);
        if (ok) {
          copyBtn.replaceChildren(
            renderCheckIcon24(),
            document.createTextNode(' ' + _('Copied!')),
          );
          copyBtn.classList.add('cbi-button-apply');
          setTimeout(() => {
            copyBtn.replaceChildren(
              renderCopyIcon24(),
              document.createTextNode(' ' + _('Copy Address')),
            );
            copyBtn.classList.remove('cbi-button-apply');
          }, 2000);
          showToast(_('Address copied to clipboard'), 'success');
        } else {
          showToast(_('Failed to copy address'), 'error');
        }
      },
    });
    copyBtn.style.whiteSpace = 'nowrap';
    copyBtn.style.flexShrink = '0';

    const addressCode = E(
      'code',
      {
        title: item.address,
        onclick: () => copyBtn.click(),
        style:
          'display: block; font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace; font-size: 11px; padding: 7px 10px; background: var(--tachyon-bg-input, rgba(15, 23, 42, 0.35)); border: 1px solid var(--tachyon-border-subtle, rgba(148, 163, 184, 0.16)); border-radius: 8px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; user-select: all; cursor: pointer; color: var(--tachyon-text-secondary, inherit);',
      },
      item.address,
    );

    const tile = E(
      'div',
      {
        style:
          'padding: 12px 14px; background: var(--tachyon-bg-surface-alt, rgba(148, 163, 184, 0.05)); border: 1px solid var(--tachyon-border-subtle, rgba(148, 163, 184, 0.18)); border-radius: 10px; display: flex; flex-direction: column; gap: 8px;',
      },
      [
        E(
          'div',
          {
            style:
              'display: flex; align-items: center; justify-content: space-between; gap: 8px; flex-wrap: nowrap; min-width: 0;',
          },
          [
            E(
              'div',
              {
                style:
                  'display: flex; align-items: center; gap: 8px; min-width: 0; flex: 1 1 auto;',
              },
              [
                E(
                  'span',
                  {
                    style: `width: 26px; height: 26px; border-radius: 6px; display: inline-flex; align-items: center; justify-content: center; font-size: 13px; font-weight: 600; background: ${item.accent}1f; color: ${item.accent}; border: 1px solid ${item.accent}3d; flex-shrink: 0;`,
                  },
                  typeof item.icon === 'function' ? [item.icon()] : item.icon,
                ),
                E(
                  'div',
                  {
                    style:
                      'display: flex; flex-direction: column; gap: 1px; min-width: 0;',
                  },
                  [
                    E(
                      'span',
                      {
                        style:
                          'font-weight: 600; font-size: 13px; line-height: 1.2; white-space: nowrap; overflow: hidden; text-overflow: ellipsis;',
                      },
                      item.name,
                    ),
                    E(
                      'span',
                      {
                        style:
                          'font-size: 10.5px; font-weight: 500; line-height: 1.2; color: var(--tachyon-text-muted, #94a3b8); white-space: nowrap; overflow: hidden; text-overflow: ellipsis;',
                      },
                      item.badge,
                    ),
                  ],
                ),
              ],
            ),
            copyBtn,
          ],
        ),
        addressCode,
      ],
    );

    cryptoItemsContainer.appendChild(tile);
  });

  const cryptoSection = E(
    'div',
    {
      style:
        'display: flex; flex-direction: column; gap: 10px; padding: 14px 16px; border-radius: 10px; border: 1px solid var(--tachyon-border-subtle, rgba(148, 163, 184, 0.18)); background: var(--tachyon-bg-card, rgba(30, 41, 59, 0.35));',
    },
    [
      E(
        'div',
        {
          style:
            'font-weight: 600; font-size: 12.5px; color: var(--tachyon-text-muted, #94a3b8); display: flex; align-items: center; gap: 6px;',
        },
        [renderCoinsIcon(14), _('Cryptocurrency')],
      ),
      cryptoItemsContainer,
    ],
  );

  // Modal footer with Close button
  const footer = E(
    'div',
    {
      style:
        'display: flex; justify-content: flex-end; padding-top: 10px; border-top: 1px solid var(--tachyon-border-subtle, rgba(148, 163, 184, 0.16));',
    },
    [
      renderButton({
        classNames: ['cbi-button'],
        text: _('Close'),
        onClick: () => {
          if (ui.hideModal) ui.hideModal();
        },
      }),
    ],
  );

  const modalContent = E(
    'div',
    {
      style:
        'max-width: 680px; width: 100%; box-sizing: border-box; display: flex; flex-direction: column; gap: 14px;',
    },
    [introBlock, primaryBentoRow, cryptoSection, footer],
  );

  ui.showModal(_('Support Development'), modalContent);
}
