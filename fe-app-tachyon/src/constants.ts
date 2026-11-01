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
  ukraine_inside: 'Украина (внутри)',
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
  openrouter: 'OpenRouter, Poe, Groq и Mistral',
  cursor: 'Cursor, OpenCode, Windsurf и AI-кодинг',
  perplexity: 'Perplexity AI и AI-поиск',
  copilot: 'Microsoft & GitHub Copilot',
  deepseek: 'DeepSeek, Kimi, Qwen и Manus',
  midjourney: 'Midjourney, Flux и Civitai (AI-графика)',
  elevenlabs: 'ElevenLabs, Suno, Udio и Runway (AI-аудио/видео)',
  huggingface: 'Hugging Face, Ollama и Character.AI',
  youtube: 'YouTube',
  twitch: 'Twitch',
  twitch_ads: 'Twitch (без рекламы и 1080p+)',
  spotify: 'Spotify',
  soundcloud_music: 'SoundCloud, Deezer, Tidal и Genius',
  netflix: 'Netflix',
  rutracker_lampa: 'RuTracker, Lampa, KinoPub и Flibusta',
  patreon_creators: 'Patreon, Medium, Substack, DeviantArt и Pixiv',
  tiktok: 'TikTok',
  hdrezka: 'HDRezka',
  anime: 'Аниме',
  pinterest: 'Pinterest',
  discord: 'Discord',
  telegram: 'Telegram',
  meta: 'Meta (Instagram / Facebook / Threads)',
  whatsapp: 'WhatsApp (отдельно от Meta)',
  messengers: 'Signal, Viber, TeamSpeak и Matrix',
  twitter: 'X (Twitter)',
  reddit: 'Reddit',
  zoom_teams: 'Zoom, Google Meet, MS Teams, Webex и Slack',
  google_meet: 'Google Meet',
  linkedin: 'LinkedIn, Glassdoor и Indeed',
  games_all: 'Игры и лаунчеры (все)',
  steam: 'Steam',
  epicgames: 'Epic Games (Fortnite / Unreal)',
  ubisoft: 'Ubisoft Connect (Uplay / R6 Siege)',
  warthunder: 'War Thunder и Gaijin (Enlisted / Crossout)',
  blizzard: 'Battle.net (Blizzard / WoW / Overwatch / Diablo)',
  riot: 'Riot Games (Valorant / LoL)',
  origin: 'EA / Origin (EA App / Apex / BF)',
  xbox: 'Xbox Live, Game Pass и Bethesda',
  playstation: 'PlayStation Network (PSN / PS5 / PS4)',
  nintendo: 'Nintendo Switch (eShop / Switch Online)',
  gog: 'GOG и CD Projekt RED (Cyberpunk / Ведьмак)',
  wargaming: 'Wargaming (World of Tanks / Warships EU)',
  hoyoverse: 'HoYoverse и Kuro Games (Genshin / HSR / ZZZ)',
  minecraft: 'Minecraft и моддинг (Mojang / CurseForge / Modrinth)',
  rockstar: 'Rockstar Games и 2K (GTA Online / RDR2 / FiveM)',
  pubg: 'PUBG, THE FINALS, DayZ, VRChat, PoE и Warframe',
  roblox: 'Roblox',
  supercell: 'Supercell (Brawl Stars / Clash)',
  escapefromtarkov: 'Escape from Tarkov',
  faceit: 'FACEIT (CS2)',
  apple: 'Apple и iCloud',
  microsoft: 'Microsoft и Xbox',
  google_play: 'Google Play (Android)',
  github: 'GitHub',
  docker: 'Docker Hub',
  jetbrains: 'JetBrains, Android Studio и Gradle',
  gitlab_notion: 'GitLab, Atlassian (Jira, Trello), Notion и Miro',
  figma_adobe: 'Figma, Canva, Adobe Creative Cloud и Framer',
  pkg_registries: 'Пакетные менеджеры (HashiCorp, npm, PyPI, Crates, Go)',
  hodca: 'Центры сертификации SSL/TLS (CA)',
  cloudflare: 'Cloudflare (CDN и подсети)',
  cloudfront: 'Amazon CloudFront (CDN подсети)',
  fastly: 'Fastly CDN',
  hetzner: 'Hetzner (подсети ДЦ)',
  ovh: 'OVHcloud (подсети ДЦ)',
  digitalocean: 'DigitalOcean (подсети ДЦ)',
  speedtest: 'Speedtest и проверка IP (Ookla, Fast.com, 2ip, Whoer)',
  crypto: 'Криптовалюты и Web3 (Bybit, Binance, OKX, TradingView)',
  paypal_fintech: 'PayPal, Wise, Revolut и Stripe (Финтех)',
  news: 'СМИ и новости',
  torrent: 'Торренты и трекеры',
  tor: 'Tor и анонимайзеры',
  porn: 'Сайты 18+ (Adult)',
  ads_hagezi_pro: 'Реклама и трекеры (Block)',
  win_spy: 'Телеметрия Windows (Block)',
  xiaomi_smarttv_ads: 'Реклама Xiaomi HyperOS/MIUI и Smart TV (Block)',
};

