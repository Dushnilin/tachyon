export const TACHYON_UCI_PACKAGE = 'tachyon';
export const TACHYON_LUCI_APP_VERSION = '__COMPILED_VERSION_VARIABLE__';
export const TACHYON_ACTION_PROVIDERS_AVAILABILITY_EVENT =
  'tachyon:action-providers-availability';
export const FAKEIP_CHECK_DOMAIN = 'fakeip.podkop.fyi';
export const IP_CHECK_DOMAIN = 'ip.podkop.fyi';
export const DEFAULT_LATENCY_TEST_URL = 'https://www.gstatic.com/generate_204';
export const LATENCY_TEST_URL_OPTIONS = [
  DEFAULT_LATENCY_TEST_URL,
  'https://cp.cloudflare.com/generate_204',
  'https://captive.apple.com',
  'https://connectivity-check.ubuntu.com',
];

export const DOMAIN_LIST_OPTIONS = {
  russia_inside: 'Россия (внутри)',
  geoblock: 'Геоблок (зарубежные сервисы)',
  block: 'Реестр РКН (прямые блокировки)',
  ru_blocked: 'Реестр РКН и Антизапрет (очищенный)',
  ru_blocked_all: 'Реестр РКН (полный)',
  antifilter: 'Antifilter Community',
  refilter: 'Re:filter',
  russia_outside: 'Россия (снаружи)',
  ru_whitelist: 'Белый список РФ (Direct)',
  ru_domains: 'Рунет и СНГ (Direct)',
  ru_only_inside: 'Только из РФ (Direct)',
  push: 'Push-уведомления (Direct)',
  ai_all: 'Нейросети и ИИ (все)',
  openai: 'OpenAI (ChatGPT / Sora)',
  anthropic: 'Anthropic (Claude AI)',
  google_ai: 'Google AI (Gemini / NotebookLM)',
  xai: 'xAI (Grok)',
  youtube: 'YouTube',
  twitch: 'Twitch',
  twitch_ads: 'Twitch (без рекламы и 1080p+)',
  spotify: 'Spotify',
  netflix: 'Netflix',
  tiktok: 'TikTok',
  hdrezka: 'HDRezka',
  anime: 'Аниме',
  pinterest: 'Pinterest',
  discord: 'Discord',
  telegram: 'Telegram',
  meta: 'Meta (Instagram / Facebook / Threads)',
  twitter: 'X (Twitter)',
  steam: 'Steam',
  epicgames: 'Epic Games (Fortnite / Unreal)',
  riot: 'Riot Games (Valorant / LoL)',
  origin: 'EA / Origin (EA App / Apex / BF)',
  roblox: 'Roblox',
  supercell: 'Supercell (Brawl Stars / Clash)',
  escapefromtarkov: 'Escape from Tarkov',
  faceit: 'FACEIT (CS2)',
  apple: 'Apple и iCloud',
  microsoft: 'Microsoft и Xbox',
  google_play: 'Google Play (Android)',
  github: 'GitHub',
  docker: 'Docker Hub',
  hodca: 'Центры сертификации SSL/TLS (CA)',
  cloudflare: 'Cloudflare (CDN и подсети)',
  cloudfront: 'Amazon CloudFront (CDN подсети)',
  fastly: 'Fastly CDN',
  hetzner: 'Hetzner (подсети ДЦ)',
  ovh: 'OVHcloud (подсети ДЦ)',
  digitalocean: 'DigitalOcean (подсети ДЦ)',
  news: 'СМИ и новости',
  torrent: 'Торренты и трекеры',
  tor: 'Tor и анонимайзеры',
  porn: 'Сайты 18+ (Adult)',
  ads_hagezi_pro: 'Реклама и трекеры (Block)',
  win_spy: 'Телеметрия Windows (Block)',
};

