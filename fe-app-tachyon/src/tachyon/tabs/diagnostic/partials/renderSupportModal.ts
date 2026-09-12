import { renderButton } from '../../../../partials';
import {
  renderCheckIcon24,
  renderCopyIcon24,
  renderLinkIcon24,
} from '../../../../icons';
import { showToast } from '../../../../helpers/showToast';

interface CryptoItem {
  name: string;
  badge: string;
  address: string;
}

const CRYPTO_LIST: CryptoItem[] = [
  {
    name: 'Bitcoin',
    badge: 'BTC',
    address: 'bc1q9ehdv7y9g948jejyflkq7xmau3tytgunxgh35h',
  },
  {
    name: 'Ethereum',
    badge: 'ETH / ERC-20',
    address: '0x6CB7a4547eD62EF64990D5C6B5D9fdA58EB223E6',
  },
  {
    name: 'TON',
    badge: 'TON',
    address: 'UQDPhLRjMz5KltDLACAT3YXXHDVEtIDOHky2i33ZIOtsMEoR',
  },
  {
    name: 'Solana',
    badge: 'SOL',
    address: '3csTGaNeU9KjhCKHEKAU3XLS5UfVjEeBVhXihpsETZwh',
  },
];

const CLOUDTIPS_URL = 'https://pay.cloudtips.ru/p/48c57581';

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
        'margin-bottom: 16px; padding: 12px 14px; background: var(--background-color-secondary, rgba(0, 0, 0, 0.05)); border: 1px solid var(--border-color, rgba(128, 128, 128, 0.2)); border-radius: 6px; font-size: 13px; line-height: 1.5; color: var(--text-color-high, inherit);',
    },
    [
      E(
        'p',
        { style: 'margin: 0;' },
        _(
          'If Tachyon powers your daily networking and keeps your connection fast and secure, consider supporting ongoing development! ☕ 🧀 🌭',
        ),
      ),
    ],
  );

  // CloudTips card
  const cloudTipsCard = E(
    'div',
    {
      style:
        'margin-bottom: 16px; padding: 14px; background: var(--background-color-secondary, rgba(0, 0, 0, 0.05)); border: 1px solid var(--border-color, rgba(128, 128, 128, 0.2)); border-radius: 6px;',
    },
    [
      E(
        'div',
        {
          style:
            'display: flex; align-items: center; justify-content: space-between; flex-wrap: wrap; gap: 10px;',
        },
        [
          E(
            'div',
            { style: 'display: flex; flex-direction: column; gap: 2px;' },
            [
              E('div', { style: 'font-weight: bold; font-size: 14px;' }, [
                '💳 ',
                _('Credit Cards / SBP / Tinkoff Pay'),
              ]),
              E(
                'div',
                {
                  style:
                    'font-size: 12px; color: var(--text-color-medium, #888);',
                },
                _('Quick donation via Russian bank cards or SBP'),
              ),
            ],
          ),
          renderButton({
            classNames: ['cbi-button-action'],
            icon: renderLinkIcon24,
            text: _('Support on CloudTips'),
            onClick: () => {
              window.open(CLOUDTIPS_URL, '_blank', 'noopener,noreferrer');
            },
          }),
        ],
      ),
    ],
  );

  // Crypto list section
  const cryptoItemsContainer = E('div', {
    style: 'display: flex; flex-direction: column; gap: 10px;',
  });

  CRYPTO_LIST.forEach((item) => {
    const addressCode = E(
      'code',
      {
        style:
          'font-family: monospace; font-size: 11px; word-break: break-all; flex: 1; padding: 6px 8px; background: var(--background-color-primary, rgba(0, 0, 0, 0.15)); border: 1px solid var(--border-color, rgba(128, 128, 128, 0.2)); border-radius: 4px; user-select: all; line-height: 1.4;',
      },
      item.address,
    );

    const copyBtn = renderButton({
      classNames: ['cbi-button'],
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

    const row = E(
      'div',
      {
        style:
          'padding: 10px 12px; background: var(--background-color-secondary, rgba(0, 0, 0, 0.05)); border: 1px solid var(--border-color, rgba(128, 128, 128, 0.2)); border-radius: 6px; display: flex; flex-direction: column; gap: 6px;',
      },
      [
        E(
          'div',
          {
            style: 'display: flex; align-items: center; gap: 8px;',
          },
          [
            E(
              'span',
              { style: 'font-weight: bold; font-size: 13px;' },
              item.name,
            ),
            E(
              'span',
              {
                class: 'badge cbi-value-title',
                style: 'font-size: 11px; padding: 2px 6px; opacity: 0.85;',
              },
              item.badge,
            ),
          ],
        ),
        E(
          'div',
          {
            style:
              'display: flex; align-items: center; gap: 8px; flex-wrap: wrap;',
          },
          [addressCode, copyBtn],
        ),
      ],
    );

    cryptoItemsContainer.appendChild(row);
  });

  const cryptoSection = E('div', { style: 'margin-bottom: 16px;' }, [
    E(
      'div',
      {
        style:
          'font-weight: bold; font-size: 14px; margin-bottom: 8px; display: flex; align-items: center; gap: 6px;',
      },
      ['🪙 ', _('Cryptocurrency')],
    ),
    cryptoItemsContainer,
  ]);

  // Modal footer with Close button
  const footer = E(
    'div',
    {
      style:
        'display: flex; justify-content: flex-end; padding-top: 12px; border-top: 1px solid var(--border-color, rgba(128, 128, 128, 0.2));',
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
        'max-width: 640px; width: 100%; box-sizing: border-box; padding: 4px;',
    },
    [introBlock, cloudTipsCard, cryptoSection, footer],
  );

  ui.showModal(`💖 ${_('Support Development')}`, modalContent);
}
