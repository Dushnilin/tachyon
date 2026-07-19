import fs from 'fs/promises';
import { getGitUser } from './locales-utils.js';

const lang = process.argv[2];
if (!lang) {
    console.error('❌ Укажи язык, например: node generate-po.js ru');
    process.exit(1);
}

const callsPath = 'locales/calls.json';
const poPath = `locales/tachyon.${lang}.po`;

function getHeader(lang) {
    const now = new Date();
    const date = now.toISOString().split('T')[0];
    const time = now.toTimeString().split(' ')[0].slice(0, 5);
    const tzOffset = (() => {
        const offset = -now.getTimezoneOffset();
        const sign = offset >= 0 ? '+' : '-';
        const hours = String(Math.floor(Math.abs(offset) / 60)).padStart(2, '0');
        const minutes = String(Math.abs(offset) % 60).padStart(2, '0');
        return `${sign}${hours}${minutes}`;
    })();

    const translator = getGitUser('Automatically generated').name;
    const pluralForms = lang === 'ru'
        ? 'nplurals=3; plural=(n%10==1 && n%100!=11 ? 0 : n%10>=2 && n%10<=4 && (n%100<10 || n%100>=20) ? 1 : 2);'
        : 'nplurals=2; plural=(n != 1);';

    return [
        `# ${lang.toUpperCase()} translations for TACHYON package.`,
        `# Copyright (C) ${now.getFullYear()} THE TACHYON COPYRIGHT HOLDER`,
        `# This file is distributed under the same license as the TACHYON package.`,
        `# ${translator}, ${now.getFullYear()}.`,
        '#',
        'msgid ""',
        'msgstr ""',
        `"Project-Id-Version: TACHYON\\n"`,
        `"Report-Msgid-Bugs-To: \\n"`,
        `"POT-Creation-Date: ${date} ${time}${tzOffset}\\n"`,
        `"PO-Revision-Date: ${date} ${time}${tzOffset}\\n"`,
        `"Last-Translator: ${translator}\\n"`,
        `"Language-Team: none\\n"`,
        `"Language: ${lang}\\n"`,
        `"MIME-Version: 1.0\\n"`,
        `"Content-Type: text/plain; charset=UTF-8\\n"`,
        `"Content-Transfer-Encoding: 8bit\\n"`,
        `"Plural-Forms: ${pluralForms}\\n"`,
        '',
    ];
}

function parsePo(content) {
    const lines = content.replace(/\r\n/g, '\n').replace(/\r/g, '\n').split('\n');
    const translations = new Map();
    let msgid = null;
    let msgstr = null;
    for (const line of lines) {
        if (line.startsWith('msgid ')) {
            try {
                msgid = JSON.parse(line.slice(6));
            } catch (e) {
                console.error('Failed to parse msgid on line:', line);
                throw e;
            }
        } else if (line.startsWith('msgstr ') && msgid !== null) {
            try {
                msgstr = JSON.parse(line.slice(7));
            } catch (e) {
                console.error('Failed to parse msgstr on line:', line);
                throw e;
            }
            translations.set(msgid, msgstr);
            msgid = null;
            msgstr = null;
        }
    }
    return translations;
}

function escapePoString(str) {
    return str.replace(/\\/g, '\\\\').replace(/"/g, '\\"');
}

async function generatePo() {
    const [callsRaw, oldPoRaw] = await Promise.all([
        fs.readFile(callsPath, 'utf8'),
        fs.readFile(poPath, 'utf8').catch(() => ''),
    ]);

    const calls = JSON.parse(callsRaw);
    const oldTranslations = parsePo(oldPoRaw);
    const header = getHeader(lang);

    const tsKeys = new Set(calls.map(({ key }) => key));

    // TypeScript-sourced strings (always present)
    const body = calls
        .map(({ key }) => {
            const msgid = key;
            const msgstr = oldTranslations.get(msgid) || '';
            return [
                `msgid "${escapePoString(msgid)}"`,
                `msgstr "${escapePoString(msgstr)}"`,
                ''
            ].join('\n');
        })
        .join('\n');

    // Extra strings from old PO (static JS files: settings.js, section.js, etc.)
    // Preserved so that locales:actualize doesn't wipe them.
    const extraBody = [...oldTranslations.entries()]
        .filter(([msgid]) => msgid !== '' && !tsKeys.has(msgid))
        .map(([msgid, msgstr]) => [
            `msgid "${escapePoString(msgid)}"`,
            `msgstr "${escapePoString(msgstr)}"`,
            ''
        ].join('\n'))
        .join('\n');

    const finalPo = header.join('\n') + '\n' + body + (extraBody ? '\n' + extraBody : '');

    await fs.writeFile(poPath, finalPo, 'utf8');
    const translated = [...oldTranslations.values()].filter(v => v !== '').length;
    const total = tsKeys.size + (oldTranslations.size - 1); // -1 for header entry
    console.log(`✅ Файл ${poPath} успешно сгенерирован. Переведено ${[...oldTranslations.keys()].length}/${calls.length}`);
}

generatePo().catch((err) => {
    console.error('Ошибка генерации PO файла:', err);
});
