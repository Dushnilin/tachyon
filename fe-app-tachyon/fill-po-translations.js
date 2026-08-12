import fs from 'fs/promises';

const dictionary = {
  "Service Health Check": "Проверка доступности сервисов",
  "Total Targets": "Всего целей",
  "Passed": "Успешно",
  "Failed": "Ошибки",
  "Avg Latency": "Ср. задержка",
  "Search domain...": "Поиск домена...",
  "Section / Target": "Секция / Цель",
  "Outbound Route": "Маршрут",
  "Resolved IP / DNS": "IP / DNS",
  "Verdict": "Статус",
  "Pending": "Ожидает запуска",
  "Check domain or IP (e.g. example.com)...": "Проверить домен или IP (напр. example.com)...",
  "Check Custom": "Проверить свой",
  "Check All": "Проверить все",
  "Checking...": "Проверка...",
  "Check Again": "Проверить снова",
  "Testing...": "Тестирование...",
  "Fetching service targets...": "Получение списка сервисов...",
  "Failed to run service check.": "Не удалось выполнить проверку сервисов.",
  "Failed to parse target list.": "Ошибка обработки списка целей.",
  "No targets found in section configs.": "Цели в конфигурациях секций не найдены.",
  "AI Chat & Tachyon Assistant": "ИИ Чат & Ассистент Tachyon",
  "Hello! I am Tachyon AI Assistant. How can I help you today? Ask me about domain blocks, diagnostics, or router settings.": "Привет! Я ИИ-ассистент Tachyon. Чем могу помочь? Задайте вопрос о блокировках, диагностике или настройках роутера.",
  "Ask Tachyon AI Assistant a question...": "Задайте вопрос ИИ-ассистенту...",
  "Send": "Отправить",
  "Thinking...": "Думаю...",
  "Failed to receive response from AI service.": "Не удалось получить ответ от ИИ-сервиса.",
  "Server unavailable": "Сервер недоступен",
  "AI service error": "Ошибка ИИ-сервиса",
  "Check YouTube": "Проверить YouTube",
  "Check YouTube availability": "Проверить доступность YouTube",
  "Why Discord fails?": "Почему не работает Discord?",
  "Check Mode:": "Режим проверки:",
  "Active Sections": "Активные секции",
  "All Profiles": "Все сервисы и профили",
  "Cannot save settings": "Не удалось сохранить настройки"
};

async function run() {
  const poPaths = [
    'locales/tachyon.ru.po',
    '../luci-app-tachyon/po/ru/tachyon.po'
  ];

  for (const p of poPaths) {
    let content = await fs.readFile(p, 'utf8');
    for (const [key, val] of Object.entries(dictionary)) {
      const searchTarget = `msgid "${key}"\nmsgstr ""`;
      const searchTargetCRLF = `msgid "${key}"\r\nmsgstr ""`;
      const replaceWith = `msgid "${key}"\nmsgstr "${val}"`;

      if (content.includes(`msgid "${key}"`)) {
        content = content.replace(searchTarget, replaceWith);
        content = content.replace(searchTargetCRLF, replaceWith);
      } else {
        content += `\nmsgid "${key}"\nmsgstr "${val}"\n`;
      }
    }
    await fs.writeFile(p, content, 'utf8');
    console.log(`Updated ${p}`);
  }
}

run().catch(console.error);
