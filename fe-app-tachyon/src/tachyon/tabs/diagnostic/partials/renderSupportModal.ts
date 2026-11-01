import { renderButton } from '../../../../partials';
import {
  renderCheckIcon24,
  renderCopyIcon24,
  renderLinkIcon24,
  renderHeartIcon24,
  renderSparklesIcon,
  renderCreditCardIcon,
  renderCoinsIcon,
  renderGemIcon,
} from '../../../../icons';
import { showToast } from '../../../../helpers/showToast';

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
    accent: '#6366f1',
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

const CLOUDTIPS_URL = 'https://pay.cloudtips.ru/p/48c57581';
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
        'display: flex; align-items: center; gap: 14px; padding: 14px 16px; border-radius: 12px; background: linear-gradient(135deg, rgba(244, 63, 94, 0.12), rgba(99, 102, 241, 0.08)); border: 1px solid rgba(244, 63, 94, 0.24);',
    },
    [
      E(
        'div',
        {
          style:
            'width: 42px; height: 42px; border-radius: 11px; background: rgba(244, 63, 94, 0.18); border: 1px solid rgba(244, 63, 94, 0.34); display: flex; align-items: center; justify-content: center; font-size: 20px; flex-shrink: 0;',
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

  // Boosty card (primary Bento tile)
  const boostyCard = E(
    'div',
    {
      style:
        'display: flex; flex-direction: column; justify-content: space-between; gap: 12px; padding: 14px 16px; border-radius: 12px; background: linear-gradient(145deg, rgba(241, 95, 44, 0.12), rgba(241, 95, 44, 0.03)); border: 1px solid rgba(241, 95, 44, 0.35);',
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
                'width: 38px; height: 38px; border-radius: 10px; background: rgba(241, 95, 44, 0.2); border: 1px solid rgba(241, 95, 44, 0.38); display: flex; align-items: center; justify-content: center; color: #f15f2c; flex-shrink: 0;',
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
                    'font-weight: 700; font-size: 14px; color: var(--tachyon-text-main, inherit);',
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
      renderButton({
        classNames: ['cbi-button-apply'],
        icon: renderLinkIcon24,
        text: _('Support on Boosty'),
        onClick: () => {
          window.open(BOOSTY_URL, '_blank', 'noopener,noreferrer');
        },
      }),
    ],
  );

  // CloudTips card (primary Bento tile)
  const cloudTipsCard = E(
    'div',
    {
      style:
        'display: flex; flex-direction: column; justify-content: space-between; gap: 12px; padding: 14px 16px; border-radius: 12px; background: linear-gradient(145deg, rgba(14, 165, 233, 0.12), rgba(14, 165, 233, 0.03)); border: 1px solid rgba(14, 165, 233, 0.35);',
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
                'width: 38px; height: 38px; border-radius: 10px; background: rgba(14, 165, 233, 0.2); border: 1px solid rgba(14, 165, 233, 0.38); display: flex; align-items: center; justify-content: center; flex-shrink: 0; color: #0ea5e9;',
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
                    'font-weight: 700; font-size: 14px; color: var(--tachyon-text-main, inherit);',
                },
                _('Credit Cards / SBP / Tinkoff Pay'),
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
      renderButton({
        classNames: ['cbi-button-save'],
        icon: renderLinkIcon24,
        text: _('Support on CloudTips'),
        onClick: () => {
          window.open(CLOUDTIPS_URL, '_blank', 'noopener,noreferrer');
        },
      }),
    ],
  );

  const primaryBentoRow = E(
    'div',
    {
      style:
        'display: grid; grid-template-columns: repeat(auto-fit, minmax(240px, 1fr)); gap: 12px;',
    },
    [boostyCard, cloudTipsCard],
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
              'display: flex; align-items: center; justify-content: space-between; gap: 8px; flex-wrap: wrap;',
          },
          [
            E(
              'div',
              { style: 'display: flex; align-items: center; gap: 8px;' },
              [
                E(
                  'span',
                  {
                    style: `width: 26px; height: 26px; border-radius: 7px; display: inline-flex; align-items: center; justify-content: center; font-size: 13px; font-weight: 700; background: ${item.accent}22; color: ${item.accent}; border: 1px solid ${item.accent}44; flex-shrink: 0;`,
                  },
                  typeof item.icon === 'function' ? [item.icon()] : item.icon,
                ),
                E(
                  'span',
                  { style: 'font-weight: 700; font-size: 13px;' },
                  item.name,
                ),
                E(
                  'span',
                  {
                    class: 'badge cbi-value-title',
                    style:
                      'font-size: 10px; font-weight: 700; padding: 2px 7px; border-radius: 999px; opacity: 0.9;',
                  },
                  item.badge,
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
        'display: flex; flex-direction: column; gap: 10px; padding: 14px 16px; border-radius: 12px; border: 1px solid var(--tachyon-border-subtle, rgba(148, 163, 184, 0.18)); background: var(--tachyon-bg-card, rgba(30, 41, 59, 0.35));',
    },
    [
      E(
        'div',
        {
          style:
            'font-weight: 700; font-size: 12px; text-transform: uppercase; letter-spacing: 0.05em; color: var(--tachyon-text-muted, #94a3b8); display: flex; align-items: center; gap: 6px;',
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