export const DOMAIN_LIST_HINTS: Record<string, string> = {
  russia_inside:
    '[Маршрут: В Прокси / VPN или Обход DPI] Сводный реестр заблокированных и ограниченных в РФ ресурсов (соцсети, СМИ, зарубежные платформы и геоблок)',
  ukraine_inside:
    '[Маршрут: В Прокси / VPN или Обход DPI] Сводный список заблокированных и ограниченных в Украине ресурсов и сервисов',
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
  openrouter:
    '[Маршрут: Только в Прокси / VPN — геоблок по IP] Агрегаторы нейросетей и провайдеры облачного инференса: OpenRouter (openrouter.ai), Poe (poe.com), Groq (groq.com), Mistral AI (mistral.ai), Together AI, Fireworks AI, DeepInfra, Cerebras, Replicate, Fal.ai, Chutes, Cohere и LMSYS Arena',
  cursor:
    '[Маршрут: Только в Прокси / VPN — геоблок по IP] Инструменты ИИ-разработки и кодинг-агенты: Cursor (cursor.com, cursorapi.com), OpenCode (opencode.ai, models.dev), Windsurf / Codeium (windsurf.com, codeium.com), JetBrains AI (grazie.ai, jetbrains.ai), Trae, Cline, Roo Code, Kilo Code, Aider, Lovable, Bolt.new, v0.dev, Devin, Replit, CodeRabbit и Context7',
  perplexity:
    '[Маршрут: Только в Прокси / VPN — геоблок по IP] Поисковые и исследовательские ИИ-системы: Perplexity (perplexity.ai, pplx.ai), You.com, Genspark, Consensus, Elicit и Scite',
  copilot:
    '[Маршрут: Только в Прокси / VPN — геоблок по IP] Все домены автодополнения кода GitHub Copilot (githubcopilot.com, copilot-proxy.githubusercontent.com) и ассистента Microsoft Copilot в Windows, Edge и Office 365 (copilot.microsoft.com, sydney.bing.com)',
  deepseek:
    '[Маршрут: В Прокси / VPN] Домены DeepSeek (deepseek.com, chat.deepseek.com, api.deepseek.com), Moonshot Kimi (kimi.ai), Alibaba Qwen Chat (chat.qwen.ai), MiniMax, Z.ai, Manus (manus.im) и Dify',
  midjourney:
    '[Маршрут: Только в Прокси / VPN — геоблок по IP] Платформы генерации графики, дизайна и 3D: Midjourney (midjourney.com), Civitai (civitai.com), Black Forest Labs / Flux (bfl.ai), Leonardo.ai, Ideogram, Krea, Recraft, Magnific, Stability AI, ComfyUI Registry, OpenArt, Tripo3D и Meshy',
  elevenlabs:
    '[Маршрут: Только в Прокси / VPN — геоблок по IP] Сервисы генерации звука, клонирования голоса, музыки и видео: ElevenLabs (elevenlabs.io), Suno (suno.com), Udio (udio.com), Runway (runwayml.com), Kling AI (klingai.com), Luma Dream Machine, Pika, Hailuo Video, HeyGen, Synthesia, Vidu и PixVerse',
  huggingface:
    '[Маршрут: В Прокси / VPN] Репозитории моделей и датасетов Hugging Face (huggingface.co, hf.co), каталоги локальных LLM (ollama.com, lmstudio.ai, openwebui.com), платформы ролевых ИИ-персонажей (Character.AI, JanitorAI, Chub, NovelAI) и ML-инфраструктура (Weights & Biases, Kaggle, LangChain)',
  youtube:
    '[Маршрут: В Обход DPI (Desync / Zapret) или Прокси / VPN] Видеосервис YouTube, YouTube Music, Studio и кэш-серверы видеопотоков (youtube.com, youtu.be, googlevideo.com, ytimg.com, ggpht.com)',
  twitch:
    '[Маршрут: В Прокси / VPN или Обход DPI] Стриминговая платформа, видеопотоки и чат (twitch.tv, ttvnw.net, jtvnw.net, live-video.net)',
  twitch_ads:
    '[Маршрут: Только в Прокси / VPN] Серверы манифестов качества видео и рекламы Twitch (usher.ttvnw.net, gql.twitch.tv) — отключает рекламу и разблокирует 1080p60/1440p без проксирования видеопотока',
  spotify:
    '[Маршрут: Только в Прокси / VPN — геоблок по IP] Музыкальный стриминг, аудио-CDN и клиентские API (spotify.com, scdn.co, spotifycdn.com, akamaized.net)',
  soundcloud_music:
    '[Маршрут: В Прокси / VPN] Музыкальные сервисы и энциклопедии, заблокированные РКН или закрытые геоблоком: SoundCloud (soundcloud.com, sndcdn.com), Deezer (deezer.com, dzcdn.net), Tidal (tidal.com), Qobuz, Bandcamp, Genius (genius.com), Last.fm, Mixcloud, TuneIn и Discogs',
  netflix:
    '[Маршрут: Только в Прокси / VPN — геоблок по IP] Онлайн-кинотеатр, видеопотоки и статика (netflix.com, nflxvideo.net, nflximg.net, nflxext.com, fast.com)',
  rutracker_lampa:
    "[Маршрут: В Прокси / VPN или Обход DPI] Народный набор для дома и Android TV: зеркала RuTracker, Rutor, NNM-Club, Kinozal, LostFilm, KinoPub, балансеры и плагины Lampa (Filmix, Cub, BWA, Zetflix), а также книжные и научные библиотеки (Flibusta, Coollib, Z-Library, Anna's Archive, LibGen, Sci-Hub)",
  patreon_creators:
    '[Маршрут: В Прокси / VPN] Платформы поддержки авторов, блогов и цифрового арта, заблокированные в РФ или закрытые геоблоком: Patreon (patreon.com), Medium (medium.com), Substack, DeviantArt, ArtStation, Pixiv (pixiv.net, pximg.net), Gumroad, Ko-fi, AO3, Ficbook, Goodreads и Letterboxd',
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
  whatsapp:
    '[Маршрут: В Прокси / VPN или Direct] Все домены WhatsApp (whatsapp.com, whatsapp.net, wa.me) отдельно от Instagram и Facebook: позволяет точечно маршрутизировать звонки и сообщения WhatsApp без проксирования тяжёлого видео-трафика Instagram',
  messengers:
    '[Маршрут: В Прокси / VPN] Мессенджеры и голосовые серверы, заблокированные РКН или используемые как замена Discord: Signal (signal.org, whispersystems.org), Viber (viber.com), TeamSpeak 3/5 (teamspeak.com, myteamspeak.com), Guilded, Element / Matrix, Threema, Session, SimpleX и Wire',
  twitter:
    '[Маршрут: В Прокси / VPN или Обход DPI] Соцсеть X / Twitter, короткие ссылки и медиа-CDN (x.com, twitter.com, t.co, twimg.com + подсети)',
  reddit:
    '[Маршрут: В Прокси / VPN или Обход DPI] Все домены и медиа-CDN платформы Reddit: reddit.com, redd.it, v.redd.it, i.redd.it, redditmedia.com и redditstatic.com (устраняет зависание видео и картинок)',
  zoom_teams:
    '[Маршрут: Напрямую (Direct) или в Прокси при геоблоке] Платформы удалённой работы и видеозвонков: Zoom (zoom.us), Google Meet (meet.google.com + STUN/TURN подсети), Microsoft Teams, Cisco Webex, Slack (slack.com), Loom, Gather, Whereby и Jitsi',
  google_meet:
    '[Маршрут: Напрямую (Direct) или в Прокси] Домены и медиа-подсети видеоконференций Google Meet (meet.google.com, stun.l.google.com)',
  linkedin:
    '[Маршрут: В Прокси / VPN] Профессиональная соцсеть LinkedIn (linkedin.com, licdn.com, lnkd.in, slideshare.net), заблокированная в РФ, а также международные карьерные порталы Glassdoor, Indeed, Wellfound и Levels.fyi',
  games_all:
    '[Маршрут: В Прокси / VPN или Direct] Единый сводный список всех популярных игровых лаунчеров, магазинов, античитов (BattlEye, EasyAntiCheat) и серверов: Steam, Epic Games, Ubisoft Connect, War Thunder / Gaijin, Battle.net / Blizzard, EA App / Origin, Riot Games, Xbox Live, PlayStation Network, Nintendo, GOG, Wargaming, HoYoverse, Minecraft, Rockstar, Roblox, Supercell, Escape from Tarkov, FACEIT и PUBG',
  steam:
    '[Маршрут: Напрямую (Direct) или в Прокси для смены региона магазина] Магазин, сообщество, инвентарь, чат и CDN загрузок Valve (steampowered.com, steamcommunity.com, steamstatic.com, steamcontent.com)',
  epicgames:
    '[Маршрут: В Прокси / VPN (для раздач/покупок) или Direct] Epic Games Store, Fortnite, Rocket League, Unreal Engine и античит EasyAntiCheat (epicgames.com, unrealengine.com, fortnite.com, easy.ac)',
  ubisoft:
    '[Маршрут: В Прокси / VPN] Домены лаунчера Ubisoft Connect (Uplay), серверов авторизации, облачных сохранений, CDN обновлений и античитов (ubisoft.com, ubi.com, uplay.com, rainbowsix.com, battleye.com)',
  warthunder:
    '[Маршрут: В Прокси / VPN или Direct] Домены игр и лаунчера Gaijin Entertainment: War Thunder (warthunder.com), Enlisted (enlisted.net), Crossout (crossout.net), CRSED, Star Conflict, магазин Gaijin.Net и серверы обновлений',
  blizzard:
    '[Маршрут: В Прокси / VPN] Домены лаунчера Battle.net, магазина и серверов Activision Blizzard: battle.net, blizzard.com, activision.com, callofduty.com, worldofwarcraft.com, playoverwatch.com, diablo4.com, playhearthstone.com',
  riot: '[Маршрут: В Прокси / VPN или Direct] Valorant, League of Legends, TFT, Riot Client и Vanguard (riotgames.com, playvalorant.com, leagueoflegends.com, pvp.net)',
  origin:
    '[Маршрут: В Прокси / VPN] EA App, Origin, Apex Legends, Battlefield, EA Sports FC и Sims (ea.com, origin.com, tnt-ea.com, apexlegends.com)',
  xbox: '[Маршрут: В Прокси / VPN] Экосистема Xbox и игровых студий Microsoft / Bethesda: xbox.com, xboxlive.com, gamepass.com, xboxservices.com, forzamotorsport.net, halowaypoint.com, seaofthieves.com, flightsimulator.com, bethesda.net',
  playstation:
    '[Маршрут: В Прокси / VPN] Сетевые сервисы Sony PlayStation: playstation.com, playstation.net, playstationnetwork.com, sonyentertainmentnetwork.com, CDN загрузок dl.playstation.net, а также Bungie / Helldivers 2',
  nintendo:
    '[Маршрут: В Прокси / VPN] Все домены консолей Nintendo Switch, магазина eShop, подписки Nintendo Switch Online и игр Pokémon / Zelda / Mario / Splatoon (nintendo.com, nintendo.net, nintendowifi.net, pokemon.com)',
  gog: '[Маршрут: В Прокси / VPN] Домены магазина без DRM GOG.com, клиента GOG Galaxy и студий CD Projekt RED (gog.com, gogalaxy.com, gog-statics.com, cdprojektred.com, cyberpunk.net, thewitcher.com)',
  wargaming:
    '[Маршрут: В Прокси / VPN] Европейские и глобальные серверы Wargaming.net, лаунчер Wargaming Game Center, World of Tanks, World of Warships и WoT Blitz (wargaming.net, worldoftanks.eu, worldofwarships.eu, wotblitz.com)',
  hoyoverse:
    '[Маршрут: В Прокси / VPN или Direct] Домены лаунчера HoYoPlay, HoYoLAB и популярных гача-игр: Genshin Impact, Honkai: Star Rail, Zenless Zone Zero, Honkai Impact 3rd, Wuthering Waves (Kuro Games), Arknights, Azur Lane и NIKKE',
  minecraft:
    '[Маршрут: В Прокси / VPN] Официальные серверы авторизации и скинов Minecraft / Mojang (minecraft.net, mojang.com, minecraftservices.com), а также платформы модов и лаунчеров: CurseForge, Modrinth, NexusMods, PrismLauncher, Lunar/Badlion, Fabric, Forge, PaperMC',
  rockstar:
    '[Маршрут: В Прокси / VPN] Домены Rockstar Games Launcher, Social Club, GTA Online, Red Dead Online, серверов ролевых проектов FiveM / RedM (cfx.re), а также 2K Games (Civilization, NBA 2K, Borderlands, Mafia)',
  pubg: '[Маршрут: В Прокси / VPN] Популярные сетевые игры и античит-системы: PUBG / Krafton, THE FINALS и ARC Raiders, DayZ и Arma, VRChat, Dead by Daylight, Path of Exile, Warframe, Guild Wars 2, Albion Online, Rust, Squad, Mortal Kombat, osu! и BattlEye / EasyAntiCheat',
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
  jetbrains:
    '[Маршрут: Только в Прокси / VPN — геоблок по IP] Все домены экосистемы JetBrains (jetbrains.com, marketplace.jetbrains.com, download.jetbrains.com, kotlinlang.org), загрузки Android Studio / SDK (dl.google.com, developer.android.com), Gradle и Maven Central',
  gitlab_notion:
    '[Маршрут: Только в Прокси / VPN — геоблок по IP] Рабочие пространства, репозитории и сервисы мониторинга, закрывшие доступ из РФ: GitLab (gitlab.com), Atlassian (Jira, Confluence, Bitbucket, Trello), Notion (notion.so), Miro, Linear, Asana, ClickUp, Airtable, Postman, Sentry, Datadog и Grafana Cloud',
  figma_adobe:
    '[Маршрут: Только в Прокси / VPN — геоблок по IP] Платформы UI/UX-дизайна, графики и стоков: Figma (figma.com), Canva (canva.com), Adobe Creative Cloud & Firefly AI (adobe.com, adobe.io, behance.net), Framer, Webflow, Dribbble, Freepik, Flaticon, Envato, Shutterstock, Unsplash и Autodesk',
  pkg_registries:
    '[Маршрут: В Прокси / VPN] Репозитории пакетов, библиотек и дистрибутивов: HashiCorp (Terraform, Vagrant, Vault — геоблок РФ), npm, Yarn, pnpm, Bun, Deno, jsDelivr, PyPI, Anaconda, PyTorch, Rust Crates.io, Go Proxy, NuGet, Packagist, Homebrew, GHCR, Quay.io, k8s.io, Arch, Alpine, Debian/Ubuntu и OpenWrt',
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
  speedtest:
    '[Маршрут: В Прокси / VPN (для теста скорости туннеля) или Direct] Сервисы замера скорости интернета, проверки внешнего IP-адреса и DNS-утечек: Speedtest (speedtest.net, ookla.com), Fast.com, Cloudflare Speed, 2ip.ru / 2ip.io, Whoer.net, BrowserLeaks, IPLeak, IPinfo, Check-Host и Ping.pe',
  crypto:
    '[Маршрут: В Прокси / VPN (на статичный зарубежный IP) или Direct] Ведущие криптобиржи, DEX, графики, аналитика и кошельки: Binance, Bybit, OKX, Bitget, BingX, KuCoin, Gate.io, HTX, MEXC, Kraken, Coinbase, Uniswap, Jupiter, Polymarket, TradingView, CoinMarketCap, CoinGecko, DeFiLlama, MetaMask, Phantom, Tonkeeper',
  paypal_fintech:
    '[Маршрут: Только в Прокси / VPN — геоблок по IP] Зарубежные финансовые сервисы, платёжные шлюзы и брокеры, блокирующие вход с российских IP: PayPal (paypal.com), Wise (wise.com), Revolut (revolut.com), Stripe (stripe.com), Payoneer, Skrill, Neteller, N26, Monzo, Interactive Brokers, Investing.com и Bloomberg',
  news: '[Маршрут: В Прокси / VPN или Обход DPI] Заблокированные независимые российские и мировые информационные агентства и медиа (Meduza, BBC, DW, Euronews, Радио Свобода)',
  torrent:
    '[Маршрут: В Обход DPI (Desync / Zapret) или Прокси] Торрент-трекеры, индексаторы и анонсеры: RuTracker, Rutor, NNM-Club, Kinozal, Rustorka, LostFilm, The Pirate Bay, 1337x, Nyaa',
  tor: '[Маршрут: В Прокси / VPN] Домены и узлы сети Tor, каталогов мостов, I2P, Tails, Whonix и анонимайзеров',
  porn: '[Маршрут: В Прокси / VPN или Обход DPI] Крупнейшие сайты и видео-CDN 18+: Pornhub, XVideos, xHamster, OnlyFans, Fansly, Chaturbate',
  ads_hagezi_pro:
    '[Маршрут: Блокировать (Block)] Комплексная фильтрация рекламных сетей, аналитики, трекеров и фишинга Hagezi Multi PRO',
  win_spy:
    '[Маршрут: Блокировать (Block)] Серверы слежки, телеметрии, отчётов об ошибках и рекламы Windows 10/11',
  xiaomi_smarttv_ads:
    '[Маршрут: Блокировать (Block)] Вырезает встроенную системную рекламу и телеметрию в прошивках Xiaomi / Poco / Redmi (MIUI и HyperOS: api.ad.xiaomi.com, tracking.miui.com, mistat.xiaomi.com), а также рекламные баннеры и ACR-слежку на телевизорах Samsung Smart TV (Tizen) и LG webOS',
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
