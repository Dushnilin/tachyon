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
                msgid = parseUnquotedPoValue(line, 'msgid');
            }
        } else if (line.startsWith('msgstr ') && msgid !== null) {
            try {
                msgstr = JSON.parse(line.slice(7));
            } catch (e) {
                msgstr = parseUnquotedPoValue(line, 'msgstr');
            }
            translations.set(msgid, msgstr);
            msgid = null;
            msgstr = null;
        }
    }
    return translations;
}

function parseUnquotedPoValue(line, prefix) {
    const match = line.match(new RegExp(`^${prefix} "(.+)"$`));
    if (!match) {
        console.error('Failed to parse line:', line);
        throw new Error('Failed to parse PO line');
    }
    return match[1]
        .replace(/\\n/g, '\n')
        .replace(/\\t/g, '\t')
        .replace(/\\"/g, '"')
        .replace(/\\\\/g, '\\');
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

    const callKeys = new Set(calls.map(({ key }) => key));

    const bodyParts = [];

    // First: all keys from calls.json (source-of-truth for what's used in code)
    for (const { key } of calls) {
        const msgid = key;
        const msgstr = oldTranslations.get(msgid) || '';
        bodyParts.push(
            `msgid "${escapePoString(msgid)}"\nmsgstr "${escapePoString(msgstr)}"`
        );
    }

    // Second: preserve existing entries NOT in calls.json (manual additions, legacy strings)
    for (const [msgid, msgstr] of oldTranslations) {
        if (!callKeys.has(msgid) && msgid !== '') {
            bodyParts.push(
                `msgid "${escapePoString(msgid)}"\nmsgstr "${escapePoString(msgstr)}"`
            );
        }
    }

    const header = getHeader(lang);
    const finalPo = header.join('\n') + '\n' + bodyParts.join('\n\n') + '\n';

    await fs.writeFile(poPath, finalPo, 'utf8');
    const translated = [...oldTranslations.values()].filter(v => v !== '').length;
    console.log(`✅ Файл ${poPath} успешно сгенерирован. Переведено ${translated}/${calls.length}`);
}

generatePo().catch((err) => {
    console.error('Ошибка генерации PO файла:', err);
});
