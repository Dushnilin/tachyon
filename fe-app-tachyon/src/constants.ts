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
  belarus_inside: 'Беларусь (внутри)',
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
  steam_cdn: 'Steam CDN и загрузка игр (Direct)',
  captive_ntp_stun: 'Captive Portal, NTP и STUN (Direct)',
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
  ai_video: 'Kling AI, Hailuo, Luma, Pika и HeyGen (AI-видео)',
  ai_cloud_gpu: 'RunPod, Vast.ai, Replicate и Fal.ai (Облачные GPU)',
  huggingface: 'Hugging Face, Ollama и Character.AI',
  youtube: 'YouTube',
  youtube_images: 'YouTube (только превью и аватарки без видео)',
  twitch: 'Twitch',
  twitch_ads: 'Twitch (без рекламы и 1080p+)',
  spotify: 'Spotify',
  soundcloud_music: 'SoundCloud, Deezer, Tidal и Genius',
  podcasts_radio: 'Подкасты, онлайн-радио и Audible',
  netflix: 'Netflix',
  streaming_west: 'Disney+, Max (HBO), Prime Video, Hulu и Plex',
  tmdb_metadata: 'Постеры и базы фильмов (TMDB, IMDb, TheTVDB)',
  rutracker_lampa: 'RuTracker, Lampa, KinoPub и Flibusta',
  books_archives: 'Wayback Machine, Sci-Hub, LibGen и Z-Library',
  patreon_creators: 'Patreon, Medium, Substack, DeviantArt и Pixiv',
  tiktok: 'TikTok',
  hdrezka: 'HDRezka',
  anime: 'Аниме',
  pinterest: 'Pinterest',
  discord: 'Discord',
  discord_voice: 'Discord Voice (только голосовые UDP-серверы)',
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
  cs2_dota2: 'Valve Matchmaking (CS2, Dota 2, Deadlock и SDR)',
  epicgames: 'Epic Games (Fortnite / Unreal)',
  ubisoft: 'Ubisoft Connect (Uplay / R6 Siege)',
  warthunder: 'War Thunder и Gaijin (Enlisted / Crossout)',
  blizzard: 'Battle.net (Blizzard / WoW / Overwatch / Diablo)',
  callofduty: 'Call of Duty и Demonware (Warzone / Black Ops 6)',
  riot: 'Riot Games (Valorant / LoL)',
  origin: 'EA / Origin (EA App / Apex / BF)',
  xbox: 'Xbox Live, Game Pass и Bethesda',
  playstation: 'PlayStation Network (PSN / PS5 / PS4)',
  nintendo: 'Nintendo Switch (eShop / Switch Online)',
  meta_quest: 'Meta Quest (Oculus) и Pico VR',
  gog: 'GOG и CD Projekt RED (Cyberpunk / Ведьмак)',
  wargaming: 'Wargaming (World of Tanks / Warships EU)',
  hoyoverse: 'HoYoverse и Kuro Games (Genshin / HSR / ZZZ)',
  netease_tencent_games: 'Marvel Rivals, Delta Force, Once Human и Naraka',
  japanese_publishers: 'Capcom, Bandai Namco, FromSoftware, SEGA и Konami',
  minecraft: 'Minecraft и моддинг (Mojang / CurseForge / Modrinth)',
  rockstar: 'Rockstar Games и 2K (GTA Online / RDR2 / FiveM)',
  pubg: 'PUBG, THE FINALS, DayZ, VRChat, PoE и Warframe',
  survival_coop: 'Dead by Daylight, Rust, Hunt, Helldivers 2 и Palworld',
  mmorpg: 'MMORPG (PoE 1 & 2, Guild Wars 2, FFXIV, ESO, Albion)',
  fighting_racing: 'Файтинги и симрейсинг (MK1, Tekken 8, SF6, iRacing)',
  strategy_sim: 'Стратегии и авиасимуляторы (Paradox, Civ, MSFS)',
  chess_boardgames: 'Chess.com, Lichess, GeoGuessr, D&D Beyond и Roll20',
  game_backends: 'Сетевые движки игр и войс-чат (Photon, Vivox, PlayFab)',
  gaming_mods_stats:
    'Менеджеры модов, оверлеи и стат-трекеры (Thunderstore, Overwolf, OP.GG)',
  roblox: 'Roblox',
  supercell: 'Supercell (Brawl Stars / Clash)',
  escapefromtarkov: 'Escape from Tarkov',
  faceit: 'FACEIT (CS2)',
  apple: 'Apple и iCloud',
  microsoft: 'Microsoft и Xbox',
  google_services:
    'Сервисы Google (Почта, Диск, Документы, Карты — без YouTube)',
  google_play: 'Google Play (Android)',
  github: 'GitHub',
  docker: 'Docker Hub',
  jetbrains: 'JetBrains, Android Studio и Gradle',
  gitlab_notion: 'GitLab, Atlassian (Jira, Trello), Notion и Miro',
  figma_adobe: 'Figma, Canva, Adobe Creative Cloud и Framer',
  gamedev_3d: '3D-графика, CAD и геймдев (Unity, Autodesk, Blender, Fab)',
  pkg_registries: 'Пакетные менеджеры (HashiCorp, npm, PyPI, Crates, Go)',
  linux_repos: 'Репозитории и пакеты Linux (Flathub, Snap, PPA, AUR, Proxmox)',
  captcha_auth:
    'Капчи и единый вход SSO (Turnstile, reCAPTCHA, hCaptcha, Arkose)',
  cloud_gaming_remote:
    'Облачный гейминг и удалённый ПК (GeForce NOW, Parsec, AnyDesk, TeamViewer)',
  cloud_storage:
    'Облачные хранилища и файлообменники (MEGA, Dropbox, WeTransfer, Pixeldrain)',
  security_passwords:
    'Менеджеры паролей, Proton и антивирусы (Bitwarden, 1Password, VirusTotal)',
  smarthome_iot:
    'Умный дом и 3D-печать (Home Assistant, Bambu Lab, Tuya, Aqara)',
  smarttv_apps: 'Smart TV: Samsung Tizen и LG webOS (Smart Hub и магазины ТВ)',
  smart_cars:
    'Умные автомобили и электрокары (LiXiang, Zeekr, BYD, Voyah, Tesla)',
  hodca: 'Центры сертификации SSL/TLS (CA)',
  doh_dot_dns:
    'Публичные шифрованные DNS (DoH / DoT: 1.1.1.1, 8.8.8.8, Quad9, AdGuard)',
  cloudflare: 'Cloudflare (CDN и подсети)',
  cloudfront: 'Amazon CloudFront (CDN подсети)',
  fastly: 'Fastly CDN',
  hetzner: 'Hetzner (подсети ДЦ)',
  ovh: 'OVHcloud (подсети ДЦ)',
  digitalocean: 'DigitalOcean (подсети ДЦ)',
  vps_clouds:
    'Облачные хостинги VPS (Oracle Cloud, Vultr, Linode, Scaleway, GCore)',
  speedtest: 'Speedtest и проверка IP (Ookla, Fast.com, 2ip, Whoer)',
  crypto: 'Криптовалюты и Web3 (Bybit, Binance, OKX, TradingView)',
  paypal_fintech: 'PayPal, Wise, Revolut и Stripe (Финтех)',
  travel_booking:
    'Путешествия, отели и авиабилеты (Booking, Airbnb, TripAdvisor, Flightradar24)',
  shopping_global:
    'Зарубежный шопинг и маркетплейсы (iHerb, Amazon, eBay, Poizon, StockX)',
  edtech_learning:
    'Обучение, курсы и IT-платформы (Coursera, Udemy, Quizlet, Duolingo, LeetCode)',
  freelance_remote:
    'Фриланс и удалённая работа (Upwork, Fiverr, Toptal, Deel, Payoneer)',
  sports_fitness:
    'Спорт, велотрекеры и фитнес (Strava, Garmin Connect, Zwift, Flashscore)',
  news: 'СМИ и новости',
  torrent: 'Торренты и трекеры',
  tor: 'Tor и анонимайзеры',
  porn: 'Сайты 18+ (Adult)',
  ads_hagezi_pro: 'Реклама и трекеры (Block)',
  android_ads_block: 'Реклама в играх и приложениях Android (Block)',
  gambling_block: 'Казино, букмекеры и слоты (Block)',
  phishing_malware_block: 'Фишинг, скам и вредоносные сайты (Block)',
  telemetry_mobile_block: 'Телеметрия смартфонов и мобильных SDK (Block)',
  win_spy: 'Телеметрия Windows (Block)',
  xiaomi_smarttv_ads: 'Реклама Xiaomi HyperOS/MIUI и Smart TV (Block)',
  et_spamhaus_block: 'Emerging Threats, Spamhaus DROP и Feodo C2 (Block)',
  hagezi_tif_ip_block:
    'HaGeZi Threat Intelligence IP и FireHOL Webclient (Block)',
  botnet_attackers_ip_block: 'IPsum, CINS Army и Binary Defense (Block)',
};