export const DOMAIN_LIST_HINTS: Record<string, string> = {
  russia_inside:
    '[Маршрут: В Прокси / VPN или Обход DPI] Сводный реестр заблокированных и ограниченных в РФ ресурсов (соцсети, СМИ, зарубежные платформы и геоблок)',
  geoblock:
    '[Маршрут: Только в Прокси / VPN — геоблок по IP] 150+ зарубежных сервисов, закрывших доступ с российских IP: PayPal, Notion, Canva, Trello, Jira, Zoom, Intel, Dell, Coursera, JetBrains, Adobe, GitLab',
  block:
    '[Маршрут: В Прокси / VPN или Обход DPI] Домены и сайты из официальной выгрузки запрещённых ресурсов Роскомнадзора',
  ru_blocked:
    '[Маршрут: В Прокси / VPN или Обход DPI] Очищенный и дедуплицированный реестр заблокированных в РФ доменов (Антизапрет + выгрузка РКН без мёртвых сайтов)',
  ru_blocked_all:
    '[Маршрут: В Прокси / VPN или Обход DPI] Полная выгрузка доменов и зеркал из реестра блокировок РФ (1.3M+ доменов; на роутерах ≤ 512 МБ ОЗУ автоматически используется оптимизированный ru_blocked для защиты от OOM)',
  antifilter:
    '[Маршрут: В Прокси / VPN или Обход DPI] Народный список доменов и сервисов, заблокированных РКН или замедляемых на ТСПУ в России',
  refilter:
    '[Маршрут: В Прокси / VPN] Выверенный список реальных блокировок РКН и геоблока западных сервисов без избыточных доменов',
  russia_outside:
    '[Маршрут: В Прокси с IP РФ (из-за рубежа) или Direct (в РФ)] Сервисы РФ: Госуслуги, банки, Ozon, WB, Кинопоиск, Иви, Wink, РЖД',
  ru_whitelist:
    '[Маршрут: Напрямую (Direct)] Госуслуги, ФНС, банки РФ (Сбер, Т-Банк, Альфа, ВТБ), Ozon, WB, Авито, Яндекс, VK, РЖД, капчи и корневые сертификаты',
  ru_domains:
    '[Маршрут: Напрямую (Direct)] Все национальные зоны (.ru, .рф, .su, .by, .kz) и домены компаний РФ (Яндекс, VK, Mail.ru, Kaspersky, 1С, 2ГИС)',
  ru_only_inside:
    '[Маршрут: Строго Напрямую (Direct)] Госпорталы, банки, суды, ЕМИАС и сервисы ЖКХ РФ, жёстко блокирующие вход с зарубежных и VPN IP-адресов',
  push: '[Маршрут: Напрямую (Direct)] Серверы мобильных и системных push-уведомлений: Apple APNs, Google FCM, Huawei, Xiaomi, Samsung, Windows WNS',
  ai_all:
    '[Маршрут: Только в Прокси / VPN — геоблок по IP] Все зарубежные ИИ: OpenAI (ChatGPT, Sora), Claude, Gemini, Grok, Perplexity, Copilot, Cursor, Midjourney, ElevenLabs, Suno, DeepSeek, Hugging Face',
  openai:
    '[Маршрут: Только в Прокси / VPN — геоблок по IP] ChatGPT, Sora, GPT API, o1/o3 и статика (chatgpt.com, openai.com, sora.com, oaistatic.com, oaiusercontent.com)',
  anthropic:
    '[Маршрут: Только в Прокси / VPN — геоблок по IP] Нейросеть Claude AI, Claude Code, Console и API (claude.ai, anthropic.com, claudeusercontent.com)',
  google_ai:
    '[Маршрут: Только в Прокси / VPN — геоблок по IP] Gemini, AI Studio, NotebookLM, DeepMind и Vertex AI (gemini.google.com, aistudio.google.com, notebooklm.google.com)',
  xai: '[Маршрут: Только в Прокси / VPN — геоблок по IP] Нейросеть Grok от xAI (grok.com, x.ai, api.x.ai и медиа-CDN)',
  youtube:
    '[Маршрут: В Обход DPI (Desync / Zapret) или Прокси / VPN] Видеосервис YouTube, YouTube Music, Studio и кэш-серверы видеопотоков (youtube.com, youtu.be, googlevideo.com, ytimg.com, ggpht.com)',
  twitch:
    '[Маршрут: В Прокси / VPN или Обход DPI] Стриминговая платформа, видеопотоки и чат (twitch.tv, ttvnw.net, jtvnw.net, live-video.net)',
  twitch_ads:
    '[Маршрут: Только в Прокси / VPN] Серверы манифестов качества видео и рекламы Twitch (usher.ttvnw.net, gql.twitch.tv) — отключает рекламу и разблокирует 1080p60/1440p без проксирования видеопотока',
  spotify:
    '[Маршрут: Только в Прокси / VPN — геоблок по IP] Музыкальный стриминг, аудио-CDN и клиентские API (spotify.com, scdn.co, spotifycdn.com, akamaized.net)',
  netflix:
    '[Маршрут: Только в Прокси / VPN — геоблок по IP] Онлайн-кинотеатр, видеопотоки и статика (netflix.com, nflxvideo.net, nflximg.net, nflxext.com, fast.com)',
  tiktok:
    '[Маршрут: Только в Прокси / VPN — региональный блок РФ] Приложение, веб-версия и медиа-CDN ByteDance (tiktok.com, tiktokv.com, tiktokcdn.com) для снятия ограничений на новые видео',
  hdrezka:
    '[Маршрут: В Прокси / VPN или Обход DPI] Онлайн-кинотеатр HDRezka, видео-балансеры (Voidboost) и актуальные зеркала (rezka.ag, hdrezka.ag, voidboost.cc)',
  anime:
    '[Маршрут: В Прокси / VPN или Обход DPI] Популярные аниме-порталы и плееры: Shikimori, AnimeGO, Jut.su, Kodik, Anilibria, Crunchyroll, MyAnimeList',
  pinterest:
    '[Маршрут: В Прокси / VPN или Обход DPI] Визуальная соцсеть и серверы картинок (pinterest.com, pin.it, i.pinimg.com — лечит незагрузку фото на ТСПУ)',
  discord:
    '[Маршрут: В Прокси / VPN или Обход DPI] Мессенджер, текстовые чаты, CDN вложений и голосовые шлюзы (discord.com, discord.gg, discordapp.net, discord.media + подсети)',
  telegram:
    '[Маршрут: В Прокси / VPN] Мессенджер, веб-клиенты, Telegraph и IPv4/IPv6-подсети всех датацентров DC1–DC5 (telegram.org, t.me, telesco.pe)',
  meta: '[Маршрут: В Прокси / VPN] Instagram, Facebook, Threads, Messenger и медиа-серверы (instagram.com, facebook.com, fbcdn.net, cdninstagram.com + подсети)',
  twitter:
    '[Маршрут: В Прокси / VPN или Обход DPI] Соцсеть X / Twitter, короткие ссылки и медиа-CDN (x.com, twitter.com, t.co, twimg.com + подсети)',
  steam:
    '[Маршрут: Напрямую (Direct) или в Прокси для смены региона магазина] Магазин, сообщество, инвентарь, чат и CDN загрузок Valve (steampowered.com, steamcommunity.com, steamstatic.com, steamcontent.com)',
  epicgames:
    '[Маршрут: В Прокси / VPN (для раздач/покупок) или Direct] Epic Games Store, Fortnite, Rocket League, Unreal Engine и античит EasyAntiCheat (epicgames.com, unrealengine.com, fortnite.com, easy.ac)',
  riot: '[Маршрут: В Прокси / VPN или Direct] Valorant, League of Legends, TFT, Riot Client и Vanguard (riotgames.com, playvalorant.com, leagueoflegends.com, pvp.net)',
  origin:
    '[Маршрут: В Прокси / VPN] EA App, Origin, Apex Legends, Battlefield, EA Sports FC и Sims (ea.com, origin.com, tnt-ea.com, apexlegends.com)',
  roblox:
    '[Маршрут: В Прокси / VPN или Обход DPI] Игровая платформа, лаунчер, Roblox Studio и игровые IP-подсети (roblox.com, rbxcdn.com, robloxlabs.com)',
  supercell:
    '[Маршрут: Только в Прокси / VPN — геоблок по IP] Brawl Stars, Clash Royale, Clash of Clans, Squad Busters и авторизация Supercell ID (обход геоблока для РФ и РБ)',
  escapefromtarkov:
    '[Маршрут: В Прокси / VPN или Direct] Лаунчер, сайт, API профилей и серверы Battlestate Games (escapefromtarkov.com, tarkov.com, battlestategames.com)',
  faceit:
    '[Маршрут: В Прокси / VPN или Обход DPI] Киберспортивная платформа CS2, античит и матчмейкинг (faceit.com, faceit-cdn.net)',
  apple:
    '[Маршрут: Напрямую (Direct) или в Прокси для Apple Intelligence] App Store, iCloud, обновления iOS/macOS, Apple Music, TV+ и Apple Intelligence (apple.com, icloud.com, mzstatic.com, cdn-apple.com)',
  microsoft:
    '[Маршрут: В Прокси / VPN (для Copilot, Xbox и ISO Windows) или Direct] Windows Update, Office 365, OneDrive, Xbox Live, Teams, Visual Studio и Azure (microsoft.com, live.com, office.com, xbox.com)',
  google_play:
    '[Маршрут: В Прокси / VPN (для платных приложений и смены региона) или Direct] Магазин приложений Android и серверы скачивания APK (play.google.com, gvt1.com, gvt2.com)',
  github:
    '[Маршрут: В Прокси / VPN (для Copilot и при сбоях ТСПУ) или Direct] Репозитории, GitHub Actions, Packages, Pages, Raw и Gist (github.com, githubusercontent.com, githubassets.com, ghcr.io)',
  docker:
    '[Маршрут: Только в Прокси / VPN — геоблок по IP] Docker Hub, реестр контейнеров и пакеты (docker.com, docker.io, registry-1.docker.io, download.docker.com)',
  hodca:
    '[Маршрут: В Прокси / VPN] Серверы проверки SSL-сертификатов (OCSP / CRL): DigiCert, Sectigo, Comodo, GlobalSign, Let’s Encrypt (устраняет долгую загрузку HTTPS из-за геоблока)',
  cloudflare:
    '[Маршрут: В Прокси / VPN или Обход DPI] IPv4/IPv6-подсети и домены Cloudflare CDN (обход блокировки TLS ECH и сайтов за Cloudflare на ТСПУ)',
  cloudfront:
    '[Маршрут: В Прокси / VPN] IP-подсети глобальной CDN-сети Amazon CloudFront (AWS), часто попадающие под веерные блокировки',
  fastly:
    '[Маршрут: В Прокси / VPN] Домены и подсети CDN-провайдера Fastly (fastly.net, fastlylb.net, fsdn.com), используемого множеством зарубежных сайтов',
  hetzner:
    '[Маршрут: В Прокси / VPN] IP-подсети европейских датацентров Hetzner (Германия и Финляндия), блокируемые на ТСПУ целыми диапазонами',
  ovh: '[Маршрут: В Прокси / VPN] IP-подсети европейских датацентров OVHcloud, на которых размещены игровые серверы и веб-проекты',
  digitalocean:
    '[Маршрут: В Прокси / VPN] IP-подсети облачного хостинга DigitalOcean, большая часть которых заблокирована или ограничена в РФ',
  news: '[Маршрут: В Прокси / VPN или Обход DPI] Заблокированные независимые российские и мировые информационные агентства и медиа (Meduza, BBC, DW, Euronews, Радио Свобода)',
  torrent:
    '[Маршрут: В Обход DPI (Desync / Zapret) или Прокси] Торрент-трекеры, индексаторы и анонсеры: RuTracker, Rutor, NNM-Club, Kinozal, Rustorka, LostFilm, The Pirate Bay, 1337x, Nyaa',
  tor: '[Маршрут: В Прокси / VPN] Домены и узлы сети Tor, каталогов мостов, I2P, Tails, Whonix и анонимайзеров',
  porn: '[Маршрут: В Прокси / VPN или Обход DPI] Крупнейшие сайты и видео-CDN 18+: Pornhub, XVideos, xHamster, OnlyFans, Fansly, Chaturbate',
  ads_hagezi_pro:
    '[Маршрут: Блокировать (Block)] Комплексная фильтрация рекламных сетей, аналитики, трекеров и фишинга Hagezi Multi PRO',
  win_spy:
    '[Маршрут: Блокировать (Block)] Серверы слежки, телеметрии, отчётов об ошибках и рекламы Windows 10/11',
};

