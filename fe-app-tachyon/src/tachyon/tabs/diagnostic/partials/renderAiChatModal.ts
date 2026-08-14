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
    class: 'tachyon_ai_chat__messages',
  });

  const renderMessages = () => {
    messageListContainer.innerHTML = '';
    chatHistory.forEach((msg) => {
      const isUser = msg.sender === 'user';
      const bubble = E(
        'div',
        {
          class: `tachyon_ai_chat__bubble ${isUser ? 'tachyon_ai_chat__bubble--user' : ''}`,
        },
        [
          E('div', {}, msg.text),
          E('small', {}, msg.timestamp),
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
  });

  const sendBtn = renderButton({
    text: _('Send'),
    classNames: ['cbi-button cbi-button-action'],
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

    const typingMsg: ChatMessage = {
      sender: 'assistant',
      text: _('Thinking...'),
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
      )) as { success?: boolean; data?: unknown };
      chatHistory.pop();

      let answerText = _('Failed to receive response from AI service.');
      if (res && res.success) {
        if (typeof res.data === 'string') {
          try {
            const parsed = JSON.parse(res.data);
            answerText =
              parsed.summary || parsed.message || parsed.raw || res.data;
          } catch (_e) {
            answerText = res.data;
          }
        } else if (
          typeof res.data === 'object' &&
          res.data !== null &&
          'message' in res.data
        ) {
          answerText = String((res.data as { message: string }).message);
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
        text: _('AI service error') + ': ' + errMsg,
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

  const quickPrompts = [
    { label: _('Check YouTube'), query: 'Check YouTube availability' },
    { label: _('Why Discord fails?'), query: 'Why Discord fails?' },
    { label: _('Full System Diagnostic'), query: 'Run full system diagnostic' },
  ];

  const quickPromptsBar = E(
    'div',
    { class: 'tachyon_ai_chat__toolbar' },
    quickPrompts.map((qp) => {
      const btn = E(
        'button',
        {
          type: 'button',
          class: 'cbi-button cbi-button-neutral',
          style: 'font-size: 12px; padding: 2px 8px;',
        },
        qp.label,
      );
      btn.onclick = () => handleSend(qp.query);
      return btn;
    }),
  );

  const inputToolbar = E(
    'div',
    { class: 'tachyon_ai_chat__input-row' },
    [chatInput, sendBtn],
  );

  const modalContent = E(
    'div',
    { style: 'width: 100%; max-width: 680px;' },
    [
      quickPromptsBar,
      messageListContainer,
      inputToolbar,
      E(
        'div',
        { class: 'tachyon_service_check__footer' },
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
