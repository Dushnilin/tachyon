import { callBaseMethod } from '../../../methods/shell/callBaseMethod';
import { renderButton } from '../../../../partials';
import { Tachyon } from '../../../types';

interface ChatMessage {
  sender: 'user' | 'assistant';
  text: string;
  timestamp: string;
}

const chatHistory: ChatMessage[] = [
  {
    sender: 'assistant',
    text: _(
      'Hello! I am Tachyon AI Assistant. How can I help you today? Ask me about domain blocks, diagnostics, or router settings.',
    ),
    timestamp: new Date().toLocaleTimeString([], {
      hour: '2-digit',
      minute: '2-digit',
    }),
  },
];

export function renderAiChatModal() {
  const messageListContainer = E('div', {
    style:
      'height: 360px; overflow-y: auto; padding: 12px; background: var(--background-color-secondary, rgba(0,0,0,0.2)); border: 1px solid var(--border-color, rgba(255,255,255,0.15)); border-radius: 8px; display: flex; flex-direction: column; gap: 10px; margin-bottom: 12px; width: 100%; box-sizing: border-box;',
  });

  const renderMessages = () => {
    messageListContainer.innerHTML = '';
    chatHistory.forEach((msg) => {
      const isUser = msg.sender === 'user';
      const bubble = E(
        'div',
        {
          style: `max-width: 82%; align-self: ${isUser ? 'flex-end' : 'flex-start'}; background: ${isUser ? '#007bff' : 'var(--background-color-primary, #2a2a2a)'}; color: #fff; padding: 8px 12px; border-radius: 12px; font-size: 13px; border: 1px solid ${isUser ? '#0056b3' : 'var(--border-color, rgba(255,255,255,0.15))'}; line-height: 1.4; word-break: break-word;`,
        },
        [
          E('div', {}, msg.text),
          E(
            'small',
            {
              style:
                'display: block; opacity: 0.65; text-align: right; font-size: 10px; margin-top: 4px;',
            },
            msg.timestamp,
          ),
        ],
      );
      messageListContainer.appendChild(bubble);
    });
    messageListContainer.scrollTop = messageListContainer.scrollHeight;
  };

  renderMessages();

  const chatInput = E('input', {
    type: 'text',
    placeholder: _('Ask Tachyon AI Assistant a question...'),
    class: 'cbi-input-text',
    style:
      'flex: 1 1 auto; min-width: 0; font-size: 13px; padding: 6px 10px; border-radius: 6px; box-sizing: border-box;',
  });

  const sendBtn = renderButton({
    text: _('Send'),
    classNames: ['cbi-button-action'],
    onClick: () => handleSend(),
  });

  const handleSend = async (queryText?: string) => {
    const text = (queryText || chatInput.value).trim();
    if (!text) return;

    const userMsg: ChatMessage = {
      sender: 'user',
      text,
      timestamp: new Date().toLocaleTimeString([], {
        hour: '2-digit',
        minute: '2-digit',
      }),
    };
    chatHistory.push(userMsg);
    chatInput.value = '';
    renderMessages();

    // Typing indicator
    const typingMsg: ChatMessage = {
      sender: 'assistant',
      text: '🤖 ' + _('Thinking...'),
      timestamp: new Date().toLocaleTimeString([], {
        hour: '2-digit',
        minute: '2-digit',
      }),
    };
    chatHistory.push(typingMsg);
    renderMessages();

    try {
      const res = (await callBaseMethod(
        Tachyon.AvailableMethods.AI_DOCTOR,
        [text],
        '/usr/bin/tachyon',
        { timeout: 120000 },
      )) as { success?: boolean; data?: unknown };
      chatHistory.pop(); // Remove typing indicator

      let answerText = _('Failed to receive response from AI service.');
      if (res && res.success) {
        const d = res.data as Record<string, unknown> | string | null;
        if (typeof d === 'object' && d !== null) {
          answerText = String(
            d.report ?? d.summary ?? d.message ?? d.raw ?? JSON.stringify(d),
          );
        } else if (typeof d === 'string') {
          try {
            const parsed = JSON.parse(d) as Record<string, unknown>;
            answerText = String(
              parsed.report ?? parsed.summary ?? parsed.message ?? parsed.raw ?? d,
            );
          } catch (_e) {
            answerText = d;
          }
        }
      }

      chatHistory.push({
        sender: 'assistant',
        text: answerText,
        timestamp: new Date().toLocaleTimeString([], {
          hour: '2-digit',
          minute: '2-digit',
        }),
      });
    } catch (e: unknown) {
      chatHistory.pop();
      const errMsg = e instanceof Error ? e.message : _('Server unavailable');
      chatHistory.push({
        sender: 'assistant',
        text: '❌ ' + _('AI service error') + ': ' + errMsg,
        timestamp: new Date().toLocaleTimeString([], {
          hour: '2-digit',
          minute: '2-digit',
        }),
      });
    }

    renderMessages();
  };

  chatInput.onkeydown = (e: KeyboardEvent) => {
    if (e.key === 'Enter') handleSend();
  };

  // Quick prompt buttons
  const quickPrompts = [
    { label: '🩺 ' + _('Check YouTube'), query: 'Check YouTube availability' },
    { label: '🔍 ' + _('Why Discord fails?'), query: 'Why Discord fails?' },
    {
      label: '🛠️ ' + _('Full System Diagnostic'),
      query: 'Run full system diagnostic',
    },
  ];

  const quickPromptsBar = E(
    'div',
    {
      style:
        'display: flex; gap: 6px; flex-wrap: wrap; margin-bottom: 10px; width: 100%; box-sizing: border-box;',
    },
    quickPrompts.map((qp) => {
      const btn = E(
        'button',
        {
          type: 'button',
          class: 'cbi-button cbi-button-neutral',
          style: 'font-size: 11px; padding: 2px 8px; border-radius: 10px;',
        },
        qp.label,
      );
      btn.onclick = () => handleSend(qp.query);
      return btn;
    }),
  );

  const inputToolbar = E(
    'div',
    {
      style:
        'display: flex; gap: 8px; align-items: center; width: 100%; box-sizing: border-box;',
    },
    [chatInput, sendBtn],
  );

  const modalWrapper = E(
    'div',
    { style: 'width: 100%; max-width: 680px; box-sizing: border-box;' },
    [quickPromptsBar, messageListContainer, inputToolbar],
  );

  const modalContent = E(
    'div',
    { style: 'width: 100%; max-width: 680px; box-sizing: border-box;' },
    [
      modalWrapper,
      E(
        'div',
        {
          style:
            'margin-top: 12px; display: flex; justify-content: flex-end; border-top: 1px solid var(--border-color, rgba(255,255,255,0.15)); padding-top: 10px;',
        },
        [
          renderButton({
            text: _('Close'),
            onClick: () => ui.hideModal(),
          }),
        ],
      ),
    ],
  );

  ui.showModal(_('AI Chat & Tachyon Assistant'), modalContent);
}