export const DNS_SERVERS_BY_PROTOCOL: Record<string, Record<string, string>> = {
  udp: {
    '1.1.1.1': '1.1.1.1 (Cloudflare)',
    '1.0.0.1': '1.0.0.1 (Cloudflare Secondary)',
    '1.1.1.2': '1.1.1.2 (Cloudflare Security)',
    '1.1.1.3': '1.1.1.3 (Cloudflare Family)',
    '8.8.8.8': '8.8.8.8 (Google)',
    '8.8.4.4': '8.8.4.4 (Google Secondary)',
    '9.9.9.9': '9.9.9.9 (Quad9 Filtered)',
    '149.112.112.112': '149.112.112.112 (Quad9 Secondary)',
    '9.9.9.10': '9.9.9.10 (Quad9 Unsecured)',
    '94.140.14.14': '94.140.14.14 (AdGuard Default)',
    '94.140.15.15': '94.140.15.15 (AdGuard Default Secondary)',
    '94.140.14.140': '94.140.14.140 (AdGuard Non-filtering)',
    '94.140.14.15': '94.140.14.15 (AdGuard Family)',
    '76.76.2.0': '76.76.2.0 (Control D Uncensored)',
    '76.76.2.1': '76.76.2.1 (Control D Malware)',
    '76.76.2.2': '76.76.2.2 (Control D Adblock)',
    '194.242.2.2': '194.242.2.2 (Mullvad No-Logs)',
    '194.242.2.3': '194.242.2.3 (Mullvad Adblock)',
    '194.242.2.4': '194.242.2.4 (Mullvad Extended)',
    '185.222.222.222': '185.222.222.222 (DNS.SB)',
    '193.110.81.0': '193.110.81.0 (DNS0.EU Zero)',
    '193.17.47.1': '193.17.47.1 (CZ.NIC ODVR)',
    '208.67.222.222': '208.67.222.222 (OpenDNS)',
    '223.5.5.5': '223.5.5.5 (AliDNS)',
    '185.228.168.9': '185.228.168.9 (CleanBrowsing Security)',
    '77.88.8.8': '77.88.8.8 (Yandex)',
    '77.88.8.1': '77.88.8.1 (Yandex Secondary)',
    '77.88.8.88': '77.88.8.88 (Yandex Safe)',
  },
  doh: {
    'https://cloudflare-dns.com/dns-query': 'Cloudflare',
    'https://security.cloudflare-dns.com/dns-query': 'Cloudflare Security',
    'https://family.cloudflare-dns.com/dns-query': 'Cloudflare Family',
    'https://dns.google/dns-query': 'Google',
    'https://dns.quad9.net/dns-query': 'Quad9 (Filtered)',
    'https://dns10.quad9.net/dns-query': 'Quad9 (Unfiltered)',
    'https://dns.adguard-dns.com/dns-query': 'AdGuard Default',
    'https://unfiltered.adguard-dns.com/dns-query': 'AdGuard Non-filtering',
    'https://family.adguard-dns.com/dns-query': 'AdGuard Family',
    'https://dns.mullvad.net/dns-query': 'Mullvad Base',
    'https://adblock.dns.mullvad.net/dns-query': 'Mullvad Adblock',
    'https://extended.dns.mullvad.net/dns-query': 'Mullvad Extended',
    'https://dns.nextdns.io/dns-query': 'NextDNS',
    'https://freedns.controld.com/p0': 'Control D Uncensored',
    'https://freedns.controld.com/p1': 'Control D Malware',
    'https://freedns.controld.com/p2': 'Control D Adblock',
    'https://doh.dns.sb/dns-query': 'DNS.SB',
    'https://zero.dns0.eu': 'DNS0.EU Zero',
    'https://odvr.nic.cz/doh': 'CZ.NIC ODVR',
    'https://dns.alidns.com/dns-query': 'AliDNS',
    'https://doh.opendns.com/dns-query': 'OpenDNS',
    'https://doh.cleanbrowsing.org/doh/security-filter/':
      'CleanBrowsing Security',
    'https://doh.cleanbrowsing.org/doh/family-filter/': 'CleanBrowsing Family',
    'https://common.dot.dns.yandex.net/dns-query': 'Yandex',
  },
  dot: {
    '1.1.1.1': '1.1.1.1 (Cloudflare)',
    '1.0.0.1': '1.0.0.1 (Cloudflare Secondary)',
    'security.cloudflare-dns.com': 'Cloudflare Security',
    'family.cloudflare-dns.com': 'Cloudflare Family',
    'dns.google': 'Google',
    'dns.quad9.net': 'Quad9 (Filtered)',
    'dns10.quad9.net': 'Quad9 (Unfiltered)',
    'dns.adguard-dns.com': 'AdGuard Default',
    'unfiltered.adguard-dns.com': 'AdGuard Non-filtering',
    'family.adguard-dns.com': 'AdGuard Family',
    'dns.mullvad.net': 'Mullvad Base',
    'adblock.dns.mullvad.net': 'Mullvad Adblock',
    'extended.dns.mullvad.net': 'Mullvad Extended',
    'dns.nextdns.io': 'NextDNS',
    'p0.freedns.controld.com': 'Control D Uncensored',
    'p1.freedns.controld.com': 'Control D Malware',
    'p2.freedns.controld.com': 'Control D Adblock',
    'dot.sb': 'DNS.SB',
    'zero.dns0.eu': 'DNS0.EU Zero',
    'odvr.nic.cz': 'CZ.NIC ODVR',
    'dns.alidns.com': 'AliDNS',
    'security-filter-dns.cleanbrowsing.org': 'CleanBrowsing Security',
    'family-filter-dns.cleanbrowsing.org': 'CleanBrowsing Family',
    'common.dot.dns.yandex.net': 'Yandex',
    'safe.dot.dns.yandex.net': 'Yandex Safe',
  },
  doq: {
    '1.1.1.1:784': 'Cloudflare',
    '1.0.0.1:784': 'Cloudflare Secondary',
    'dns.google:784': 'Google',
    'dns.adguard-dns.com:785': 'AdGuard Default',
    'unfiltered.adguard-dns.com:785': 'AdGuard Non-filtering',
    'dns.mullvad.net:784': 'Mullvad Base',
    'adblock.dns.mullvad.net:784': 'Mullvad Adblock',
    'dns.nextdns.io:784': 'NextDNS',
    'p0.freedns.controld.com:853': 'Control D Uncensored',
    'p2.freedns.controld.com:853': 'Control D Adblock',
    'zero.dns0.eu:853': 'DNS0.EU Zero',
  },
};
export const BOOTSTRAP_DNS_SERVER_OPTIONS = {
  '1.1.1.1': '1.1.1.1 (Cloudflare DNS)',
  '1.0.0.1': '1.0.0.1 (Cloudflare DNS)',
  '8.8.8.8': '8.8.8.8 (Google DNS)',
  '8.8.4.4': '8.8.4.4 (Google DNS)',
  '9.9.9.9': '9.9.9.9 (Quad9 DNS)',
  '149.112.112.112': '149.112.112.112 (Quad9 DNS)',
  '94.140.14.14': '94.140.14.14 (AdGuard DNS)',
  '94.140.15.15': '94.140.15.15 (AdGuard DNS)',
  '76.76.2.0': '76.76.2.0 (Control D)',
  '194.242.2.2': '194.242.2.2 (Mullvad DNS)',
  '185.222.222.222': '185.222.222.222 (DNS.SB)',
  '193.110.81.0': '193.110.81.0 (DNS0.EU)',
  '193.17.47.1': '193.17.47.1 (CZ.NIC ODVR)',
  '208.67.222.222': '208.67.222.222 (OpenDNS)',
  '223.5.5.5': '223.5.5.5 (AliDNS)',
  '77.88.8.8': '77.88.8.8 (Yandex DNS)',
  '77.88.8.1': '77.88.8.1 (Yandex DNS)',
};

export const COMMAND_TIMEOUT = 10000; // 10 seconds