export const DOMAIN_LIST_HINTS: Record<string, string> = {
  russia_inside:
    '[Маршрут: В Прокси / VPN или Обход DPI] Сводный реестр заблокированных и ограниченных в РФ ресурсов (соцсети, СМИ, зарубежные платформы и геоблок)',
  ukraine_inside:
    '[Маршрут: В Прокси / VPN или Обход DPI] Сводный список заблокированных и ограниченных в Украине ресурсов и сервисов',
  belarus_inside:
    "[Маршрут: В Прокси / VPN или Обход DPI] Сводный список интернет-ресурсов, новостных порталов, правозащитных сайтов и зарубежных платформ, заблокированных Министерством информации и провайдерами на территории Республики Беларусь (Zerkalo / TUT.BY, Наша Ніва, Хартия'97, Белсат, Радыё Свабода, Euroradio, Dev.by, CityDog, Реформация, Трибуна, а также закрытые по геоблоку в РБ LinkedIn, ChatGPT, Claude, Airbnb, Upwork, Coursera)",
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
  steam_cdn:
    '[Маршрут: Напрямую (Direct) — ставить ВЫШЕ правила Steam!] Контент-серверы скачивания игр и обновлений Steam (steamcontent.com, steampipe.akamaized.net, dl.steam.ksyna.com, steamserver.net) и других игровых лаунчеров. Поставьте этот список в Direct выше основного списка Steam (Proxy): магазин, смена региона, инвентарь и торговая площадка будут работать через VPN, а 100-гигабайтные игры будут качаться напрямую на полной скорости вашего провайдера!',
  captive_ntp_stun:
    '[Маршрут: Напрямую (Direct)] Системные домены проверки наличия интернета на iOS, Android, Windows и macOS (captive.apple.com, connectivitycheck.gstatic.com, msftconnecttest.com), серверы синхронизации точного времени NTP (pool.ntp.org, time.cloudflare.com — критично для запуска VLESS/Reality и WireGuard на роутерах без RTC!) и публичные STUN-серверы',
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
  ai_video:
    '[Маршрут: Только в Прокси / VPN — геоблок по IP] Ведущие нейросети генерации видео, анимации, говорящих аватаров и VFX: Kling AI (klingai.com), Hailuo AI / MiniMax (hailuoai.video), Luma Dream Machine (lumalabs.ai), Pika Art (pika.art), HeyGen (heygen.com), Synthesia, Vidu, PixVerse, Higgsfield AI, Hedra, Topaz Labs и Magnific AI',
  ai_cloud_gpu:
    '[Маршрут: В Прокси / VPN] Платформы почасовой аренды GPU (A100/H100/RTX 4090) под Stable Diffusion / Flux / LLM и бессерверного API-инференса: RunPod (runpod.io), Vast.ai (vast.ai), Replicate (replicate.com), Fal.ai (fal.ai, fal.run), Together AI, Fireworks AI, Modal, Lambda Labs, Baseten, DeepInfra и Chutes AI',
  huggingface:
    '[Маршрут: В Прокси / VPN] Репозитории моделей и датасетов Hugging Face (huggingface.co, hf.co), каталоги локальных LLM (ollama.com, lmstudio.ai, openwebui.com), платформы ролевых ИИ-персонажей (Character.AI, JanitorAI, Chub, NovelAI) и ML-инфраструктура (Weights & Biases, Kaggle, LangChain)',
  youtube:
    '[Маршрут: В Обход DPI (Desync / Zapret) или Прокси / VPN] Видеосервис YouTube, YouTube Music, Studio и кэш-серверы видеопотоков (youtube.com, youtu.be, googlevideo.com, ytimg.com, ggpht.com)',
  youtube_images:
    '[Маршрут: В Прокси / VPN — для тех, кто чинит само видео через Zapret/ByeDPI] Серверы обложек роликов (i.ytimg.com, i9.ytimg.com), аватарок каналов (yt3.ggpht.com, yt4.ggpht.com) и веб-интерфейса YouTube БЕЗ тяжёлых видеосерверов googlevideo.com. Если видео через обход DPI показывает, но не грузятся картинки и аватарки — направьте этот список в Прокси!',
  twitch:
    '[Маршрут: В Прокси / VPN или Обход DPI] Стриминговая платформа, видеопотоки и чат (twitch.tv, ttvnw.net, jtvnw.net, live-video.net)',
  twitch_ads:
    '[Маршрут: Только в Прокси / VPN] Серверы манифестов качества видео и рекламы Twitch (usher.ttvnw.net, gql.twitch.tv) — отключает рекламу и разблокирует 1080p60/1440p без проксирования видеопотока',
  spotify:
    '[Маршрут: Только в Прокси / VPN — геоблок по IP] Музыкальный стриминг, аудио-CDN и клиентские API (spotify.com, scdn.co, spotifycdn.com, akamaized.net)',
  soundcloud_music:
    '[Маршрут: В Прокси / VPN] Музыкальные сервисы и энциклопедии, заблокированные РКН или закрытые геоблоком: SoundCloud (soundcloud.com, sndcdn.com), Deezer (deezer.com, dzcdn.net), Tidal (tidal.com), Qobuz, Bandcamp, Genius (genius.com), Last.fm, Mixcloud, TuneIn и Discogs',
  podcasts_radio:
    '[Маршрут: В Прокси / VPN] Зарубежные CDN-хостинги подкастов (megaphone.fm, art19.com, simplecast.com, acast.com, omny.fm, buzzsprout.com, libsyn.com, podbean.com — именно из-за их блокировки не скачиваются выпуски в стандартном приложении «Подкасты» на iPhone!), плееры Pocket Casts и Overcast, аудиокниги Audible, Storytel, Bookmate и интернет-радио TuneIn Radio, DI.FM и Radio Garden',
  netflix:
    '[Маршрут: Только в Прокси / VPN — геоблок по IP] Онлайн-кинотеатр, видеопотоки и статика (netflix.com, nflxvideo.net, nflximg.net, nflxext.com, fast.com)',
  streaming_west:
    '[Маршрут: Только в Прокси / VPN — геоблок по IP] Западные стриминговые сервисы и медиасерверы: Disney+ (disneyplus.com, bamgrid.com), Max / HBO (max.com, hbomax.com), Amazon Prime Video (primevideo.com, aiv-cdn.net), Hulu, Paramount+, Peacock, MUBI и облако домашнего медиасервера Plex (plex.tv, plex.direct)',
  tmdb_metadata:
    '[Маршрут: В Прокси / VPN или Обход DPI] Базы метаданных, обложек, актёров и описаний фильмов и музыки: The Movie Database (themoviedb.org, image.tmdb.org, api.themoviedb.org — блокируются в РФ, из-за чего в Lampa, Plex, Kodi, Jellyfin и Infuse пропадают постеры!), TheTVDB, IMDb, Trakt.tv, Fanart.tv, OpenSubtitles, Last.fm, MusicBrainz и Discogs',
  rutracker_lampa:
    "[Маршрут: В Прокси / VPN или Обход DPI] Народный набор для дома и Android TV: зеркала RuTracker, Rutor, NNM-Club, Kinozal, LostFilm, KinoPub, балансеры и плагины Lampa (Filmix, Cub, BWA, Zetflix), а также книжные и научные библиотеки (Flibusta, Coollib, Z-Library, Anna's Archive, LibGen, Sci-Hub)",
  books_archives:
    "[Маршрут: В Прокси / VPN или Обход DPI] Архив интернета (archive.org / Wayback Machine — заблокирован в РФ), архивы веб-страниц (archive.is, archive.ph, ghostarchive.org), крупнейшие библиотеки книг, фанфиков и научных статей: Anna's Archive, Z-Library (z-lib.gs, singlelogin.re), Library Genesis (libgen.is), Sci-Hub, Project Gutenberg, ResearchGate, Academia.edu и AO3 (archiveofourown.org)",
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
  discord_voice:
    '[Маршрут: В низкопинговый игровой Прокси / VPN с поддержкой UDP или Обход DPI] Узкий список голосовых и видео-шлюзов Discord (*.discord.media и UDP-подсети голосовых серверов Discord). Позволяет направить голосовые каналы и стриминг экрана через самый быстрый узел с минимальным пингом отдельно от основного чата и картинок Discord',
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
  cs2_dota2:
    '[Маршрут: В игровой Прокси с минимальным пингом или Direct] Только соревновательные серверы матчей Valve, релеи Steam Datagram Relay (steamdatagram.com, valve.net и подсети AS32590 Valve Corporation) и игровой координатор (CS2, Dota 2, Deadlock, TF2) — без тяжёлого магазина и скачивания игр Steam',
  epicgames:
    '[Маршрут: В Прокси / VPN (для раздач/покупок) или Direct] Epic Games Store, Fortnite, Rocket League, Unreal Engine и античит EasyAntiCheat (epicgames.com, unrealengine.com, fortnite.com, easy.ac)',
  ubisoft:
    '[Маршрут: В Прокси / VPN] Домены лаунчера Ubisoft Connect (Uplay), серверов авторизации, облачных сохранений, CDN обновлений и античитов (ubisoft.com, ubi.com, uplay.com, rainbowsix.com, battleye.com)',
  warthunder:
    '[Маршрут: В Прокси / VPN или Direct] Домены игр и лаунчера Gaijin Entertainment: War Thunder (warthunder.com), Enlisted (enlisted.net), Crossout (crossout.net), CRSED, Star Conflict, магазин Gaijin.Net и серверы обновлений',
  blizzard:
    '[Маршрут: В Прокси / VPN] Домены лаунчера Battle.net, магазина и серверов Activision Blizzard: battle.net, blizzard.com, activision.com, callofduty.com, worldofwarcraft.com, playoverwatch.com, diablo4.com, playhearthstone.com',
  callofduty:
    '[Маршрут: В Прокси / VPN (устраняет ошибки HUENEME-NEGEV / TRAVIS-RILEA и вечный цикл «Обновление завершено. Требуется перезапуск»)] Полный список доменов и 805 IP-подсетей матчей Call of Duty для Steam, Battle.net, Xbox Game Pass и PlayStation: шлюзы матчмейкинга и лобби Demonware (demonware.net + AS60229), CDN микропатчей и шейдеров Beenox (d2cyf1jgpkmugk.cloudfront.net, fastdl/content.callofduty.com, cod-live-updates.activision.com, blzstatic.com) и игровые серверы Warzone',
  riot: '[Маршрут: В Прокси / VPN или Direct] Valorant, League of Legends, TFT, Riot Client и Vanguard (riotgames.com, playvalorant.com, leagueoflegends.com, pvp.net)',
  origin:
    '[Маршрут: В Прокси / VPN] EA App, Origin, Apex Legends, Battlefield, EA Sports FC и Sims (ea.com, origin.com, tnt-ea.com, apexlegends.com)',
  xbox: '[Маршрут: В Прокси / VPN] Экосистема Xbox и игровых студий Microsoft / Bethesda: xbox.com, xboxlive.com, gamepass.com, xboxservices.com, forzamotorsport.net, halowaypoint.com, seaofthieves.com, flightsimulator.com, bethesda.net',
  playstation:
    '[Маршрут: В Прокси / VPN] Сетевые сервисы Sony PlayStation: playstation.com, playstation.net, playstationnetwork.com, sonyentertainmentnetwork.com, CDN загрузок dl.playstation.net, а также Bungie / Helldivers 2',
  nintendo:
    '[Маршрут: В Прокси / VPN] Все домены консолей Nintendo Switch, магазина eShop, подписки Nintendo Switch Online и игр Pokémon / Zelda / Mario / Splatoon (nintendo.com, nintendo.net, nintendowifi.net, pokemon.com)',
  meta_quest:
    '[Маршрут: Только в Прокси / VPN — обязательно для работы Meta Quest в РФ] Выделенный список доменов VR-экосистемы Meta Quest 2 / 3 / 3S / Pro (oculus.com, oculuscdn.com, meta.com, graph.oculus.com, securecdn.oculus.com), Pico VR (picoxr.com) и SideQuest. Позволяет активировать шлем, обновлять прошивку Horizon OS и скачивать игры на полной скорости, не проксируя весь остальной трафик Instagram/Facebook',
  gog: '[Маршрут: В Прокси / VPN] Домены магазина без DRM GOG.com, клиента GOG Galaxy и студий CD Projekt RED (gog.com, gogalaxy.com, gog-statics.com, cdprojektred.com, cyberpunk.net, thewitcher.com)',
  wargaming:
    '[Маршрут: В Прокси / VPN] Европейские и глобальные серверы Wargaming.net, лаунчер Wargaming Game Center, World of Tanks, World of Warships и WoT Blitz (wargaming.net, worldoftanks.eu, worldofwarships.eu, wotblitz.com)',
  hoyoverse:
    '[Маршрут: В Прокси / VPN или Direct] Домены лаунчера HoYoPlay, HoYoLAB и популярных гача-игр: Genshin Impact, Honkai: Star Rail, Zenless Zone Zero, Honkai Impact 3rd, Wuthering Waves (Kuro Games), Arknights, Azur Lane и NIKKE',
  netease_tencent_games:
    '[Маршрут: В Прокси / VPN] Игровые бэкенды, лаунчеры, античиты и CDN-серверы глобальных хитов от NetEase Games и Tencent Level Infinite: Marvel Rivals (marvelrivals.com), Delta Force (playdeltaforce.com), Once Human (oncehuman.game), Arena Breakout: Infinite, Naraka: Bladepoint, FragPunk, PUBG Mobile, NIKKE и Strinova (netease.com, easebar.com, loadingbay.com, intlgame.com, proximabeta.com)',
  japanese_publishers:
    '[Маршрут: В Прокси / VPN] Онлайн-сервисы и серверы коопа/матчмейкинга японских игровых издателей: FromSoftware и Bandai Namco (Elden Ring, Elden Ring Nightreign, Dark Souls, Armored Core VI — fromsoftware-game.jp, bandainamcoent.com), Capcom (Monster Hunter Wilds / World, Resident Evil, Capcom ID — capcom.com), SEGA и Atlus (Sonic, Like a Dragon, Persona — sega.com), Square Enix и Konami (eFootball, Yu-Gi-Oh!, Metal Gear)',
  minecraft:
    '[Маршрут: В Прокси / VPN] Официальные серверы авторизации и скинов Minecraft / Mojang (minecraft.net, mojang.com, minecraftservices.com), а также платформы модов и лаунчеров: CurseForge, Modrinth, NexusMods, PrismLauncher, Lunar/Badlion, Fabric, Forge, PaperMC',
  rockstar:
    '[Маршрут: В Прокси / VPN] Домены Rockstar Games Launcher, Social Club, GTA Online, Red Dead Online, серверов ролевых проектов FiveM / RedM (cfx.re), а также 2K Games (Civilization, NBA 2K, Borderlands, Mafia)',
  pubg: '[Маршрут: В Прокси / VPN] Популярные сетевые игры и античит-системы: PUBG / Krafton, THE FINALS и ARC Raiders, DayZ и Arma, VRChat, Dead by Daylight, Path of Exile, Warframe, Guild Wars 2, Albion Online, Rust, Squad, Mortal Kombat, osu! и BattlEye / EasyAntiCheat',
  survival_coop:
    '[Маршрут: В Прокси / VPN или Обход DPI] Серверы входа, инвентаря и матчмейкинга популярных мультиплеерных экшенов и выживачей, страдающих от блокировок подсетей Amazon AWS / GameLift и Hetzner на ТСПУ: Dead by Daylight (bhvrdbd.com), Rust (facepunch.com, playrust.com), Hunt: Showdown 1896 (huntshowdown.com, crytek.com), Helldivers 2, Palworld, ARK, Valheim, Satisfactory, Deep Rock Galactic, Dune: Awakening и Sea of Thieves',
  mmorpg:
    '[Маршрут: В Прокси / VPN] Серверы авторизации, патчеры и торговые площадки ведущих MMORPG: Path of Exile 1 и PoE 2 (pathofexile.com, poecdn.com, grindinggear.com), Guild Wars 2 (guildwars2.com, arena.net, ncsoft.com), Final Fantasy XIV (finalfantasyxiv.com, sqex.com), The Elder Scrolls Online (elderscrollsonline.com), Albion Online (albiononline.com), Black Desert, EVE Online, Star Citizen, Lost Ark и RuneScape',
  fighting_racing:
    '[Маршрут: Только в Прокси / VPN — WB Games блокирует РФ по IP] Серверы онлайна и профилей файтингов и гоночных симуляторов: Mortal Kombat 1 / 11 и игры Warner Bros. Games (wbgames.com, wbplay.com, agoragames.com — закрыты для российских IP!), Tekken 8, Street Fighter 6 (buckler.capcom.com), Guilty Gear Strive, а также симрейсинг iRacing (iracing.com), Assetto Corsa / LFM (lowfuelmotorsport.com), Le Mans Ultimate, RaceRoom, Fanatec, Moza Racing и Simagic',
  strategy_sim:
    "[Маршрут: В Прокси / VPN] Лаунчеры, моды и мультиплеер глобальных стратегий и симуляторов: Paradox Interactive (Hearts of Iron IV, Stellaris, Europa Universalis IV, Crusader Kings III, Cities: Skylines — paradoxinteractive.com, paradoxplaza.com), Sid Meier's Civilization (2K), Age of Empires, Total War, Euro Truck Simulator 2 (TruckersMP), а также серверы фотограмметрии, погоды и навигации Microsoft Flight Simulator 2020/2024, X-Plane, Navigraph и VATSIM",
  chess_boardgames:
    '[Маршрут: В Прокси / VPN или Обход DPI] Крупнейший шахматный портал Chess.com (заблокирован РКН в РФ: chess.com, chesscomfiles.com), Lichess (lichess.org), географическая игра GeoGuessr (geoguessr.com), виртуальные столы для настольных и ролевых игр D&D Beyond (dndbeyond.com, wizards.com), Roll20 (roll20.net), Foundry VTT, BoardGameArena и Tabletopia',
  game_backends:
    '[Маршрут: В Прокси / VPN (с UDP) или Обход DPI] Сетевая инфраструктура сотен мультиплеерных игр и внутриигрового голосового чата: войс-движок Vivox (vivox.com, unity3d.com — чинит голосовой чат в Valorant, PUBG, LoL, Fortnite, Overwatch 2, Rainbow Six), облако кооп-игр Photon Engine (photonengine.com, exitgames.com + UDP-подсети — чинит Phasmophobia, R.E.P.O., Content Warning, Lethal Company, VRChat, Among Us), Azure PlayFab (playfabapi.com — Helldivers 2, Sea of Thieves, Minecraft) и Epic Online Services (epicgames.dev)',
  gaming_mods_stats:
    '[Маршрут: В Прокси / VPN] Платформы моддинга, игровых оверлеев, трейнеров и киберспортивной статистики, часто недоступные из РФ из-за блокировок Cloudflare и геоблока: Thunderstore Mod Manager / r2modman (thunderstore.io, gcdn.thunderstore.io), Overwolf (overwolf.com), WeMod, ModDB, GameBanana, SteamDB, Tracker.gg, OP.GG, U.GG, Mobalytics, Dotabuff, OpenDota, Stratz, Leetify, Maxroll, Wowhead, Poe.ninja и HLTV.org',
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
  google_services:
    '[Маршрут: Напрямую (Direct) или В Прокси / VPN по выбору] Основная экосистема поиска и офисных сервисов Google (google.com, gmail.com, drive.google.com, docs.google.com, maps.google.com, translate.google.com, gstatic.com, googleapis.com, googleusercontent.com), из которой исключены домены YouTube (youtube.com, googlevideo.com) и нейросетей Google AI (gemini.google.com, aistudio.google.com)',
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
  gamedev_3d:
    '[Маршрут: Только в Прокси / VPN — геоблок по IP] Профессиональный софт для 3D-моделирования, рендера, CAD и разработки игр: Unity Engine, Unity Hub и Asset Store (unity.com, unity3d.com — закрыты для RU IP), Autodesk (AutoCAD, 3ds Max, Maya, Revit, Fusion 360 — autodesk.com), Chaos Group (V-Ray, Corona, Enscape), Maxon (Cinema 4D, Redshift, ZBrush), Blender, Godot, SideFX Houdini, Quixel Megascans / Fab.com, Sketchfab, ArtStation, Poly Haven и Printables',
  pkg_registries:
    '[Маршрут: В Прокси / VPN] Репозитории пакетов, библиотек и дистрибутивов: HashiCorp (Terraform, Vagrant, Vault — геоблок РФ), npm, Yarn, pnpm, Bun, Deno, jsDelivr, PyPI, Anaconda, PyTorch, Rust Crates.io, Go Proxy, NuGet, Packagist, Homebrew, GHCR, Quay.io, k8s.io, Arch, Alpine, Debian/Ubuntu и OpenWrt',
  linux_repos:
    '[Маршрут: В Прокси / VPN] Пакетные репозитории, магазины приложений Linux и серверные дистрибутивы, которые ограничивают доступ с российских IP (Red Hat, Fedora, Canonical Launchpad) или тормозят из-за блокировок CDN (Flathub): Flathub / Flatpak (flathub.org), Snapcraft (snapcraft.io), Ubuntu / Launchpad PPA (launchpad.net), Arch Linux & AUR (archlinux.org), Proxmox VE (proxmox.com), Red Hat (redhat.com), Fedora, Debian, Alpine, Kali и NixOS',
  captcha_auth:
    '[Маршрут: В Прокси / VPN или Direct (в зависимости от сайта)] Виджеты проверки на робота и провайдеры единой авторизации (SSO / OAuth / Passkeys): Cloudflare Turnstile (challenges.cloudflare.com), hCaptcha (hcaptcha.com), Google reCAPTCHA (recaptcha.net), Arkose Labs / FunCaptcha (arkoselabs.com, funcaptcha.com — капча в Steam, Roblox, EA, GitHub, OpenAI), GeeTest, DataDome, Auth0, Okta и Clerk',
  cloud_gaming_remote:
    '[Маршрут: В Прокси / VPN] Сервисы облачного гейминга и удалённого управления ПК: NVIDIA GeForce NOW (geforcenow.com, nvidiagrid.net — проверяет зарубежный IP только при входе и старте игры, после чего видеопоток идёт напрямую!), Boosteroid, Parsec (parsec.app), Shadow, а также TeamViewer (заблокировал РФ по IP), AnyDesk (anydesk.com — часто режется ТСПУ), RustDesk, NoMachine, Tailscale и ZeroTier',
  cloud_storage:
    '[Маршрут: В Прокси / VPN или Обход DPI] Зарубежные облачные диски и популярные файлообменники, где публикуют прошивки, моды и рабочие архивы (многие заблокированы РКН или закрыли доступ из РФ): MEGA (mega.nz, mega.co.nz, mega.io), Dropbox (dropbox.com), WeTransfer (wetransfer.com, we.tl), Pixeldrain (pixeldrain.com), GoFile (gofile.io), Catbox (catbox.moe), MediaFire, Box.com, pCloud, Sync.com и TeraBox',
  security_passwords:
    '[Маршрут: В Прокси / VPN] Менеджеры паролей и ключей: Bitwarden (bitwarden.com, bitwarden.eu), 1Password (1password.com), NordPass, Dashlane, Keeper, Enpass; защищённая экосистема Proton (Proton Mail, Proton Pass, Proton Drive — proton.me, protonmail.com, заблокирована РКН), Tuta (tuta.com); облачный сканер VirusTotal и обновления баз зарубежных антивирусов (Malwarebytes, Avast, AVG, ESET NOD32, Bitdefender, Norton, Avira)',
  smarthome_iot:
    '[Маршрут: В Прокси / VPN] Облачные сервисы и репозитории умного дома и 3D-принтеров: облако 3D-печати Bambu Lab / MakerWorld (bambulab.com, bblmw.com, makerworld.com — отправка печати из Bambu Studio и видео с камеры через AWS часто блокируются ТСПУ!), Creality Cloud, Prusa; экосистема Home Assistant и Nabu Casa (home-assistant.io, nabu.casa, esphome.io, zigbee2mqtt.io); глобальные облака Tuya / Smart Life, eWeLink (Sonoff), Aqara, Roborock, Dreame и Philips Hue',
  smarttv_apps:
    '[Маршрут: Только в Прокси / VPN (на нужный регион при настройке/активации ТВ)] Серверы проверки геолокации, активации Smart Hub и каталогов приложений телевизоров Samsung Smart TV (Tizen OS: samsungcloudsolution.com, samsungotn.net, samsungqbe.com, samsungosp.com) и LG Smart TV (webOS / LG Content Store: lgappstv.com, lgtvsdp.com, lgtvcommon.com). Незаменимо для разблокировки «серых» телевизоров параллельного импорта',
  smart_cars:
    '[Маршрут: Напрямую (Direct) или в китайский/целевой прокси] Серверы телематики, OTA-обновлений, мастер-аккаунтов и штатной навигации современных автомобилей: китайские электрокары и гибриды LiXiang / Li Auto (lixiang.com, chj.com), Zeekr (zeekrlife.com, zeekr.com), BYD, Voyah, Geely, Changan, Xiaomi SU7, NIO, XPeng, а также приложения и облака Tesla (tesla.com), BMW (MyBMW / ConnectedDrive) и Mercedes me. Позволяет на роутере в авто не пускать китайскую телематику в европейский VPN во избежание гео-блокировки экранов!',
  hodca:
    '[Маршрут: В Прокси / VPN] Серверы проверки SSL-сертификатов (OCSP / CRL): DigiCert, Sectigo, Comodo, GlobalSign, Let’s Encrypt (устраняет долгую загрузку HTTPS из-за геоблока)',
  doh_dot_dns:
    '[Маршрут: В Прокси / VPN (для обхода блокировки DoH) или Блокировать (Block — чтобы запретить устройствам обходить локальный DNS роутера)] Полная база публичных серверов DNS-over-HTTPS (DoH) и DNS-over-TLS (DoT), включая домены и IP-адреса резолверов Cloudflare (1.1.1.1, cloudflare-dns.com), Google (8.8.8.8, dns.google), Quad9 (9.9.9.9, dns.quad9.net), AdGuard DNS, NextDNS, OpenDNS, Control D и Mullvad DNS',
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
  vps_clouds:
    '[Маршрут: В Прокси / VPN] Сводные IPv4/IPv6-подсети популярных зарубежных облачных провайдеров и VPS-хостингов: Oracle Cloud (AS31898), Vultr / Constant (AS20473), Linode / Akamai Connected Cloud (AS63949), Scaleway / Online.net (AS12876) и GCore Labs (AS199524), диапазоны которых массово блокируются или ограничиваются на ТСПУ в РФ (в дополнение к спискам Hetzner, OVH и DigitalOcean)',
  speedtest:
    '[Маршрут: В Прокси / VPN (для теста скорости туннеля) или Direct] Сервисы замера скорости интернета, проверки внешнего IP-адреса и DNS-утечек: Speedtest (speedtest.net, ookla.com), Fast.com, Cloudflare Speed, 2ip.ru / 2ip.io, Whoer.net, BrowserLeaks, IPLeak, IPinfo, Check-Host и Ping.pe',
  crypto:
    '[Маршрут: В Прокси / VPN (на статичный зарубежный IP) или Direct] Ведущие криптобиржи, DEX, графики, аналитика и кошельки: Binance, Bybit, OKX, Bitget, BingX, KuCoin, Gate.io, HTX, MEXC, Kraken, Coinbase, Uniswap, Jupiter, Polymarket, TradingView, CoinMarketCap, CoinGecko, DeFiLlama, MetaMask, Phantom, Tonkeeper',
  paypal_fintech:
    '[Маршрут: Только в Прокси / VPN — геоблок по IP] Зарубежные финансовые сервисы, платёжные шлюзы и брокеры, блокирующие вход с российских IP: PayPal (paypal.com), Wise (wise.com), Revolut (revolut.com), Stripe (stripe.com), Payoneer, Skrill, Neteller, N26, Monzo, Interactive Brokers, Investing.com и Bloomberg',
  travel_booking:
    '[Маршрут: Только в Прокси / VPN — геоблок по IP] Международные системы бронирования отелей, жилья и поиска авиабилетов: Booking.com (booking.com, bstatic.com — не показывает объекты размещения при входе с российских IP!), Airbnb (airbnb.com, muscache.com — блокирует доступ из РФ и РБ), Agoda, Hostelworld, Expedia, Hotels.com, Trip.com, Skyscanner, Kayak, Momondo, TripAdvisor, а также радар полётов Flightradar24 и MarineTraffic',
  shopping_global:
    '[Маршрут: Только в Прокси / VPN — блокировка РКН и геоблок] Иностранные интернет-магазины, витамины и фэшн-платформы: iHerb (iherb.com — заблокирован РКН), Amazon (amazon.com), eBay (ebay.com), китайский маркетплейс оригинальных кроссовок и брендов Poizon / Dewu (dewu.com, poizon.com), StockX, GOAT, Chrono24, Farfetch, ASOS, Yoox, Net-a-Porter, Nike, Adidas, Uniqlo, Zara и IKEA',
  edtech_learning:
    '[Маршрут: В Прокси / VPN] Образовательные платформы, языковые сервисы и тренажёры для программистов: Coursera (coursera.org), Udemy (udemy.com), edX, Udacity, Khan Academy, карточки для запоминания слов Quizlet (quizlet.com — заблокирован РКН!), Duolingo (duolingo.com), Babbel, Busuu, AnkiWeb, а также алгоритмические и Data Science платформы LeetCode (leetcode.com), Kaggle (kaggle.com), HackerRank, Codewars и freeCodeCamp',
  freelance_remote:
    '[Маршрут: Только в Прокси / VPN — строгий геоблок по IP] Международные биржи фриланса, контрактов и глобального найма (требуют постоянный не-российский IP): Upwork (upwork.com), Fiverr (fiverr.com), Freelancer.com, Toptal, PeoplePerHour, Guru, 99designs, Behance, Dribbble, а также платформы оформления контрактов и выплат удалённым сотрудникам Deel (deel.com), Remote.com, Oyster HR и Payoneer',
  sports_fitness:
    '[Маршрут: Только в Прокси / VPN] Спортивные трекеры, умные часы, велостанки и результаты матчей: Strava (strava.com — закрыла доступ и синхронизацию тренировок с российских IP!), Garmin Connect (garmin.com, connect.garmin.com), виртуальный велотренажёр Zwift (zwift.com), велонавигатор Komoot, Wahoo, Whoop, MyFitnessPal, результаты матчей Flashscore (flashscore.com — заблокирован РКН), Sofascore, Transfermarkt, F1 TV, UFC Fight Pass, NBA и NHL',
  news: '[Маршрут: В Прокси / VPN или Обход DPI] Заблокированные независимые российские и мировые информационные агентства и медиа (Meduza, BBC, DW, Euronews, Радио Свобода)',
  torrent:
    '[Маршрут: В Обход DPI (Desync / Zapret) или Прокси] Торрент-трекеры, индексаторы и анонсеры: RuTracker, Rutor, NNM-Club, Kinozal, Rustorka, LostFilm, The Pirate Bay, 1337x, Nyaa',
  tor: '[Маршрут: В Прокси / VPN] Домены и узлы сети Tor, каталогов мостов, I2P, Tails, Whonix и анонимайзеров',
  porn: '[Маршрут: В Прокси / VPN или Обход DPI] Крупнейшие сайты и видео-CDN 18+: Pornhub, XVideos, xHamster, OnlyFans, Fansly, Chaturbate',
  ads_hagezi_pro:
    '[Маршрут: Блокировать (Block)] Комплексная фильтрация рекламных сетей, аналитики, трекеров и фишинга Hagezi Multi PRO',
  android_ads_block:
    '[Маршрут: Блокировать (Block)] Вырезает полноэкранную видеорекламу между уровнями в мобильных играх и баннеры внутри бесплатных приложений на Android (AdAway Official + AdGuard Mobile Ads + все главные рекламные SDK: Google AdMob, Unity Ads, AppLovin MAX, IronSource LevelPlay, Vungle/Liftoff, Mintegral, Chartboost, Pangle, InMobi, AdColony, Tapjoy, Bigo Ads, BidMachine, Яндекс Реклама / Mobile Ads SDK и VK MyTarget)',
  gambling_block:
    '[Маршрут: Блокировать (Block)] Полная база онлайн-казино, нелегальных букмекеров, крипто-рулеток, слотов и их тысяч зеркал (Hagezi Gambling Medium + СНГ-казино: 1xBet, Melbet, Mostbet, Pin-Up, Vulkan, Vavada, Joycasino, Azino777, Stake, 1win, DragonMoney, Up-X и др.), агрессивно всплывающих на пиратских киносайтах',
  phishing_malware_block:
    '[Маршрут: Блокировать (Block)] Специализированный список блокировки фишинговых копий Steam / Telegram / Госуслуг / банков, телефонных мошенников, крипто-дрейнеров, ботнетов и вредоносных доменов (Hagezi Threat Intelligence Feeds Mini + Fake/Scam). Идеален для тех, кто не хочет включать полный AdBlock, чтобы не ломать реферальные ссылки и кэшбэк-сервисы, но хочет защитить домашнюю сеть от скама и вирусов',
  telemetry_mobile_block:
    '[Маршрут: Блокировать (Block)] Блокировка встроенной системной телеметрии смартфонов Apple iOS/macOS, Huawei EMUI/HarmonyOS, Realme/OPPO ColorOS, Vivo OriginOS, Amazon FireOS, а также самых навязчивых рекламных и трекинговых мобильных SDK внутри приложений (AppsFlyer, Adjust, Branch.io, Kochava, Singular, AppLovin, Unity Ads, IronSource, Vungle, Mintegral)',
  win_spy:
    '[Маршрут: Блокировать (Block)] Серверы слежки, телеметрии, отчётов об ошибках и рекламы Windows 10/11',
  xiaomi_smarttv_ads:
    '[Маршрут: Блокировать (Block)] Вырезает встроенную системную рекламу и телеметрию в прошивках Xiaomi / Poco / Redmi (MIUI и HyperOS: api.ad.xiaomi.com, tracking.miui.com, mistat.xiaomi.com), а также рекламные баннеры и ACR-слежку на телевизорах Samsung Smart TV (Tizen) и LG webOS',
  et_spamhaus_block:
    '[Маршрут: Блокировать (Block)] Базовый исходящий IP-фильтр сетевых угроз без ложных срабатываний (аналог профилей threat, etcompromised, spamhaus, feodo и dshield в banIP): управляющие C2-серверы ботнетов Abuse.ch Feodo Tracker, скомпрометированные узлы Emerging Threats (ET Block & Compromised), похищенные подсети Spamhaus DROP / eDROP и активные сканеры SANS DShield.',
  hagezi_tif_ip_block:
    '[Маршрут: Блокировать (Block)] Расширенный исходящий список опасных IP-адресов и подсетей (аналог профилей hagezi и webclient в banIP): серверы распространения вредоносного ПО, крипто-дрейнеров, троянов, командные узлы C2 и вредоносные веб-узлы по данным HaGeZi Threat Intelligence IP Feed и FireHOL Webclient. Блокирует прямое подключение по IP даже при обращениях мимо системного DNS.',
  botnet_attackers_ip_block:
    '[Маршрут: Блокировать (Block)] Сводный список IP-адресов с подтверждённой вредоносной активностью по данным десятков независимых сенсоров и ханипотов (аналог профилей ipsum, cinsscore и binarydefense в banIP): IPsum (Level 3+), CINS Army (Sentinel IPS) и Binary Defense ATIF.',
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
