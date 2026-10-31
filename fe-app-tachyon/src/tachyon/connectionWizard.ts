/* eslint-disable @typescript-eslint/no-explicit-any */
import { tr } from './helpers/i18n';
import { showToast } from '../helpers/showToast';
import {
  createInteractiveHintBanner,
  getSubsumedCommunityLists,
} from '../helpers/communityListPicker';
import { renderTachyonDuckMascotSvg } from '../icons/duckMascot';
import {
  renderZapIcon,
  renderShieldIcon,
  renderFolderIcon,
  renderCheckIcon,
  renderCommunityListServiceIcon,
  renderLockIcon,
  renderGamepad2Icon,
  renderBanIcon,
} from '../icons';
import {
  DOMAIN_LIST_HINTS,
  DOMAIN_LIST_OPTIONS,
  TACHYON_UCI_PACKAGE,
} from '../constants';
import { executeShellCommand } from '../helpers/executeShellCommand';
import { TachyonShellMethods } from './methods/shell';
import { applyUiStateToStore } from './services/uiState.service';
import type { Tachyon } from './types';

function getUi(): any {
  if (typeof ui !== 'undefined' && ui) return ui;
  const g = globalThis as any;
  return g.ui || g.L?.ui;
}

function getUci(): any {
  if (typeof uci !== 'undefined' && uci) return uci;
  const g = globalThis as any;
  return g.uci || g.L?.uci;
}

export interface ConnectionWizardOptions {
  initialDirection?: 'outbound' | 'inbound';
  onComplete?: (result: {
    direction: 'outbound' | 'inbound';
    sectionId: string;
  }) => void;
}

interface OutboundMethodOption {
  id:
    | 'subscription'
    | 'proxy_links'
    | 'amnezia_config'
    | 'warp'
    | 'desync'
    | 'fptn'
    | 'custom_proto';
  titleRu: string;
  titleEn: string;
  descRu: string;
  descEn: string;
  badge: string;
}

const OUTBOUND_METHODS: OutboundMethodOption[] = [
  {
    id: 'subscription',
    titleRu: 'Подписка (URL)',
    titleEn: 'Subscription (URL)',
    descRu:
      'Ссылка https://... от вашего провайдера — автоматически загрузит все серверы и будет обновлять их по расписанию',
    descEn:
      'HTTPS subscription link from your provider — imports all nodes and updates them automatically',
    badge: 'AUTO POOL',
  },
  {
    id: 'proxy_links',
    titleRu: 'Ключи и ссылки (VLESS, HY2, TUIC, SS...)',
    titleEn: 'Share Links (VLESS, HY2, TUIC, SS...)',
    descRu:
      'Вставьте одну или несколько ссылок: vless://, hysteria2://, tuic://, trojan://, vmess://, ss://, anytls://, naive+https://, mieru://, trusttunnel://, tewfai://, masque://',
    descEn:
      'Paste one or multiple share links: vless://, hysteria2://, tuic://, trojan://, vmess://, ss://, anytls://, etc.',
    badge: 'MULTI-LINK',
  },
  {
    id: 'amnezia_config',
    titleRu: 'Amnezia / WireGuard (vpn:// или .conf)',
    titleEn: 'Amnezia / WireGuard (vpn:// or .conf)',
    descRu:
      'Вставьте ключ vpn:// из приложения Amnezia или загрузите готовый конфигурационный файл .conf',
    descEn: 'Paste a vpn:// link from Amnezia or upload a .conf tunnel file',
    badge: 'AWG / WG',
  },
  {
    id: 'desync',
    titleRu: 'Обход DPI (Core Desync / Zapret2 / ByeDPI)',
    titleEn: 'DPI Bypass (Core Desync / Zapret2 / ByeDPI)',
    descRu:
      'Модификация и фрагментация пакетов (Tachyon Core Desync, Zapret2 nfqws2, Zapret nfqws, ByeDPI ciadpi) без прокси-сервера',
    descEn:
      'Packet fragmentation and DPI desync (Tachyon Core Desync, Zapret2, Zapret, ByeDPI) without external proxy',
    badge: 'DPI BYPASS',
  },
  {
    id: 'warp',
    titleRu: 'Cloudflare WARP',
    titleEn: 'Cloudflare WARP',
    descRu:
      'Встроенный туннель Cloudflare с автоматической регистрацией ключей в 1 клик',
    descEn:
      'Built-in Cloudflare tunnel with automatic 1-click key registration',
    badge: 'FREE VPN',
  },
  {
    id: 'fptn',
    titleRu: 'FPTN VPN (Токен доступа)',
    titleEn: 'FPTN VPN (Access Token)',
    descRu: 'Подключение по токену fptn:// или fptnb:// с автовыбором узла',
    descEn: 'Connect using an fptn:// or fptnb:// access token',
    badge: 'FPTN',
  },
  {
    id: 'custom_proto',
    titleRu: 'Другой протокол / Интерфейс',
    titleEn: 'Other Protocol / Interface',
    descRu:
      'Ручная настройка AnyTLS, NaiveProxy, Mieru, Snell, Sudoku, MASQUE, TrustTunnel, TewFai, ShadowTLS, OpenConnect, OpenVPN, Tailscale, Tor или сетевого интерфейса',
    descEn:
      'Configure AnyTLS, NaiveProxy, Mieru, Snell, Sudoku, MASQUE, TrustTunnel, TewFai, ShadowTLS, OpenConnect, OpenVPN, Tailscale, Tor, or Network Interface',
    badge: 'PROTOS',
  },
];

const ZAPRET_DEFAULT_NFQWS_OPT =
  '--filter-tcp=80 --dpi-desync=fake,fakedsplit --dpi-desync-autottl=2 --dpi-desync-fooling=badsum --new --filter-tcp=443 --dpi-desync=fake,multidisorder --dpi-desync-split-pos=1,midsld --dpi-desync-repeats=11 --dpi-desync-fooling=badsum --dpi-desync-fake-tls-mod=rnd,dupsid,sni=www.google.com --new --filter-udp=443 --dpi-desync=fake --dpi-desync-repeats=11 --dpi-desync-fake-quic=/opt/zapret/files/fake/quic_initial_www_google_com.bin';

const ZAPRET2_DEFAULT_NFQWS2_OPT =
  '--filter-tcp=80 --filter-l7=http --payload=http_req --lua-desync=fake:blob=fake_default_http:tcp_md5 --lua-desync=multisplit:pos=method+2 --new --filter-tcp=443 --filter-l7=tls --payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:tcp_md5:tcp_seq=-10000 --lua-desync=multidisorder:pos=1,midsld --new --filter-udp=443 --filter-l7=quic --payload=quic_initial --lua-desync=fake:blob=fake_default_quic:repeats=6';

const BYEDPI_DEFAULT_CMD_OPTS = '-o 2 --auto=t,r,a,s -d 2';

const CUSTOM_PROTO_LIST: Array<{
  id: string;
  label: string;
  defaultPort?: string;
}> = [
  { id: 'anytls', label: 'AnyTLS (TLS Padding Scheme)', defaultPort: '443' },
  {
    id: 'naive',
    label: 'NaiveProxy (Chromium HTTPS / HTTP/3 QUIC)',
    defaultPort: '443',
  },
  {
    id: 'mieru',
    label: 'Mieru (TCP / UDP Multiplexed)',
    defaultPort: '2012-2022',
  },
  { id: 'snell', label: 'Snell (v1–v4 + Obfs)', defaultPort: '443' },
  {
    id: 'sudoku',
    label: 'Sudoku (Polymorphic AEAD + HTTP Mask)',
    defaultPort: '443',
  },
  {
    id: 'masque',
    label: 'MASQUE (HTTP/3 QUIC IP/UDP Tunnel)',
    defaultPort: '443',
  },
  {
    id: 'trusttunnel',
    label: 'TrustTunnel (HTTP/2 & HTTP/3 Stealth)',
    defaultPort: '443',
  },
  {
    id: 'tewfai',
    label: 'TewFai (Post-Quantum ML-KEM + Traffic Shaper)',
    defaultPort: '8443',
  },
  {
    id: 'shadowtls',
    label: 'ShadowTLS v3 (TLS Handshake Camouflage)',
    defaultPort: '443',
  },
  {
    id: 'openconnect',
    label: 'OpenConnect (Cisco AnyConnect / Palo Alto GP / Fortinet)',
    defaultPort: '443',
  },
  { id: 'openvpn', label: 'OpenVPN (.ovpn Profile)', defaultPort: '1194' },
  { id: 'tailscale', label: 'Tailscale Mesh VPN (tailscale0)' },
  {
    id: 'tor',
    label: 'Tor Network (Local SOCKS5 Daemon)',
    defaultPort: '9050',
  },
  {
    id: 'interface',
    label: tr(
      'Сетевой интерфейс роутера (wg0 / awg0 / tun0)',
      'Router Network Interface (wg0 / awg0 / tun0)',
    ),
  },
  {
    id: 'outbound_json',
    label: tr(
      'Собственный JSON-аутбаунд (sing-box / tachyon-core)',
      'Custom Raw JSON Outbound (sing-box / tachyon-core)',
    ),
  },
];

const INBOUND_PROTOCOLS: Array<{
  id: string;
  title: string;
  badge: string;
  defaultPort: string;
  descRu: string;
  descEn: string;
}> = [
  {
    id: 'vless',
    title: 'VLESS + Reality',
    badge: 'РЕКОМЕНДУЕТСЯ',
    defaultPort: '443',
    descRu:
      'Максимальная защита от DPI: маскируется под популярный сайт (например microsoft.com), не требует покупки домена',
    descEn:
      'Maximum DPI resistance: camouflages as a popular website (e.g. microsoft.com), no domain required',
  },
  {
    id: 'awg',
    title: 'AmneziaWG (AWG 3.0)',
    badge: 'UDP TUNNEL',
    defaultPort: '51820',
    descRu:
      'Современный защищённый WireGuard с обфускацией пакетов и защитой заголовков',
    descEn:
      'Modern obfuscated WireGuard with packet junk and header protection',
  },
  {
    id: 'hysteria2',
    title: 'Hysteria 2 (QUIC)',
    badge: 'TURBO UDP',
    defaultPort: '8443',
    descRu:
      'Максимальная скорость на мобильных и нестабильных сетях поверх QUIC + Salamander',
    descEn:
      'Maximum throughput over lossy or mobile networks using QUIC + Salamander',
  },
  {
    id: 'tuic',
    title: 'TUIC v5 (QUIC BBR)',
    badge: 'QUIC 0-RTT',
    defaultPort: '8443',
    descRu: 'Низкая задержка и мультиплексирование потоков поверх QUIC с BBR',
    descEn: 'Low-latency 0-RTT stream multiplexing over QUIC with BBR',
  },
  {
    id: 'tewfai',
    title: 'TewFai (PQC + Shaper)',
    badge: 'PQC CORE',
    defaultPort: '8443',
    descRu:
      'Постквантовое шифрование, адаптивный шейпинг трафика и бесшовный хэндовер',
    descEn: 'Post-quantum cryptography, adaptive traffic shaper and handover',
  },
  {
    id: 'anytls',
    title: 'AnyTLS',
    badge: 'TLS PADDING',
    defaultPort: '443',
    descRu: 'Гибкое выравнивание размеров пакетов поверх TLS',
    descEn: 'Flexible packet padding scheme over TLS',
  },
  {
    id: 'trusttunnel',
    title: 'TrustTunnel',
    badge: 'HTTP/2 + H3',
    defaultPort: '443',
    descRu: 'Незаметный туннель поверх стандартного HTTPS / HTTP/3',
    descEn: 'Stealth tunnel over standard HTTPS / HTTP/3',
  },
  {
    id: 'trojan',
    title: 'Trojan TLS',
    badge: 'CLASSIC TLS',
    defaultPort: '443',
    descRu: 'Классический протокол поверх TLS с широкой поддержкой клиентов',
    descEn: 'Classic TLS-based proxy protocol supported by all clients',
  },
  {
    id: 'shadowsocks',
    title: 'Shadowsocks 2022 / AEAD',
    badge: 'LIGHTWEIGHT',
    defaultPort: '8388',
    descRu: 'Лёгкий и быстрый протокол с минимальной нагрузкой на процессор',
    descEn: 'Lightweight and fast AEAD cipher proxy with minimal CPU overhead',
  },
  {
    id: 'socks',
    title: 'SOCKS5 / Mixed',
    badge: 'LAN / WAN',
    defaultPort: '1080',
    descRu: 'Универсальный прокси с авторизацией по логину и паролю',
    descEn: 'Universal proxy with username and password authentication',
  },
];

const TRAFFIC_PRESETS: Array<{
  id: string;
  labelRu: string;
  labelEn: string;
  domains: string[];
}> = [
  {
    id: 'youtube',
    labelRu: 'YouTube и Google Video',
    labelEn: 'YouTube & Google Video',
    domains: ['youtube'],
  },
  {
    id: 'discord',
    labelRu: 'Discord (текст, голос и CDN)',
    labelEn: 'Discord (text, voice & CDN)',
    domains: ['discord'],
  },
  {
    id: 'telegram',
    labelRu: 'Telegram (чаты, медиа и DC1–DC5)',
    labelEn: 'Telegram (chats, media & DC1–DC5)',
    domains: ['telegram'],
  },
  {
    id: 'rkn_geoblock',
    labelRu: 'Базовый обход РФ + Геоблок 150+ сервисов + SSL CA',
    labelEn: 'Base Russia Bypass + GeoBlock 150+ + SSL CA',
    domains: ['russia_inside', 'hodca'],
  },
  {
    id: 'antifilter_refilter',
    labelRu: 'Расширенный реестр РКН, Антизапрет и Re:filter',
    labelEn: 'Extended RKN Registry, Antizapret & Re:filter',
    domains: ['ru_blocked', 'refilter', 'antifilter'],
  },
  {
    id: 'ai',
    labelRu: 'Нейросети и ИИ (ChatGPT, Claude, Gemini, Grok, Cursor)',
    labelEn: 'AI Services (ChatGPT, Claude, Gemini, Grok, Cursor)',
    domains: ['ai_all', 'google_ai'],
  },
  {
    id: 'social',
    labelRu: 'Соцсети (Instagram/Meta, X/Twitter, TikTok, Pinterest)',
    labelEn: 'Social Media (Meta, X/Twitter, TikTok, Pinterest)',
    domains: ['meta', 'twitter', 'tiktok', 'pinterest'],
  },
  {
    id: 'streaming',
    labelRu: 'Кино, музыка и стримы (Spotify, Netflix, Twitch, HDRezka, Аниме)',
    labelEn: 'Streaming & Music (Spotify, Netflix, Twitch, HDRezka, Anime)',
    domains: ['spotify', 'netflix', 'twitch', 'hdrezka', 'anime'],
  },
  {
    id: 'gaming',
    labelRu: 'Заблокированные игры (Roblox, Brawl Stars/Supercell, EA, FACEIT)',
    labelEn: 'Blocked Games (Roblox, Supercell, EA/Origin, FACEIT)',
    domains: ['roblox', 'supercell', 'origin', 'faceit'],
  },
  {
    id: 'dev_cloud',
    labelRu: 'Разработка и CDN (GitHub, Docker, Cloudflare, Hetzner, OVH, DO)',
    labelEn: 'Dev & Cloud CDN (GitHub, Docker, Cloudflare, Hetzner, OVH, DO)',
    domains: [
      'github',
      'docker',
      'cloudflare',
      'cloudfront',
      'fastly',
      'hetzner',
      'ovh',
      'digitalocean',
    ],
  },
  {
    id: 'ecosystems',
    labelRu: 'Экосистемы (Apple, Microsoft/Xbox, Google Play)',
    labelEn: 'Ecosystems (Apple, Microsoft/Xbox, Google Play)',
    domains: ['apple', 'microsoft', 'google_play'],
  },
  {
    id: 'media_extra',
    labelRu: 'СМИ, Торренты и Tor (Meduza/BBC, RuTracker, Tor)',
    labelEn: 'News, Torrents & Tor',
    domains: ['news', 'torrent', 'tor'],
  },
];

const TACHYON_LIST_CATEGORIES: Array<{
  id: string;
  titleRu: string;
  titleEn: string;
  keys: Array<keyof typeof DOMAIN_LIST_OPTIONS>;
}> = [
  {
    id: 'rkn',
    titleRu: 'Реестры блокировок и Геоблок',
    titleEn: 'Censorship & GeoBlock Registries',
    keys: [
      'russia_inside',
      'geoblock',
      'ru_blocked',
      'refilter',
      'antifilter',
      'block',
      'ru_blocked_all',
    ],
  },
  {
    id: 'ai',
    titleRu: 'Нейросети и ИИ',
    titleEn: 'AI & LLMs',
    keys: ['ai_all', 'openai', 'anthropic', 'google_ai', 'xai'],
  },
  {
    id: 'media',
    titleRu: 'Видео, Стримы и Музыка',
    titleEn: 'Video, Streams & Music',
    keys: [
      'youtube',
      'twitch',
      'twitch_ads',
      'spotify',
      'netflix',
      'tiktok',
      'hdrezka',
      'anime',
      'pinterest',
    ],
  },
  {
    id: 'social',
    titleRu: 'Мессенджеры и Соцсети',
    titleEn: 'Messengers & Social Networks',
    keys: ['discord', 'telegram', 'meta', 'twitter'],
  },
  {
    id: 'games',
    titleRu: 'Игры и Лаунчеры',
    titleEn: 'Games & Launchers',
    keys: [
      'steam',
      'epicgames',
      'riot',
      'origin',
      'roblox',
      'supercell',
      'escapefromtarkov',
      'faceit',
    ],
  },
  {
    id: 'cloud',
    titleRu: 'Платформы, Разработка и CDN',
    titleEn: 'Platforms, Dev & Cloud CDN',
    keys: [
      'apple',
      'microsoft',
      'google_play',
      'github',
      'docker',
      'hodca',
      'cloudflare',
      'cloudfront',
      'fastly',
      'hetzner',
      'ovh',
      'digitalocean',
    ],
  },
  {
    id: 'extra',
    titleRu: 'Медиа, Торренты и 18+',
    titleEn: 'News, Torrents & Adult',
    keys: ['news', 'torrent', 'tor', 'porn'],
  },
];

const DIRECT_BYPASS_PRESETS: Array<{
  key: keyof typeof DOMAIN_LIST_OPTIONS;
  labelRu: string;
  labelEn: string;
}> = [
  {
    key: 'steam',
    labelRu: 'Steam (магазин и быстрая загрузка игр Valve)',
    labelEn: 'Steam (Valve store & fast CDN downloads)',
  },
  {
    key: 'riot',
    labelRu: 'Riot Games (Valorant / LoL — низкий пинг без VPN)',
    labelEn: 'Riot Games (Valorant / LoL — low ping direct)',
  },
  {
    key: 'epicgames',
    labelRu: 'Epic Games (Fortnite / Rocket League / EasyAntiCheat)',
    labelEn: 'Epic Games (Fortnite / Rocket League / EasyAntiCheat)',
  },
  {
    key: 'escapefromtarkov',
    labelRu: 'Escape from Tarkov (серверы Battlestate Games)',
    labelEn: 'Escape from Tarkov (Battlestate Games servers)',
  },
  {
    key: 'origin',
    labelRu: 'EA / Origin (Apex Legends, Battlefield, EA FC)',
    labelEn: 'EA / Origin (Apex Legends, Battlefield, EA FC)',
  },
  {
    key: 'faceit',
    labelRu: 'FACEIT (CS2 серверы и античит)',
    labelEn: 'FACEIT (CS2 servers & anti-cheat)',
  },
  {
    key: 'microsoft',
    labelRu: 'Microsoft и Xbox Live (загрузки Windows / Xbox)',
    labelEn: 'Microsoft & Xbox Live (Windows / Xbox CDN)',
  },
  {
    key: 'apple',
    labelRu: 'Apple, App Store и iCloud (высокая скорость CDN)',
    labelEn: 'Apple, App Store & iCloud (fast CDN)',
  },
  {
    key: 'google_play',
    labelRu: 'Google Play (скачивание приложений Android)',
    labelEn: 'Google Play (Android APK downloads)',
  },
  {
    key: 'ru_whitelist',
    labelRu:
      'Белый список РФ (Госуслуги, Сбер, Т-Банк, Альфа, Ozon, WB, Яндекс, VK, РЖД)',
    labelEn: 'RU Whitelist (Gosuslugi, Banks, Ozon, WB, Yandex, VK)',
  },
  {
    key: 'ru_only_inside',
    labelRu: 'Строго из РФ (Госпорталы, суды, ЕМИАС, ЖКХ — блок с VPN)',
    labelEn: 'Strictly Inside RU (Gov portals, courts, EMIAS)',
  },
  {
    key: 'ru_domains',
    labelRu: 'Доменные зоны Рунета (.ru, .рф, .su, .by, .kz)',
    labelEn: 'Runet & CIS TLDs (.ru, .рф, .su, .by, .kz)',
  },
  {
    key: 'russia_outside',
    labelRu: 'Кинотеатры и сервисы РФ (Кинопоиск, Иви, Wink, Ozon, WB)',
    labelEn: 'Russian Streaming & Services (Kinopoisk, Ivi, Wink)',
  },
  {
    key: 'push',
    labelRu: 'Push-уведомления (Apple APNs, Google FCM, Xiaomi, Huawei)',
    labelEn: 'Push Notifications (Apple APNs, Google FCM, Xiaomi, Huawei)',
  },
];

const WIZARD_GLOBAL_DNS_PRESETS: Array<{
  id: string;
  labelRu: string;
  labelEn: string;
  shortRu: string;
  shortEn: string;
  badge: string;
  descRu: string;
  descEn: string;
  dnsType: 'udp' | 'doh' | 'dot';
  servers: string[];
  bootstrap: string[];
}> = [
  {
    id: 'autotune',
    labelRu: 'Автоподбор лучшего DNS (Smart Auto-Tune & Benchmark)',
    labelEn: 'Smart DNS Auto-Tune (Benchmark Best Stack)',
    shortRu: 'Автоподбор DNS',
    shortEn: 'Auto-Tune DNS',
    badge: 'AUTO BEST',
    descRu:
      'Основной DoH + быстрый Bootstrap + Fallback по реальному замеру на вашем провайдере',
    descEn:
      'Primary DoH + fast Bootstrap + Fallback based on live router benchmark',
    dnsType: 'doh',
    servers: ['https://common.dot.dns.yandex.net/dns-query'],
    bootstrap: ['77.88.8.8', '1.1.1.1'],
  },
  {
    id: 'keep',
    labelRu: 'Оставить текущие настройки DNS роутера без изменений',
    labelEn: 'Keep current router DNS settings unchanged',
    shortRu: 'Текущий DNS',
    shortEn: 'Keep Current',
    badge: 'UNCHANGED',
    descRu: 'Не менять глобальные настройки DNS роутера на этом шаге',
    descEn: 'Keep existing router DNS settings untouched',
    dnsType: 'udp',
    servers: [],
    bootstrap: [],
  },
  {
    id: 'yandex_udp',
    labelRu:
      'Яндекс DNS (77.88.8.8 / 77.88.8.1, UDP) — быстрый отклик и российские CDN',
    labelEn: 'Yandex DNS (77.88.8.8 / 77.88.8.1, UDP) — fast for RU & games',
    shortRu: 'Яндекс DNS (UDP)',
    shortEn: 'Yandex DNS (UDP)',
    badge: '77.88.8.8',
    descRu: 'Минимальный пинг (5–15 мс) в РФ и точная маршрутизация на RU CDN',
    descEn: 'Lowest latency in RU and accurate local CDN resolution',
    dnsType: 'udp',
    servers: ['77.88.8.8', '77.88.8.1'],
    bootstrap: ['77.88.8.8', '77.88.8.1'],
  },
  {
    id: 'yandex_doh',
    labelRu: 'Яндекс DNS (DoH HTTPS — common.dot.dns.yandex.net)',
    labelEn: 'Yandex DNS (DoH HTTPS — common.dot.dns.yandex.net)',
    shortRu: 'Яндекс DoH',
    shortEn: 'Yandex DoH',
    badge: 'HTTPS RU',
    descRu: 'Шифрованный российский DNS поверх HTTPS (защита от перехвата)',
    descEn: 'Encrypted Russian DNS over HTTPS with local CDN accuracy',
    dnsType: 'doh',
    servers: ['https://common.dot.dns.yandex.net/dns-query'],
    bootstrap: ['77.88.8.8', '77.88.8.1'],
  },
  {
    id: 'cloudflare_doh',
    labelRu: 'Cloudflare DNS (1.1.1.1, DoH HTTPS — быстрый зарубежный)',
    labelEn: 'Cloudflare DNS (1.1.1.1, DoH HTTPS)',
    shortRu: 'Cloudflare DoH',
    shortEn: 'Cloudflare DoH',
    badge: '1.1.1.1 HTTPS',
    descRu: 'Быстрый глобальный шифрованный резолвер без фильтрации',
    descEn: 'Fast global encrypted DNS resolver (cloudflare-dns.com)',
    dnsType: 'doh',
    servers: ['https://cloudflare-dns.com/dns-query'],
    bootstrap: ['1.1.1.1', '1.0.0.1'],
  },
  {
    id: 'cloudflare_udp',
    labelRu: 'Cloudflare DNS (1.1.1.1 / 1.0.0.1, UDP)',
    labelEn: 'Cloudflare DNS (1.1.1.1 / 1.0.0.1, UDP)',
    shortRu: 'Cloudflare UDP',
    shortEn: 'Cloudflare UDP',
    badge: '1.1.1.1 UDP',
    descRu: 'Классический быстрый DNS Cloudflare по протоколу UDP 53',
    descEn: 'Classic Cloudflare UDP 53 resolver (1.1.1.1 / 1.0.0.1)',
    dnsType: 'udp',
    servers: ['1.1.1.1', '1.0.0.1'],
    bootstrap: ['1.1.1.1', '1.0.0.1'],
  },
  {
    id: 'google_doh',
    labelRu: 'Google DNS (8.8.8.8, DoH HTTPS — dns.google)',
    labelEn: 'Google DNS (8.8.8.8, DoH HTTPS — dns.google)',
    shortRu: 'Google DoH',
    shortEn: 'Google DoH',
    badge: '8.8.8.8 HTTPS',
    descRu: 'Надёжный шифрованный глобальный DNS от Google (dns.google)',
    descEn: 'Reliable global encrypted DNS over HTTPS by Google',
    dnsType: 'doh',
    servers: ['https://dns.google/dns-query'],
    bootstrap: ['8.8.8.8', '8.8.4.4'],
  },
  {
    id: 'adguard_doh',
    labelRu: 'AdGuard DNS (94.140.14.14, DoH HTTPS — фильтрация рекламы)',
    labelEn: 'AdGuard DNS (94.140.14.14, DoH HTTPS — ad blocking)',
    shortRu: 'AdGuard DoH',
    shortEn: 'AdGuard DoH',
    badge: 'ADBLOCK HTTPS',
    descRu: 'Шифрованный DoH с блокировкой рекламы, трекеров и фишинга',
    descEn: 'Encrypted DoH with built-in ad, tracker, and phishing blocker',
    dnsType: 'doh',
    servers: ['https://dns.adguard-dns.com/dns-query'],
    bootstrap: ['94.140.14.14', '94.140.15.15'],
  },
  {
    id: 'quad9_doh',
    labelRu: 'Quad9 DNS (9.9.9.9, DoH HTTPS — защита и приватность)',
    labelEn: 'Quad9 DNS (9.9.9.9, DoH HTTPS — security & privacy)',
    shortRu: 'Quad9 DoH',
    shortEn: 'Quad9 DoH',
    badge: '9.9.9.9 HTTPS',
    descRu: 'Швейцарский шифрованный DNS с защитой от вредоносных доменов',
    descEn: 'Swiss privacy-focused encrypted DNS with malware protection',
    dnsType: 'doh',
    servers: ['https://dns.quad9.net/dns-query'],
    bootstrap: ['9.9.9.9', '149.112.112.112'],
  },
  {
    id: 'custom',
    labelRu: 'Свой DNS-сервер (указать вручную)',
    labelEn: 'Custom DNS Server (enter manually)',
    shortRu: 'Свой DNS',
    shortEn: 'Custom DNS',
    badge: 'MANUAL',
    descRu: 'Указать собственный UDP / DoH / DoT сервер вручную',
    descEn: 'Specify your own UDP, DoH, or DoT resolver address',
    dnsType: 'udp',
    servers: [],
    bootstrap: [],
  },
];

const DIRECT_BYPASS_DNS_PRESETS: Array<{
  id: string;
  labelRu: string;
  labelEn: string;
  dnsType: 'udp' | 'dot' | 'doh';
  servers: string[];
}> = [
  {
    id: 'yandex_udp',
    labelRu: 'Яндекс DNS (UDP 77.88.8.8, 77.88.8.1) — Рекомендуется для игр',
    labelEn: 'Yandex DNS (UDP 77.88.8.8, 77.88.8.1) — Recommended for games',
    dnsType: 'udp',
    servers: ['77.88.8.8', '77.88.8.1'],
  },
  {
    id: 'yandex_dot',
    labelRu: 'Яндекс DNS (DoT TLS — common.dot.dns.yandex.net)',
    labelEn: 'Yandex DNS (DoT TLS — common.dot.dns.yandex.net)',
    dnsType: 'dot',
    servers: ['common.dot.dns.yandex.net'],
  },
  {
    id: 'yandex_doh',
    labelRu: 'Яндекс DNS (DoH HTTPS — common.dot.dns.yandex.net/dns-query)',
    labelEn: 'Yandex DNS (DoH HTTPS — common.dot.dns.yandex.net/dns-query)',
    dnsType: 'doh',
    servers: ['https://common.dot.dns.yandex.net/dns-query'],
  },
  {
    id: 'adguard_udp',
    labelRu: 'AdGuard DNS (UDP 94.140.14.14, 94.140.15.15)',
    labelEn: 'AdGuard DNS (UDP 94.140.14.14, 94.140.15.15)',
    dnsType: 'udp',
    servers: ['94.140.14.14', '94.140.15.15'],
  },
  {
    id: 'custom',
    labelRu: 'Свой DNS провайдера (ISP / локальный роутер)',
    labelEn: 'Custom ISP / Local DNS Server',
    dnsType: 'udp',
    servers: [],
  },
];

function sanitizeId(raw: string, prefix: string): string {
  const cleaned = String(raw || '')
    .trim()
    .replace(/[^A-Za-z0-9_]/g, '_')
    .replace(/_+/g, '_')
    .replace(/^_+|_+$/g, '');
  const base = cleaned
    ? `${prefix}_${cleaned}`
    : `${prefix}_${Date.now() % 10000}`;
  const uciObj = getUci();
  if (!uciObj || typeof uciObj.get !== 'function') return base;
  if (!uciObj.get(TACHYON_UCI_PACKAGE, base)) return base;
  let i = 2;
  while (uciObj.get(TACHYON_UCI_PACKAGE, `${base}_${i}`)) {
    i++;
  }
  return `${base}_${i}`;
}

function generateRandomHex(bytes: number): string {
  const arr = new Uint8Array(bytes);
  if (typeof crypto !== 'undefined' && crypto.getRandomValues) {
    crypto.getRandomValues(arr);
  } else {
    for (let i = 0; i < bytes; i++) arr[i] = Math.floor(Math.random() * 256);
  }
  return Array.from(arr)
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('');
}

function generateUuidV4(): string {
  if (
    typeof crypto !== 'undefined' &&
    typeof crypto.randomUUID === 'function'
  ) {
    return crypto.randomUUID();
  }
  const hex = generateRandomHex(16);
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-4${hex.slice(13, 16)}-a${hex.slice(17, 20)}-${hex.slice(20, 32)}`;
}

function generateBase64Key(bytes = 32): string {
  const arr = new Uint8Array(bytes);
  if (typeof crypto !== 'undefined' && crypto.getRandomValues) {
    crypto.getRandomValues(arr);
  } else {
    for (let i = 0; i < bytes; i++) arr[i] = Math.floor(Math.random() * 256);
  }
  let binary = '';
  for (let i = 0; i < arr.length; i++) {
    binary += String.fromCharCode(arr[i]);
  }
  if (typeof btoa === 'function') {
    return btoa(binary);
  }
  return generateRandomHex(bytes);
}

function randomIntInRange(min: number, max: number): number {
  return Math.floor(Math.random() * (max - min + 1)) + min;
}

export function openConnectionWizardModal(
  options: ConnectionWizardOptions = {},
): void {
  const uiObj = getUi();
  const uciObj = getUci();
  if (!uiObj || typeof uiObj.showModal !== 'function' || !uciObj) {
    return;
  }

  let step: 1 | 2 | 3 | 4 = options.initialDirection ? 2 : 1;
  let direction: 'outbound' | 'inbound' =
    options.initialDirection || 'outbound';

  // Outbound state
  let outboundMethod: OutboundMethodOption['id'] = 'subscription';
  let customProto = 'anytls';
  let connName = '';
  let subUrl = '';
  let proxyLinksText = '';
  let amneziaText = '';

  // WARP state
  let warpPrivateKey = '';
  let warpPeerPublicKey = 'bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=';
  let warpLocalAddress = '172.16.0.2/32';
  let warpIpv6 = '';
  let warpServer = '162.159.192.1';
  let warpServerPort = '2408';
  let warpReserved = '';
  let warpMtu = '1280';
  let warpFakePackets = '5-10';
  const warpAwgOptions: Record<string, string> = {};
  let isGeneratingWarp = false;

  const applyGeneratedWarpPayload = (data: Record<string, any>) => {
    if (!data || typeof data !== 'object') return;
    if (data.private_key) warpPrivateKey = String(data.private_key);
    if (data.public_key || data.peer_public_key) {
      warpPeerPublicKey = String(data.public_key || data.peer_public_key);
    }
    if (data.v4 || data.local_address) {
      warpLocalAddress = String(data.v4 || data.local_address);
    }
    if (data.v6 || data.ipv6_address) {
      warpIpv6 = String(data.v6 || data.ipv6_address);
    }
    if (data.reserved) {
      warpReserved = Array.isArray(data.reserved)
        ? data.reserved.join(',')
        : String(data.reserved);
    }
    if (data.server_address || data.server) {
      warpServer = String(data.server_address || data.server);
    }
    if (data.server_port) {
      warpServerPort = String(data.server_port);
    }
    if (data.endpoint) {
      const m = String(data.endpoint).match(/^([^:]+):(\d+)$/);
      if (m) {
        warpServer = m[1];
        warpServerPort = m[2];
      }
    }
    const awgKeys = [
      'awg_version',
      'awg_jc',
      'awg_jmin',
      'awg_jmax',
      'awg_s1',
      'awg_s2',
      'awg_s3',
      'awg_s4',
      'awg_h1',
      'awg_h2',
      'awg_h3',
      'awg_h4',
      'awg_i1',
      'awg_i2',
      'awg_i3',
      'awg_i4',
      'awg_i5',
    ];
    for (const k of awgKeys) {
      if (data[k] !== undefined && data[k] !== null && String(data[k]) !== '') {
        warpAwgOptions[k] = String(data[k]);
      }
    }
  };

  // FPTN state
  let fptnToken = '';
  let fptnBypassMethod = 'obfuscation';
  let fptnSni = '';
  let fptnPreferredServer = '';

  // Desync / DPI state
  let dpiEngineType: 'desync' | 'zapret2' | 'zapret' | 'byedpi' = 'desync';
  let desyncPresetKey = 'fake_split';
  let desyncMode = 'fake_split';
  let desyncSplitPos = 'sni';
  let desyncFakeTtl = '6';
  let desyncFakeSni = 'www.google.com';
  const desyncUdpFake = true;
  let desyncPreset =
    '--dpi-desync=fake,multidisorder --dpi-desync-split-pos=1,midsld --dpi-desync-fooling=badsum';
  let nfqws2Opt = ZAPRET2_DEFAULT_NFQWS2_OPT;
  let nfqwsOpt = ZAPRET_DEFAULT_NFQWS_OPT;
  let directNfqws = true;
  let byedpiCmdOpts = BYEDPI_DEFAULT_CMD_OPTS;

  // Custom protocol shared & specific state
  let customHost = '';
  let customPort = '443';
  let customUsername = '';
  let customPassword = '';
  let customSni = '';
  let customInsecure = false;
  let customInterface = 'wg0';

  // AnyTLS
  let anytlsAlpn = 'h2, http/1.1';
  const anytlsIdleInterval = '30s';
  let anytlsIdleTimeout = '30s';
  let anytlsMinIdle = '5';

  // NaiveProxy
  let naiveQuic = false;
  let naiveCongestion = 'bbr';
  let naiveConcurrency = '1';
  let naiveUot = false;
  const naiveExtraHeaders = '';

  // Mieru
  let mieruTransport: 'TCP' | 'UDP' = 'TCP';
  let mieruMultiplexing = 'MULTIPLEXING_HIGH';
  let mieruHandshake = 'HANDSHAKE_STANDARD';

  // Snell
  let snellVersion = '4';
  let snellObfs = 'tls';
  let snellObfsHost = 'www.bing.com';
  let snellUot = true;

  // Sudoku
  let sudokuAead = 'chacha20-poly1305';
  let sudokuAscii = 'prefer_entropy';
  let sudokuHttpMask = true;
  let sudokuMaskHost = 'www.cloudflare.com';

  // MASQUE
  let masquePublicKey = '';
  let masqueLocalAddr = '172.16.0.2/32';
  const masqueIpv6 = '';
  let masqueUri = '';
  let masqueMtu = '1280';
  let masqueVhttp = false;

  // TrustTunnel
  let trusttunnelQuic = false;
  let trusttunnelHealthCheck = true;

  // TewFai
  let tewfaiTransports = 'quic, h3_datagram, h2, tcp';
  let tewfaiInnerCipher = '';
  let tewfaiMorphProfile = 'browsing';

  // ShadowTLS
  let shadowtlsVersion = '3';

  // OpenConnect
  let openconnectProtocol = 'anyconnect';
  let openconnectAuthgroup = '';
  let openconnectServercert = '';
  let openconnectNoDtls = false;

  // OpenVPN
  let openvpnConfig = '';
  let openvpnProto: 'udp' | 'tcp' = 'udp';
  let openvpnCipher = 'AES-256-GCM';

  // Tor & JSON
  let torSocksPort = '9050';
  let outboundJsonText = '';

  let targetMode: 'existing' | 'new' | 'pool_only' = 'existing';
  let targetExistingSection = 'Main';
  let newSectionName = '';
  const selectedPresets = new Set<string>([
    'youtube',
    'discord',
    'rkn_geoblock',
  ]);
  const selectedIndividualLists = new Set<string>();
  let showAllTachyonLists = false;
  let appendPresetsToExisting = false;
  let customDomainsText = '';
  let enableAutoUrlTest = true;

  // Step 4: DNS & Direct Bypass for Games / RU Services
  let globalDnsPreset = 'keep';
  let customGlobalDnsType: 'udp' | 'doh' | 'dot' = 'udp';
  let customGlobalDnsServer = '77.88.8.8';
  let enableDnsDetour = false;
  let enableDirectGamesBypass = false;
  let directBypassDnsPreset = 'yandex_udp';
  let customDirectBypassDnsServer = '77.88.8.8';
  const selectedDirectBypassLists = new Set<string>([
    'steam',
    'riot',
    'epicgames',
    'ru_whitelist',
    'ru_only_inside',
  ]);
  let directBypassCustomDomains = '';
  let directBypassSourceIps = '';
  let enableAdBlockSection = false;

  // Step 4: Live DNS Benchmark & Auto-Tune state
  let dnsBenchRunning = false;
  let dnsBenchProgress = 0;
  let dnsBenchCurrentServer = '';
  let dnsBenchRecommendation: Tachyon.DnsBenchmarkRecommendation | null = null;
  let dnsBenchError: string | null = null;
  let dnsBenchPollTimer: number | null = null;
  let dnsBenchPolling = false;
  let dnsBenchHydrated = false;

  function stopDnsBenchPollTimer() {
    if (dnsBenchPollTimer !== null) {
      clearInterval(dnsBenchPollTimer);
      dnsBenchPollTimer = null;
    }
  }

  // Inbound state
  let inboundProto = 'vless';
  let inboundName = 'Tachyon VPN';
  let inboundPort = '443';
  let inboundSni = 'www.microsoft.com';
  let inboundCountry = 'RU';
  let inboundOpenFirewall = true;
  let inboundRoutingMode = 'rules';

  const existingSections = (
    uciObj.sections(TACHYON_UCI_PACKAGE, 'section') || []
  ).map((s: any) => ({
    id: s['.name'],
    label: s.label || s.name || s['.name'],
  }));
  if (existingSections.length > 0) {
    targetExistingSection = existingSections[0].id;
  } else {
    targetMode = 'new';
  }

  const root = E('div', { class: 'tachyon-wizard' }, []);

  function renderStepIndicator() {
    const steps =
      direction === 'outbound'
        ? [
            { num: 1, label: tr('Тип', 'Type') },
            { num: 2, label: tr('Подключение', 'Connection') },
            { num: 3, label: tr('Маршрут и списки', 'Routing & Lists') },
            { num: 4, label: tr('DNS и Игры / РФ', 'DNS & Games / Direct') },
          ]
        : [
            { num: 1, label: tr('Тип', 'Type') },
            { num: 2, label: tr('Протокол сервера', 'Server Protocol') },
            { num: 3, label: tr('Параметры запуска', 'Launch Settings') },
          ];

    return E(
      'div',
      { class: 'tachyon-wizard__steps' },
      steps.map((s) =>
        E(
          'div',
          {
            class: [
              'tachyon-wizard__step-pill',
              step === s.num ? 'is-active' : '',
              step > s.num ? 'is-done' : '',
            ]
              .filter(Boolean)
              .join(' '),
            style: 'cursor: pointer;',
            click: () => {
              step = s.num as 1 | 2 | 3 | 4;
              rerender();
            },
          },
          [
            E(
              'span',
              { class: 'tachyon-wizard__step-num' },
              step > s.num ? renderCheckIcon(12) : String(s.num),
            ),
            E('span', { class: 'tachyon-wizard__step-label' }, s.label),
          ],
        ),
      ),
    );
  }

  function renderStep1() {
    return E('div', { class: 'tachyon-wizard__body' }, [
      E(
        'p',
        { class: 'tachyon-wizard__subtitle' },
        tr(
          'Выберите, какое подключение нужно добавить. Мастер автоматически создаст все необходимые сущности с оптимальными настройками.',
          'Choose what kind of connection to add. The wizard will automatically configure all required entities with optimal defaults.',
        ),
      ),
      E('div', { class: 'tachyon-wizard__cards-2col' }, [
        E(
          'button',
          {
            type: 'button',
            class: `tachyon-wizard__choice-card ${direction === 'outbound' ? 'is-selected' : ''}`,
            click: () => {
              direction = 'outbound';
              step = 2;
              rerender();
            },
          },
          [
            E('div', { class: 'tachyon-wizard__choice-badge' }, 'OUTBOUND'),
            E(
              'div',
              { class: 'tachyon-wizard__choice-title' },
              tr(
                'Исходящее подключение (Аутбаунд)',
                'Outbound Connection (Client / DPI)',
              ),
            ),
            E(
              'div',
              { class: 'tachyon-wizard__choice-desc' },
              tr(
                'Подключить подписку, ключи VLESS / Hysteria2 / TUIC / SS, конфиг AmneziaWG / WireGuard, Cloudflare WARP или встроенный нативный Desync ядра Tachyon Core для обхода блокировок.',
                'Add a subscription URL, VLESS / Hysteria2 / TUIC / SS share links, AmneziaWG / WireGuard config, Cloudflare WARP, or built-in Tachyon Core Desync.',
              ),
            ),
          ],
        ),
        E(
          'button',
          {
            type: 'button',
            class: `tachyon-wizard__choice-card ${direction === 'inbound' ? 'is-selected' : ''}`,
            click: () => {
              direction = 'inbound';
              step = 2;
              rerender();
            },
          },
          [
            E('div', { class: 'tachyon-wizard__choice-badge' }, 'INBOUND'),
            E(
              'div',
              { class: 'tachyon-wizard__choice-title' },
              tr(
                'Входящий сервер на роутере (Инбаунд)',
                'Inbound Server on Router (Host)',
              ),
            ),
            E(
              'div',
              { class: 'tachyon-wizard__choice-desc' },
              tr(
                'Поднять свой собственный VPN/прокси-сервер на роутере (VLESS Reality, AmneziaWG, Hysteria2, TUIC, TewFai, AnyTLS и др.) с автогенерацией ключей и QR-кодом.',
                'Host your own VPN/proxy server on this router (VLESS Reality, AmneziaWG, Hysteria2, TUIC, TewFai, AnyTLS, etc.) with 1-click key generation and QR codes.',
              ),
            ),
          ],
        ),
      ]),
    ]);
  }

  function renderStep2Outbound() {
    const methodCards = OUTBOUND_METHODS.map((m) =>
      E(
        'button',
        {
          type: 'button',
          class: `tachyon-wizard__method-card ${outboundMethod === m.id ? 'is-selected' : ''}`,
          click: () => {
            outboundMethod = m.id;
            rerender();
          },
        },
        [
          E('div', { class: 'tachyon-wizard__method-header' }, [
            E(
              'span',
              { class: 'tachyon-wizard__method-title' },
              tr(m.titleRu, m.titleEn),
            ),
            E('span', { class: 'tachyon-wizard__method-badge' }, m.badge),
          ]),
          E(
            'div',
            { class: 'tachyon-wizard__method-desc' },
            tr(m.descRu, m.descEn),
          ),
        ],
      ),
    );

    const formFields: HTMLElement[] = [
      E('div', { class: 'tachyon-wizard__field' }, [
        E(
          'label',
          { class: 'tachyon-wizard__label' },
          tr('Название подключения', 'Connection Name'),
        ),
        E('input', {
          type: 'text',
          class: 'cbi-input-text tachyon-wizard__input',
          placeholder: tr(
            'Например: Основная подписка, Германия VLESS, Мой AWG',
            'e.g. Main Subscription, Germany VLESS, My AWG',
          ),
          value: connName,
          input: (ev: Event) => {
            connName = (ev.target as HTMLInputElement).value;
          },
        } as any),
      ]),
    ];

    if (outboundMethod === 'subscription') {
      formFields.push(
        E('div', { class: 'tachyon-wizard__field' }, [
          E(
            'label',
            { class: 'tachyon-wizard__label' },
            tr('Ссылка на подписку (HTTPS URL)', 'Subscription URL (HTTPS)'),
          ),
          E('input', {
            type: 'url',
            class: 'cbi-input-text tachyon-wizard__input',
            placeholder: 'https://example.com/sub/...',
            value: subUrl,
            input: (ev: Event) => {
              subUrl = (ev.target as HTMLInputElement).value;
            },
          } as any),
        ]),
      );
    } else if (outboundMethod === 'proxy_links') {
      formFields.push(
        E('div', { class: 'tachyon-wizard__field' }, [
          E(
            'label',
            { class: 'tachyon-wizard__label' },
            tr(
              'Ссылки на серверы (по одной на строке)',
              'Server share links (one per line)',
            ),
          ),
          E(
            'textarea',
            {
              class: 'cbi-input-textarea tachyon-wizard__textarea',
              rows: 4,
              placeholder:
                'vless://uuid@host:443?security=reality&sni=www.microsoft.com&pbk=...#Germany\nhysteria2://pass@host:8443?sni=...#Finland',
              input: (ev: Event) => {
                proxyLinksText = (ev.target as HTMLTextAreaElement).value;
              },
            } as any,
            proxyLinksText,
          ),
        ]),
      );
    } else if (outboundMethod === 'amnezia_config') {
      const fileBtn = E(
        'button',
        {
          type: 'button',
          class: 'btn cbi-button cbi-button-action',
          style: 'margin-bottom: 8px;',
          click: () => {
            const inp = document.createElement('input');
            inp.type = 'file';
            inp.accept = '.conf,.wg,.txt';
            inp.addEventListener('change', () => {
              const file = inp.files?.[0];
              if (!file) return;
              const reader = new FileReader();
              reader.onload = (e) => {
                amneziaText = String(e.target?.result || '').trim();
                if (!connName) {
                  connName = file.name.replace(/\.(conf|wg|txt)$/i, '');
                }
                rerender();
              };
              reader.readAsText(file);
            });
            inp.click();
          },
        },
        [
          renderFolderIcon(14),
          E('span', {}, tr('Загрузить файл .conf', 'Upload .conf file')),
        ],
      );

      formFields.push(
        E('div', { class: 'tachyon-wizard__field' }, [
          E(
            'label',
            { class: 'tachyon-wizard__label' },
            tr(
              'Ключ vpn:// или содержимое файла .conf',
              'vpn:// link or .conf file content',
            ),
          ),
          fileBtn,
          E(
            'textarea',
            {
              class: 'cbi-input-textarea tachyon-wizard__textarea',
              rows: 5,
              placeholder: 'vpn://... или [Interface] ... [Peer] ...',
              input: (ev: Event) => {
                amneziaText = (ev.target as HTMLTextAreaElement).value;
              },
            } as any,
            amneziaText,
          ),
        ]),
      );
    } else if (outboundMethod === 'warp') {
      const genBtn = E(
        'button',
        {
          type: 'button',
          class: 'btn cbi-button cbi-button-action',
          style: 'margin-bottom: 10px;',
          disabled: isGeneratingWarp ? true : undefined,
          click: () => {
            const g = globalThis as any;
            const fsObj =
              (typeof fs !== 'undefined' && fs) || g.fs || g.L?.fs || null;
            if (!fsObj || typeof fsObj.exec !== 'function') {
              showToast(
                tr(
                  'Недоступно в демо-режиме — введите приватный ключ WARP вручную',
                  'Not available in demo mode — enter WARP private key manually',
                ),
                'error',
              );
              return;
            }
            isGeneratingWarp = true;
            rerender();
            fsObj
              .exec('/usr/bin/tachyon', ['generate_warp'])
              .then((res: any) => {
                isGeneratingWarp = false;
                if (res && res.code === 0 && res.stdout) {
                  const data = JSON.parse(String(res.stdout).trim());
                  applyGeneratedWarpPayload(data);
                  showToast(
                    tr(
                      'Ключи Cloudflare WARP успешно зарегистрированы!',
                      'Cloudflare WARP keys registered!',
                    ),
                    'success',
                  );
                } else {
                  const errMsg =
                    res?.stderr || res?.stdout || 'Cloudflare API unreachable';
                  showToast(
                    `${tr('Ошибка генерации WARP', 'WARP Generation Error')}: ${String(errMsg).slice(0, 120)}`,
                    'error',
                  );
                }
                rerender();
              })
              .catch((err: any) => {
                isGeneratingWarp = false;
                showToast(
                  `${tr('Ошибка генерации WARP', 'WARP Generation Error')}: ${err?.message || err}`,
                  'error',
                );
                rerender();
              });
          },
        } as any,
        isGeneratingWarp
          ? [
              E(
                'span',
                {},
                tr(
                  'Регистрация аккаунта Cloudflare WARP...',
                  'Registering Cloudflare WARP account...',
                ),
              ),
            ]
          : [
              renderZapIcon(14),
              E(
                'span',
                {},
                tr(
                  'Сгенерировать ключи Cloudflare WARP в 1 клик',
                  'Auto-generate Cloudflare WARP keys in 1 click',
                ),
              ),
            ],
      );

      formFields.push(
        E('div', { class: 'tachyon-wizard__field' }, [genBtn]),
        E('div', { class: 'tachyon-wizard__row-2col' }, [
          E('div', { class: 'tachyon-wizard__field' }, [
            E(
              'label',
              { class: 'tachyon-wizard__label' },
              tr(
                'Приватный ключ клиента (Private Key)',
                'Client Private Key (Base64)',
              ),
            ),
            E('input', {
              type: 'text',
              class: 'cbi-input-text tachyon-wizard__input',
              placeholder: tr(
                'Оставьте пустым для автогенерации при старте или нажмите кнопку выше',
                'Leave blank to auto-generate on start or click button above',
              ),
              value: warpPrivateKey,
              input: (ev: Event) => {
                warpPrivateKey = (ev.target as HTMLInputElement).value;
              },
            } as any),
          ]),
          E('div', { class: 'tachyon-wizard__field' }, [
            E(
              'label',
              { class: 'tachyon-wizard__label' },
              tr(
                'Публичный ключ пира Cloudflare (Peer Public Key)',
                'Cloudflare Peer Public Key',
              ),
            ),
            E('input', {
              type: 'text',
              class: 'cbi-input-text tachyon-wizard__input',
              value: warpPeerPublicKey,
              input: (ev: Event) => {
                warpPeerPublicKey = (ev.target as HTMLInputElement).value;
              },
            } as any),
          ]),
        ]),
        E('div', { class: 'tachyon-wizard__row-2col' }, [
          E('div', { class: 'tachyon-wizard__field' }, [
            E(
              'label',
              { class: 'tachyon-wizard__label' },
              tr('Адрес эндпоинта WARP', 'WARP Endpoint Host'),
            ),
            E('input', {
              type: 'text',
              class: 'cbi-input-text tachyon-wizard__input',
              placeholder: 'engage.cloudflareclient.com',
              value: warpServer,
              input: (ev: Event) => {
                warpServer = (ev.target as HTMLInputElement).value;
              },
            } as any),
          ]),
          E('div', { class: 'tachyon-wizard__field' }, [
            E(
              'label',
              { class: 'tachyon-wizard__label' },
              tr('Порт эндпоинта (UDP)', 'Endpoint UDP Port'),
            ),
            E('input', {
              type: 'number',
              class: 'cbi-input-text tachyon-wizard__input',
              placeholder: '2408',
              value: warpServerPort,
              input: (ev: Event) => {
                warpServerPort = (ev.target as HTMLInputElement).value;
              },
            } as any),
          ]),
        ]),
        E('div', { class: 'tachyon-wizard__row-2col' }, [
          E('div', { class: 'tachyon-wizard__field' }, [
            E(
              'label',
              { class: 'tachyon-wizard__label' },
              tr('Локальный IPv4 адрес туннеля', 'Local Tunnel IPv4 CIDR'),
            ),
            E('input', {
              type: 'text',
              class: 'cbi-input-text tachyon-wizard__input',
              placeholder: '172.16.0.2/32',
              value: warpLocalAddress,
              input: (ev: Event) => {
                warpLocalAddress = (ev.target as HTMLInputElement).value;
              },
            } as any),
          ]),
          E('div', { class: 'tachyon-wizard__field' }, [
            E(
              'label',
              { class: 'tachyon-wizard__label' },
              tr('Обфускация AWG Fake Packets / MTU', 'AWG Fake Packets / MTU'),
            ),
            E('div', { class: 'tachyon-wizard__row-2col' }, [
              E('input', {
                type: 'text',
                class: 'cbi-input-text tachyon-wizard__input',
                placeholder: '5-10',
                title: 'warp_fake_packets',
                value: warpFakePackets,
                input: (ev: Event) => {
                  warpFakePackets = (ev.target as HTMLInputElement).value;
                },
              } as any),
              E('input', {
                type: 'number',
                class: 'cbi-input-text tachyon-wizard__input',
                placeholder: '1280',
                title: 'MTU',
                value: warpMtu,
                input: (ev: Event) => {
                  warpMtu = (ev.target as HTMLInputElement).value;
                },
              } as any),
            ]),
          ]),
        ]),
      );
    } else if (outboundMethod === 'desync') {
      const dpiEngines: Array<{
        id: 'desync' | 'zapret2' | 'zapret' | 'byedpi';
        label: string;
      }> = [
        {
          id: 'desync',
          label: tr(
            'Tachyon Core Desync (встроенный нативный движок)',
            'Tachyon Core Desync (Built-in Native Engine)',
          ),
        },
        {
          id: 'zapret2',
          label: tr(
            'Zapret2 (nfqws2 — Lua-стратегии и NFQUEUE)',
            'Zapret2 (nfqws2 — Lua strategies & NFQUEUE)',
          ),
        },
        {
          id: 'zapret',
          label: tr(
            'Zapret (nfqws — классический NFQUEUE)',
            'Zapret (nfqws — classic NFQUEUE)',
          ),
        },
        {
          id: 'byedpi',
          label: tr(
            'ByeDPI (ciadpi — локальный SOCKS5 десинхронизатор)',
            'ByeDPI (ciadpi — local SOCKS5 desync)',
          ),
        },
      ];

      formFields.push(
        E('div', { class: 'tachyon-wizard__field' }, [
          E(
            'label',
            { class: 'tachyon-wizard__label' },
            tr('Движок обхода DPI', 'DPI Bypass Engine'),
          ),
          E(
            'select',
            {
              class: 'cbi-input-select tachyon-wizard__select',
              change: (ev: Event) => {
                dpiEngineType = (ev.target as HTMLSelectElement).value as any;
                rerender();
              },
            } as any,
            dpiEngines.map((eng) =>
              E(
                'option',
                {
                  value: eng.id,
                  selected: eng.id === dpiEngineType ? true : undefined,
                },
                eng.label,
              ),
            ),
          ),
        ]),
      );

      if (dpiEngineType === 'desync') {
        const presetOptions = [
          {
            id: 'fake_split',
            label: tr(
              'Fake + Split по SNI (рекомендуется для большинства ТСПУ)',
              'Fake + Split at SNI (recommended for most ISPs)',
            ),
          },
          {
            id: 'tlsrec',
            label: tr(
              'TLS Record Split (разбиение TLS-записи до SNI без fake)',
              'TLS Record Split before SNI (clean, no fake packets)',
            ),
          },
          {
            id: 'disorder',
            label: tr(
              'Disorder (отправка сегментов в обратном порядке с фейком)',
              'Disorder (out-of-order TCP segments with fake)',
            ),
          },
          {
            id: 'split',
            label: tr(
              'TCP Split по SNI (чистая фрагментация без фейков)',
              'TCP Split at SNI (pure segmentation without fake)',
            ),
          },
          {
            id: 'fake',
            label: tr(
              'Fake ClientHello с малым TTL',
              'Fake ClientHello with low TTL',
            ),
          },
          {
            id: 'oob',
            label: tr(
              'TCP Out-of-Band (URG-байт посреди SNI)',
              'TCP Out-of-Band (URG byte at SNI)',
            ),
          },
          {
            id: 'auto',
            label: tr(
              'Auto — каскадный перебор стратегий',
              'Auto — automatic strategy fallback',
            ),
          },
          {
            id: 'custom',
            label: tr(
              'Ручная настройка параметров (Custom)',
              'Custom parameters (Manual)',
            ),
          },
        ];
        formFields.push(
          E('div', { class: 'tachyon-wizard__field' }, [
            E(
              'label',
              { class: 'tachyon-wizard__label' },
              tr('Пресет десинхронизации', 'Desync Preset'),
            ),
            E(
              'select',
              {
                class: 'cbi-input-select tachyon-wizard__select',
                change: (ev: Event) => {
                  desyncPresetKey = (ev.target as HTMLSelectElement).value;
                  rerender();
                },
              } as any,
              presetOptions.map((po) =>
                E(
                  'option',
                  {
                    value: po.id,
                    selected: po.id === desyncPresetKey ? true : undefined,
                  },
                  po.label,
                ),
              ),
            ),
          ]),
        );
        if (desyncPresetKey === 'custom' || desyncPresetKey === 'auto') {
          if (desyncPresetKey === 'custom') {
            formFields.push(
              E('div', { class: 'tachyon-wizard__row-2col' }, [
                E('div', { class: 'tachyon-wizard__field' }, [
                  E(
                    'label',
                    { class: 'tachyon-wizard__label' },
                    tr('Базовый режим (Mode)', 'Desync Mode'),
                  ),
                  E(
                    'select',
                    {
                      class: 'cbi-input-select tachyon-wizard__select',
                      change: (ev: Event) => {
                        desyncMode = (ev.target as HTMLSelectElement).value;
                      },
                    } as any,
                    [
                      ['fake_split', 'Fake + Split'],
                      ['tlsrec', 'TLS Record Split'],
                      ['disorder', 'Disorder'],
                      ['split', 'TCP Split'],
                      ['fake', 'Fake Only'],
                      ['oob', 'Out-of-Band (URG)'],
                    ].map(([val, lbl]) =>
                      E(
                        'option',
                        {
                          value: val,
                          selected: val === desyncMode ? true : undefined,
                        },
                        lbl,
                      ),
                    ),
                  ),
                ]),
                E('div', { class: 'tachyon-wizard__field' }, [
                  E(
                    'label',
                    { class: 'tachyon-wizard__label' },
                    tr('Позиция разбиения (Split Pos)', 'Split Position'),
                  ),
                  E(
                    'select',
                    {
                      class: 'cbi-input-select tachyon-wizard__select',
                      change: (ev: Event) => {
                        desyncSplitPos = (ev.target as HTMLSelectElement).value;
                      },
                    } as any,
                    [
                      ['sni', 'SNI (середина домена)'],
                      ['1', 'Байт 1'],
                      ['2', 'Байт 2'],
                      ['3', 'Байт 3'],
                    ].map(([val, lbl]) =>
                      E(
                        'option',
                        {
                          value: val,
                          selected: val === desyncSplitPos ? true : undefined,
                        },
                        lbl,
                      ),
                    ),
                  ),
                ]),
              ]),
            );
          }
          const whitelistSniOptions = [
            [
              '',
              tr(
                'Авто (клонировать SNI / www.google.com)',
                'Auto (clone SNI / www.google.com)',
              ),
            ],
            ['ya.ru', 'ya.ru (Яндекс — Белый список РФ)'],
            ['vk.com', 'vk.com (ВКонтакте — Белый список РФ)'],
            ['max.ru', 'max.ru (MAX — Белый список РФ)'],
            ['gosuslugi.ru', 'gosuslugi.ru (Госуслуги — Белый список РФ)'],
            ['sberbank.ru', 'sberbank.ru (Сбербанк — Белый список РФ)'],
            ['tbank.ru', 'tbank.ru (Т-Банк — Белый список РФ)'],
            ['ozon.ru', 'ozon.ru (Ozon — Белый список РФ)'],
            [
              'wildberries.ru',
              'wildberries.ru (Wildberries — Белый список РФ)',
            ],
            ['rutube.ru', 'rutube.ru (Rutube — Белый список РФ)'],
            ['dzen.ru', 'dzen.ru (Дзен — Белый список РФ)'],
            ['avito.ru', 'avito.ru (Авито — Белый список РФ)'],
            ['rzd.ru', 'rzd.ru (РЖД — Белый список РФ)'],
            ['pochta.ru', 'pochta.ru (Почта России — Белый список РФ)'],
            ['2gis.ru', '2gis.ru (2ГИС — Белый список РФ)'],
            ['mail.ru', 'mail.ru (Mail.ru — Белый список РФ)'],
            ['www.google.com', 'www.google.com (Google Global)'],
          ];
          formFields.push(
            E('div', { class: 'tachyon-wizard__row-2col' }, [
              E('div', { class: 'tachyon-wizard__field' }, [
                E(
                  'label',
                  { class: 'tachyon-wizard__label' },
                  tr('Fake TTL (1–64, пусто = авто)', 'Fake Packet TTL'),
                ),
                E('input', {
                  type: 'number',
                  class: 'cbi-input-text tachyon-wizard__input',
                  placeholder: '4',
                  value: desyncFakeTtl,
                  input: (ev: Event) => {
                    desyncFakeTtl = (ev.target as HTMLInputElement).value;
                  },
                } as any),
              ]),
              E('div', { class: 'tachyon-wizard__field' }, [
                E(
                  'label',
                  { class: 'tachyon-wizard__label' },
                  tr(
                    'Fake SNI домен (Белый список РФ)',
                    'Fake SNI Domain (Whitelist)',
                  ),
                ),
                E(
                  'select',
                  {
                    class: 'cbi-input-select tachyon-wizard__select',
                    style: 'margin-bottom: 6px;',
                    change: (ev: Event) => {
                      desyncFakeSni = (ev.target as HTMLSelectElement).value;
                      rerender();
                    },
                  } as any,
                  whitelistSniOptions.map(([val, lbl]) =>
                    E(
                      'option',
                      {
                        value: val,
                        selected: val === desyncFakeSni ? true : undefined,
                      },
                      lbl,
                    ),
                  ),
                ),
                E('input', {
                  type: 'text',
                  class: 'cbi-input-text tachyon-wizard__input',
                  placeholder: 'ya.ru, vk.com, max.ru...',
                  value: desyncFakeSni,
                  input: (ev: Event) => {
                    desyncFakeSni = (ev.target as HTMLInputElement).value;
                  },
                } as any),
              ]),
            ]),
            E('div', { class: 'tachyon-wizard__field' }, [
              E(
                'label',
                { class: 'tachyon-wizard__label' },
                tr(
                  'Дополнительная CLI-строка (необязательно)',
                  'Extra CLI Strategy String (optional)',
                ),
              ),
              E('input', {
                type: 'text',
                class: 'cbi-input-text tachyon-wizard__input',
                value: desyncPreset,
                input: (ev: Event) => {
                  desyncPreset = (ev.target as HTMLInputElement).value;
                },
              } as any),
            ]),
          );
        }
      } else if (dpiEngineType === 'zapret2') {
        formFields.push(
          E('div', { class: 'tachyon-wizard__field' }, [
            E(
              'label',
              { class: 'tachyon-wizard__label' },
              tr(
                'Стратегия Zapret2 (аргументы nfqws2 / Lua)',
                'Zapret2 Strategy (nfqws2 / Lua arguments)',
              ),
            ),
            E(
              'textarea',
              {
                class: 'cbi-input-textarea tachyon-wizard__textarea',
                rows: 4,
                input: (ev: Event) => {
                  nfqws2Opt = (ev.target as HTMLTextAreaElement).value;
                },
              } as any,
              nfqws2Opt,
            ),
          ]),
          E('label', { class: 'tachyon-wizard__toggle-row' }, [
            E('input', {
              type: 'checkbox',
              checked: directNfqws ? true : undefined,
              change: (ev: Event) => {
                directNfqws = (ev.target as HTMLInputElement).checked;
              },
            } as any),
            E(
              'span',
              {},
              tr(
                'Прямой запуск бинарника nfqws2 (изолированный per-section инстанс без /etc/init.d/zapret2)',
                'Direct nfqws2 binary launch (isolated per-section instance)',
              ),
            ),
          ]),
        );
      } else if (dpiEngineType === 'zapret') {
        formFields.push(
          E('div', { class: 'tachyon-wizard__field' }, [
            E(
              'label',
              { class: 'tachyon-wizard__label' },
              tr(
                'Стратегия Zapret (аргументы nfqws)',
                'Zapret Strategy (nfqws arguments)',
              ),
            ),
            E(
              'textarea',
              {
                class: 'cbi-input-textarea tachyon-wizard__textarea',
                rows: 4,
                input: (ev: Event) => {
                  nfqwsOpt = (ev.target as HTMLTextAreaElement).value;
                },
              } as any,
              nfqwsOpt,
            ),
          ]),
          E('label', { class: 'tachyon-wizard__toggle-row' }, [
            E('input', {
              type: 'checkbox',
              checked: directNfqws ? true : undefined,
              change: (ev: Event) => {
                directNfqws = (ev.target as HTMLInputElement).checked;
              },
            } as any),
            E(
              'span',
              {},
              tr(
                'Прямой запуск бинарника nfqws (изолированный инстанс)',
                'Direct nfqws binary launch (isolated instance)',
              ),
            ),
          ]),
        );
      } else if (dpiEngineType === 'byedpi') {
        formFields.push(
          E('div', { class: 'tachyon-wizard__field' }, [
            E(
              'label',
              { class: 'tachyon-wizard__label' },
              tr(
                'Аргументы командной строки ByeDPI (ciadpi)',
                'ByeDPI (ciadpi) Command Arguments',
              ),
            ),
            E('input', {
              type: 'text',
              class: 'cbi-input-text tachyon-wizard__input',
              placeholder: '-o 2 --auto=t,r,a,s -d 2',
              value: byedpiCmdOpts,
              input: (ev: Event) => {
                byedpiCmdOpts = (ev.target as HTMLInputElement).value;
              },
            } as any),
          ]),
        );
      }
    } else if (outboundMethod === 'fptn') {
      formFields.push(
        E('div', { class: 'tachyon-wizard__field' }, [
          E(
            'label',
            { class: 'tachyon-wizard__label' },
            tr(
              'Токен доступа FPTN (fptn:// или fptnb://)',
              'FPTN Access Token (fptn:// or fptnb://)',
            ),
          ),
          E('input', {
            type: 'text',
            class: 'cbi-input-text tachyon-wizard__input',
            placeholder: 'fptn://...',
            value: fptnToken,
            input: (ev: Event) => {
              fptnToken = (ev.target as HTMLInputElement).value;
            },
          } as any),
        ]),
        E('div', { class: 'tachyon-wizard__row-2col' }, [
          E('div', { class: 'tachyon-wizard__field' }, [
            E(
              'label',
              { class: 'tachyon-wizard__label' },
              tr('Метод обхода цензуры', 'Censorship Bypass Method'),
            ),
            E(
              'select',
              {
                class: 'cbi-input-select tachyon-wizard__select',
                change: (ev: Event) => {
                  fptnBypassMethod = (ev.target as HTMLSelectElement).value;
                },
              } as any,
              [
                ['obfuscation', 'TLS Obfuscation (рекомендуется)'],
                ['split', 'Packet Split'],
                ['auto-sni', 'Auto-SNI'],
                ['reality', 'Reality Mode'],
                ['plain', 'Plain TLS'],
              ].map(([val, lbl]) =>
                E(
                  'option',
                  {
                    value: val,
                    selected: val === fptnBypassMethod ? true : undefined,
                  },
                  lbl,
                ),
              ),
            ),
          ]),
          E('div', { class: 'tachyon-wizard__field' }, [
            E(
              'label',
              { class: 'tachyon-wizard__label' },
              tr(
                'Домен маскировки SNI (необязательно)',
                'Camouflage SNI Domain (optional)',
              ),
            ),
            E('input', {
              type: 'text',
              class: 'cbi-input-text tachyon-wizard__input',
              placeholder: 'www.google.com',
              value: fptnSni,
              input: (ev: Event) => {
                fptnSni = (ev.target as HTMLInputElement).value;
              },
            } as any),
          ]),
        ]),
        E('div', { class: 'tachyon-wizard__field' }, [
          E(
            'label',
            { class: 'tachyon-wizard__label' },
            tr(
              'Предпочитаемый сервер FPTN (необязательно)',
              'Preferred FPTN Server Host/IP (optional)',
            ),
          ),
          E('input', {
            type: 'text',
            class: 'cbi-input-text tachyon-wizard__input',
            placeholder: tr(
              'Автовыбор самого быстрого узла из токена',
              'Auto-select fastest node from token',
            ),
            value: fptnPreferredServer,
            input: (ev: Event) => {
              fptnPreferredServer = (ev.target as HTMLInputElement).value;
            },
          } as any),
        ]),
      );
    } else if (outboundMethod === 'custom_proto') {
      formFields.push(
        E('div', { class: 'tachyon-wizard__field' }, [
          E(
            'label',
            { class: 'tachyon-wizard__label' },
            tr('Протокол или источник', 'Protocol or Source'),
          ),
          E(
            'select',
            {
              class: 'cbi-input-select tachyon-wizard__select',
              change: (ev: Event) => {
                customProto = (ev.target as HTMLSelectElement).value;
                const found = CUSTOM_PROTO_LIST.find(
                  (p) => p.id === customProto,
                );
                if (found?.defaultPort) {
                  customPort = found.defaultPort;
                }
                if (
                  customProto === 'tailscale' &&
                  (!customInterface || customInterface === 'wg0')
                ) {
                  customInterface = 'tailscale0';
                } else if (
                  customProto === 'interface' &&
                  customInterface === 'tailscale0'
                ) {
                  customInterface = 'wg0';
                }
                rerender();
              },
            } as any,
            CUSTOM_PROTO_LIST.map((p) =>
              E(
                'option',
                {
                  value: p.id,
                  selected: p.id === customProto ? true : undefined,
                },
                p.label,
              ),
            ),
          ),
        ]),
      );

      const renderHostPortRow = (
        hostLabel = tr(
          'Адрес сервера (Host / IP)',
          'Server Address (Host / IP)',
        ),
        portLabel = tr('Порт', 'Port'),
        portPlaceholder = '443',
      ) =>
        E('div', { class: 'tachyon-wizard__row-2col' }, [
          E('div', { class: 'tachyon-wizard__field' }, [
            E('label', { class: 'tachyon-wizard__label' }, hostLabel),
            E('input', {
              type: 'text',
              class: 'cbi-input-text tachyon-wizard__input',
              placeholder: 'vpn.example.com',
              value: customHost,
              input: (ev: Event) => {
                customHost = (ev.target as HTMLInputElement).value;
              },
            } as any),
          ]),
          E('div', { class: 'tachyon-wizard__field' }, [
            E('label', { class: 'tachyon-wizard__label' }, portLabel),
            E('input', {
              type: 'text',
              class: 'cbi-input-text tachyon-wizard__input',
              placeholder: portPlaceholder,
              value: customPort,
              input: (ev: Event) => {
                customPort = (ev.target as HTMLInputElement).value;
              },
            } as any),
          ]),
        ]);

      if (customProto === 'anytls') {
        formFields.push(
          renderHostPortRow(),
          E('div', { class: 'tachyon-wizard__row-2col' }, [
            E('div', { class: 'tachyon-wizard__field' }, [
              E(
                'label',
                { class: 'tachyon-wizard__label' },
                tr('Пароль AnyTLS', 'AnyTLS Password'),
              ),
              E('input', {
                type: 'text',
                class: 'cbi-input-text tachyon-wizard__input',
                value: customPassword,
                input: (ev: Event) => {
                  customPassword = (ev.target as HTMLInputElement).value;
                },
              } as any),
            ]),
            E('div', { class: 'tachyon-wizard__field' }, [
              E(
                'label',
                { class: 'tachyon-wizard__label' },
                tr('Домен TLS SNI', 'TLS SNI Domain'),
              ),
              E('input', {
                type: 'text',
                class: 'cbi-input-text tachyon-wizard__input',
                placeholder: 'example.com',
                value: customSni,
                input: (ev: Event) => {
                  customSni = (ev.target as HTMLInputElement).value;
                },
              } as any),
            ]),
          ]),
          E('div', { class: 'tachyon-wizard__row-2col' }, [
            E('div', { class: 'tachyon-wizard__field' }, [
              E(
                'label',
                { class: 'tachyon-wizard__label' },
                tr(
                  'ALPN-протоколы (через запятую)',
                  'ALPN Protocols (comma-separated)',
                ),
              ),
              E('input', {
                type: 'text',
                class: 'cbi-input-text tachyon-wizard__input',
                placeholder: 'h2, http/1.1',
                value: anytlsAlpn,
                input: (ev: Event) => {
                  anytlsAlpn = (ev.target as HTMLInputElement).value;
                },
              } as any),
            ]),
            E('div', { class: 'tachyon-wizard__field' }, [
              E(
                'label',
                { class: 'tachyon-wizard__label' },
                tr(
                  'Мин. пул idle-сессий / Таймаут',
                  'Min Idle Sessions / Timeout',
                ),
              ),
              E('div', { class: 'tachyon-wizard__row-2col' }, [
                E('input', {
                  type: 'number',
                  class: 'cbi-input-text tachyon-wizard__input',
                  placeholder: '5',
                  title: 'min_idle_session',
                  value: anytlsMinIdle,
                  input: (ev: Event) => {
                    anytlsMinIdle = (ev.target as HTMLInputElement).value;
                  },
                } as any),
                E('input', {
                  type: 'text',
                  class: 'cbi-input-text tachyon-wizard__input',
                  placeholder: '30s',
                  title: 'idle_session_timeout',
                  value: anytlsIdleTimeout,
                  input: (ev: Event) => {
                    anytlsIdleTimeout = (ev.target as HTMLInputElement).value;
                  },
                } as any),
              ]),
            ]),
          ]),
          E('label', { class: 'tachyon-wizard__toggle-row' }, [
            E('input', {
              type: 'checkbox',
              checked: customInsecure ? true : undefined,
              change: (ev: Event) => {
                customInsecure = (ev.target as HTMLInputElement).checked;
              },
            } as any),
            E(
              'span',
              {},
              tr(
                'Пропускать проверку TLS-сертификата (Allow Insecure)',
                'Skip TLS certificate verification (Allow Insecure)',
              ),
            ),
          ]),
        );
      } else if (customProto === 'naive') {
        formFields.push(
          renderHostPortRow(),
          E('div', { class: 'tachyon-wizard__row-2col' }, [
            E('div', { class: 'tachyon-wizard__field' }, [
              E(
                'label',
                { class: 'tachyon-wizard__label' },
                tr('Имя пользователя (Username)', 'Username'),
              ),
              E('input', {
                type: 'text',
                class: 'cbi-input-text tachyon-wizard__input',
                value: customUsername,
                input: (ev: Event) => {
                  customUsername = (ev.target as HTMLInputElement).value;
                },
              } as any),
            ]),
            E('div', { class: 'tachyon-wizard__field' }, [
              E(
                'label',
                { class: 'tachyon-wizard__label' },
                tr('Пароль (Password)', 'Password'),
              ),
              E('input', {
                type: 'text',
                class: 'cbi-input-text tachyon-wizard__input',
                value: customPassword,
                input: (ev: Event) => {
                  customPassword = (ev.target as HTMLInputElement).value;
                },
              } as any),
            ]),
          ]),
          E('div', { class: 'tachyon-wizard__row-2col' }, [
            E('div', { class: 'tachyon-wizard__field' }, [
              E(
                'label',
                { class: 'tachyon-wizard__label' },
                tr('Домен TLS SNI', 'TLS SNI Domain'),
              ),
              E('input', {
                type: 'text',
                class: 'cbi-input-text tachyon-wizard__input',
                placeholder: 'example.com',
                value: customSni,
                input: (ev: Event) => {
                  customSni = (ev.target as HTMLInputElement).value;
                },
              } as any),
            ]),
            E('div', { class: 'tachyon-wizard__field' }, [
              E(
                'label',
                { class: 'tachyon-wizard__label' },
                tr(
                  'Алгоритм QUIC Congestion Control & Потоки',
                  'QUIC Congestion Control & Concurrency',
                ),
              ),
              E('div', { class: 'tachyon-wizard__row-2col' }, [
                E(
                  'select',
                  {
                    class: 'cbi-input-select tachyon-wizard__select',
                    change: (ev: Event) => {
                      naiveCongestion = (ev.target as HTMLSelectElement).value;
                    },
                  } as any,
                  [
                    ['bbr', 'BBR'],
                    ['bbr2', 'BBRv2'],
                    ['cubic', 'CUBIC'],
                    ['reno', 'Reno'],
                  ].map(([val, lbl]) =>
                    E(
                      'option',
                      {
                        value: val,
                        selected: val === naiveCongestion ? true : undefined,
                      },
                      lbl,
                    ),
                  ),
                ),
                E('input', {
                  type: 'number',
                  class: 'cbi-input-text tachyon-wizard__input',
                  placeholder: '1',
                  title: 'insecure_concurrency',
                  value: naiveConcurrency,
                  input: (ev: Event) => {
                    naiveConcurrency = (ev.target as HTMLInputElement).value;
                  },
                } as any),
              ]),
            ]),
          ]),
          E('label', { class: 'tachyon-wizard__toggle-row' }, [
            E('input', {
              type: 'checkbox',
              checked: naiveQuic ? true : undefined,
              change: (ev: Event) => {
                naiveQuic = (ev.target as HTMLInputElement).checked;
              },
            } as any),
            E(
              'span',
              {},
              tr(
                'Использовать HTTP/3 QUIC вместо HTTP/2 TLS',
                'Use HTTP/3 QUIC transport instead of HTTP/2 TLS',
              ),
            ),
          ]),
          E('label', { class: 'tachyon-wizard__toggle-row' }, [
            E('input', {
              type: 'checkbox',
              checked: naiveUot ? true : undefined,
              change: (ev: Event) => {
                naiveUot = (ev.target as HTMLInputElement).checked;
              },
            } as any),
            E(
              'span',
              {},
              tr('Включить UDP over TCP (UoT)', 'Enable UDP over TCP (UoT)'),
            ),
          ]),
        );
      } else if (customProto === 'mieru') {
        formFields.push(
          renderHostPortRow(
            tr('Адрес сервера Mieru', 'Mieru Server Address'),
            tr('Порт или диапазон (напр. 2012-2022)', 'Port or Range'),
          ),
          E('div', { class: 'tachyon-wizard__row-2col' }, [
            E('div', { class: 'tachyon-wizard__field' }, [
              E(
                'label',
                { class: 'tachyon-wizard__label' },
                tr('Имя пользователя (Username)', 'Username'),
              ),
              E('input', {
                type: 'text',
                class: 'cbi-input-text tachyon-wizard__input',
                value: customUsername,
                input: (ev: Event) => {
                  customUsername = (ev.target as HTMLInputElement).value;
                },
              } as any),
            ]),
            E('div', { class: 'tachyon-wizard__field' }, [
              E(
                'label',
                { class: 'tachyon-wizard__label' },
                tr('Пароль (Password)', 'Password'),
              ),
              E('input', {
                type: 'text',
                class: 'cbi-input-text tachyon-wizard__input',
                value: customPassword,
                input: (ev: Event) => {
                  customPassword = (ev.target as HTMLInputElement).value;
                },
              } as any),
            ]),
          ]),
          E('div', { class: 'tachyon-wizard__row-2col' }, [
            E('div', { class: 'tachyon-wizard__field' }, [
              E(
                'label',
                { class: 'tachyon-wizard__label' },
                tr('Транспорт (TCP / UDP)', 'Transport Protocol'),
              ),
              E(
                'select',
                {
                  class: 'cbi-input-select tachyon-wizard__select',
                  change: (ev: Event) => {
                    mieruTransport = (ev.target as HTMLSelectElement)
                      .value as any;
                  },
                } as any,
                ['TCP', 'UDP'].map((t) =>
                  E(
                    'option',
                    {
                      value: t,
                      selected: t === mieruTransport ? true : undefined,
                    },
                    t,
                  ),
                ),
              ),
            ]),
            E('div', { class: 'tachyon-wizard__field' }, [
              E(
                'label',
                { class: 'tachyon-wizard__label' },
                tr(
                  'Уровень мультиплексирования и Handshake',
                  'Multiplexing & Handshake Mode',
                ),
              ),
              E('div', { class: 'tachyon-wizard__row-2col' }, [
                E(
                  'select',
                  {
                    class: 'cbi-input-select tachyon-wizard__select',
                    change: (ev: Event) => {
                      mieruMultiplexing = (ev.target as HTMLSelectElement)
                        .value;
                    },
                  } as any,
                  [
                    ['MULTIPLEXING_HIGH', 'High Mux'],
                    ['MULTIPLEXING_MIDDLE', 'Middle Mux'],
                    ['MULTIPLEXING_LOW', 'Low Mux'],
                    ['MULTIPLEXING_OFF', 'Mux Off'],
                  ].map(([val, lbl]) =>
                    E(
                      'option',
                      {
                        value: val,
                        selected: val === mieruMultiplexing ? true : undefined,
                      },
                      lbl,
                    ),
                  ),
                ),
                E(
                  'select',
                  {
                    class: 'cbi-input-select tachyon-wizard__select',
                    change: (ev: Event) => {
                      mieruHandshake = (ev.target as HTMLSelectElement).value;
                    },
                  } as any,
                  [
                    ['HANDSHAKE_STANDARD', 'Standard'],
                    ['HANDSHAKE_NO_WAIT', '0-RTT No-Wait'],
                  ].map(([val, lbl]) =>
                    E(
                      'option',
                      {
                        value: val,
                        selected: val === mieruHandshake ? true : undefined,
                      },
                      lbl,
                    ),
                  ),
                ),
              ]),
            ]),
          ]),
        );
      } else if (customProto === 'snell') {
        formFields.push(
          renderHostPortRow(),
          E('div', { class: 'tachyon-wizard__row-2col' }, [
            E('div', { class: 'tachyon-wizard__field' }, [
              E(
                'label',
                { class: 'tachyon-wizard__label' },
                tr('Ключ Snell PSK (Pre-Shared Key)', 'Snell PSK'),
              ),
              E('input', {
                type: 'text',
                class: 'cbi-input-text tachyon-wizard__input',
                value: customPassword,
                input: (ev: Event) => {
                  customPassword = (ev.target as HTMLInputElement).value;
                },
              } as any),
            ]),
            E('div', { class: 'tachyon-wizard__field' }, [
              E(
                'label',
                { class: 'tachyon-wizard__label' },
                tr('Версия протокола Snell', 'Snell Protocol Version'),
              ),
              E(
                'select',
                {
                  class: 'cbi-input-select tachyon-wizard__select',
                  change: (ev: Event) => {
                    snellVersion = (ev.target as HTMLSelectElement).value;
                  },
                } as any,
                [
                  ['4', 'Snell v4 (рекомендуется)'],
                  ['3', 'Snell v3'],
                  ['2', 'Snell v2'],
                  ['1', 'Snell v1'],
                ].map(([val, lbl]) =>
                  E(
                    'option',
                    {
                      value: val,
                      selected: val === snellVersion ? true : undefined,
                    },
                    lbl,
                  ),
                ),
              ),
            ]),
          ]),
          E('div', { class: 'tachyon-wizard__row-2col' }, [
            E('div', { class: 'tachyon-wizard__field' }, [
              E(
                'label',
                { class: 'tachyon-wizard__label' },
                tr('Режим обфускации (Simple-Obfs)', 'Obfuscation Mode'),
              ),
              E(
                'select',
                {
                  class: 'cbi-input-select tachyon-wizard__select',
                  change: (ev: Event) => {
                    snellObfs = (ev.target as HTMLSelectElement).value;
                    rerender();
                  },
                } as any,
                [
                  ['tls', 'TLS Obfuscation'],
                  ['http', 'HTTP Obfuscation'],
                  ['', tr('Без обфускации (None)', 'None')],
                ].map(([val, lbl]) =>
                  E(
                    'option',
                    {
                      value: val,
                      selected: val === snellObfs ? true : undefined,
                    },
                    lbl,
                  ),
                ),
              ),
            ]),
            E('div', { class: 'tachyon-wizard__field' }, [
              E(
                'label',
                { class: 'tachyon-wizard__label' },
                tr('Хост обфускации (Obfs Host)', 'Obfs Host Domain'),
              ),
              E('input', {
                type: 'text',
                class: 'cbi-input-text tachyon-wizard__input',
                placeholder: 'www.bing.com',
                value: snellObfsHost,
                input: (ev: Event) => {
                  snellObfsHost = (ev.target as HTMLInputElement).value;
                },
              } as any),
            ]),
          ]),
          E('label', { class: 'tachyon-wizard__toggle-row' }, [
            E('input', {
              type: 'checkbox',
              checked: snellUot ? true : undefined,
              change: (ev: Event) => {
                snellUot = (ev.target as HTMLInputElement).checked;
              },
            } as any),
            E(
              'span',
              {},
              tr('Включить UDP over TCP (UoT)', 'Enable UDP over TCP (UoT)'),
            ),
          ]),
        );
      } else if (customProto === 'sudoku') {
        formFields.push(
          renderHostPortRow(),
          E('div', { class: 'tachyon-wizard__row-2col' }, [
            E('div', { class: 'tachyon-wizard__field' }, [
              E(
                'label',
                { class: 'tachyon-wizard__label' },
                tr('Ключ / Пароль Sudoku', 'Sudoku Key / Password'),
              ),
              E('input', {
                type: 'text',
                class: 'cbi-input-text tachyon-wizard__input',
                value: customPassword,
                input: (ev: Event) => {
                  customPassword = (ev.target as HTMLInputElement).value;
                },
              } as any),
            ]),
            E('div', { class: 'tachyon-wizard__field' }, [
              E(
                'label',
                { class: 'tachyon-wizard__label' },
                tr('Шифрование AEAD', 'AEAD Cipher'),
              ),
              E(
                'select',
                {
                  class: 'cbi-input-select tachyon-wizard__select',
                  change: (ev: Event) => {
                    sudokuAead = (ev.target as HTMLSelectElement).value;
                  },
                } as any,
                [
                  ['chacha20-poly1305', 'ChaCha20-Poly1305'],
                  ['aes-128-gcm', 'AES-128-GCM'],
                  ['none', 'None'],
                ].map(([val, lbl]) =>
                  E(
                    'option',
                    {
                      value: val,
                      selected: val === sudokuAead ? true : undefined,
                    },
                    lbl,
                  ),
                ),
              ),
            ]),
          ]),
          E('div', { class: 'tachyon-wizard__row-2col' }, [
            E('div', { class: 'tachyon-wizard__field' }, [
              E(
                'label',
                { class: 'tachyon-wizard__label' },
                tr('Полиморфный профиль энтропии', 'Polymorphic Entropy Mode'),
              ),
              E(
                'select',
                {
                  class: 'cbi-input-select tachyon-wizard__select',
                  change: (ev: Event) => {
                    sudokuAscii = (ev.target as HTMLSelectElement).value;
                  },
                } as any,
                [
                  ['prefer_entropy', 'Prefer Entropy (Balanced)'],
                  ['prefer_ascii', 'Prefer ASCII (Text-like)'],
                ].map(([val, lbl]) =>
                  E(
                    'option',
                    {
                      value: val,
                      selected: val === sudokuAscii ? true : undefined,
                    },
                    lbl,
                  ),
                ),
              ),
            ]),
            E('div', { class: 'tachyon-wizard__field' }, [
              E(
                'label',
                { class: 'tachyon-wizard__label' },
                tr('Домен HTTP-маскировки (HTTP Mask Host)', 'HTTP Mask Host'),
              ),
              E('input', {
                type: 'text',
                class: 'cbi-input-text tachyon-wizard__input',
                placeholder: 'www.cloudflare.com',
                value: sudokuMaskHost,
                input: (ev: Event) => {
                  sudokuMaskHost = (ev.target as HTMLInputElement).value;
                },
              } as any),
            ]),
          ]),
          E('label', { class: 'tachyon-wizard__toggle-row' }, [
            E('input', {
              type: 'checkbox',
              checked: sudokuHttpMask ? true : undefined,
              change: (ev: Event) => {
                sudokuHttpMask = (ev.target as HTMLInputElement).checked;
              },
            } as any),
            E(
              'span',
              {},
              tr(
                'Включить маскировку HTTP-заголовков (HTTP Mask)',
                'Enable HTTP Header Masking',
              ),
            ),
          ]),
        );
      } else if (customProto === 'masque') {
        formFields.push(
          renderHostPortRow(),
          E('div', { class: 'tachyon-wizard__row-2col' }, [
            E('div', { class: 'tachyon-wizard__field' }, [
              E(
                'label',
                { class: 'tachyon-wizard__label' },
                tr(
                  'Публичный ключ сервера MASQUE (Base64 ECDSA)',
                  'MASQUE Server Public Key (Base64)',
                ),
              ),
              E('input', {
                type: 'text',
                class: 'cbi-input-text tachyon-wizard__input',
                placeholder: 'Base64 ECDSA / Ed25519 key...',
                value: masquePublicKey,
                input: (ev: Event) => {
                  masquePublicKey = (ev.target as HTMLInputElement).value;
                },
              } as any),
            ]),
            E('div', { class: 'tachyon-wizard__field' }, [
              E(
                'label',
                { class: 'tachyon-wizard__label' },
                tr(
                  'Локальный IPv4 адрес туннеля / MTU',
                  'Local Tunnel IPv4 CIDR / MTU',
                ),
              ),
              E('div', { class: 'tachyon-wizard__row-2col' }, [
                E('input', {
                  type: 'text',
                  class: 'cbi-input-text tachyon-wizard__input',
                  placeholder: '172.16.0.2/32',
                  value: masqueLocalAddr,
                  input: (ev: Event) => {
                    masqueLocalAddr = (ev.target as HTMLInputElement).value;
                  },
                } as any),
                E('input', {
                  type: 'number',
                  class: 'cbi-input-text tachyon-wizard__input',
                  placeholder: '1280',
                  value: masqueMtu,
                  input: (ev: Event) => {
                    masqueMtu = (ev.target as HTMLInputElement).value;
                  },
                } as any),
              ]),
            ]),
          ]),
          E('div', { class: 'tachyon-wizard__row-2col' }, [
            E('div', { class: 'tachyon-wizard__field' }, [
              E(
                'label',
                { class: 'tachyon-wizard__label' },
                tr('Домен TLS SNI', 'TLS SNI Domain'),
              ),
              E('input', {
                type: 'text',
                class: 'cbi-input-text tachyon-wizard__input',
                placeholder: 'consumer-masque.cloudflareclient.com',
                value: customSni,
                input: (ev: Event) => {
                  customSni = (ev.target as HTMLInputElement).value;
                },
              } as any),
            ]),
            E('div', { class: 'tachyon-wizard__field' }, [
              E(
                'label',
                { class: 'tachyon-wizard__label' },
                tr('MASQUE URI шаблон (необязательно)', 'MASQUE URI Template'),
              ),
              E('input', {
                type: 'text',
                class: 'cbi-input-text tachyon-wizard__input',
                placeholder:
                  'https://example.com/.well-known/masque/udp/{target_host}/{target_port}/',
                value: masqueUri,
                input: (ev: Event) => {
                  masqueUri = (ev.target as HTMLInputElement).value;
                },
              } as any),
            ]),
          ]),
          E('label', { class: 'tachyon-wizard__toggle-row' }, [
            E('input', {
              type: 'checkbox',
              checked: masqueVhttp ? true : undefined,
              change: (ev: Event) => {
                masqueVhttp = (ev.target as HTMLInputElement).checked;
              },
            } as any),
            E(
              'span',
              {},
              tr(
                'Включить виртуальную обёртку HTTP/3 (vHTTP)',
                'Enable Virtual HTTP/3 Wrapper (vHTTP)',
              ),
            ),
          ]),
        );
      } else if (customProto === 'trusttunnel') {
        formFields.push(
          renderHostPortRow(
            tr('Эндпоинт TrustTunnel (Host / IP)', 'TrustTunnel Endpoint Host'),
            tr('Порт HTTPS / QUIC', 'HTTPS / QUIC Port'),
          ),
          E('div', { class: 'tachyon-wizard__row-2col' }, [
            E('div', { class: 'tachyon-wizard__field' }, [
              E(
                'label',
                { class: 'tachyon-wizard__label' },
                tr('Имя пользователя (Username)', 'Username'),
              ),
              E('input', {
                type: 'text',
                class: 'cbi-input-text tachyon-wizard__input',
                value: customUsername,
                input: (ev: Event) => {
                  customUsername = (ev.target as HTMLInputElement).value;
                },
              } as any),
            ]),
            E('div', { class: 'tachyon-wizard__field' }, [
              E(
                'label',
                { class: 'tachyon-wizard__label' },
                tr('Пароль (Password)', 'Password'),
              ),
              E('input', {
                type: 'text',
                class: 'cbi-input-text tachyon-wizard__input',
                value: customPassword,
                input: (ev: Event) => {
                  customPassword = (ev.target as HTMLInputElement).value;
                },
              } as any),
            ]),
          ]),
          E('div', { class: 'tachyon-wizard__field' }, [
            E(
              'label',
              { class: 'tachyon-wizard__label' },
              tr('Домен TLS SNI', 'TLS SNI Domain'),
            ),
            E('input', {
              type: 'text',
              class: 'cbi-input-text tachyon-wizard__input',
              placeholder: 'example.com',
              value: customSni,
              input: (ev: Event) => {
                customSni = (ev.target as HTMLInputElement).value;
              },
            } as any),
          ]),
          E('label', { class: 'tachyon-wizard__toggle-row' }, [
            E('input', {
              type: 'checkbox',
              checked: trusttunnelQuic ? true : undefined,
              change: (ev: Event) => {
                trusttunnelQuic = (ev.target as HTMLInputElement).checked;
              },
            } as any),
            E(
              'span',
              {},
              tr(
                'Использовать транспорт HTTP/3 QUIC вместо HTTP/2',
                'Use HTTP/3 QUIC transport instead of HTTP/2',
              ),
            ),
          ]),
          E('label', { class: 'tachyon-wizard__toggle-row' }, [
            E('input', {
              type: 'checkbox',
              checked: trusttunnelHealthCheck ? true : undefined,
              change: (ev: Event) => {
                trusttunnelHealthCheck = (ev.target as HTMLInputElement)
                  .checked;
              },
            } as any),
            E(
              'span',
              {},
              tr(
                'Фоновая проверка живучести сессии (Health Check)',
                'Background tunnel health check',
              ),
            ),
          ]),
        );
      } else if (customProto === 'tewfai') {
        formFields.push(
          renderHostPortRow(
            tr('Адрес сервера TewFai', 'TewFai Server Host'),
            tr('Порт', 'Port'),
            '8443',
          ),
          E('div', { class: 'tachyon-wizard__row-2col' }, [
            E('div', { class: 'tachyon-wizard__field' }, [
              E(
                'label',
                { class: 'tachyon-wizard__label' },
                tr('Идентификатор / UUID пользователя', 'User ID / UUID'),
              ),
              E('input', {
                type: 'text',
                class: 'cbi-input-text tachyon-wizard__input',
                value: customUsername,
                input: (ev: Event) => {
                  customUsername = (ev.target as HTMLInputElement).value;
                },
              } as any),
            ]),
            E('div', { class: 'tachyon-wizard__field' }, [
              E(
                'label',
                { class: 'tachyon-wizard__label' },
                tr('Ключ / Пароль TewFai (PSK)', 'TewFai Key / Password'),
              ),
              E('input', {
                type: 'text',
                class: 'cbi-input-text tachyon-wizard__input',
                value: customPassword,
                input: (ev: Event) => {
                  customPassword = (ev.target as HTMLInputElement).value;
                },
              } as any),
            ]),
          ]),
          E('div', { class: 'tachyon-wizard__row-2col' }, [
            E('div', { class: 'tachyon-wizard__field' }, [
              E(
                'label',
                { class: 'tachyon-wizard__label' },
                tr('Домен TLS SNI', 'TLS SNI Domain'),
              ),
              E('input', {
                type: 'text',
                class: 'cbi-input-text tachyon-wizard__input',
                placeholder: 'www.cloudflare.com',
                value: customSni,
                input: (ev: Event) => {
                  customSni = (ev.target as HTMLInputElement).value;
                },
              } as any),
            ]),
            E('div', { class: 'tachyon-wizard__field' }, [
              E(
                'label',
                { class: 'tachyon-wizard__label' },
                tr(
                  'Цепочка транспортов (multipath failover)',
                  'Transport Fallback Chain',
                ),
              ),
              E('input', {
                type: 'text',
                class: 'cbi-input-text tachyon-wizard__input',
                placeholder: 'quic, h3_datagram, h2, tcp',
                value: tewfaiTransports,
                input: (ev: Event) => {
                  tewfaiTransports = (ev.target as HTMLInputElement).value;
                },
              } as any),
            ]),
          ]),
          E('div', { class: 'tachyon-wizard__row-2col' }, [
            E('div', { class: 'tachyon-wizard__field' }, [
              E(
                'label',
                { class: 'tachyon-wizard__label' },
                tr('Постквантовый шифр (Inner PQC Cipher)', 'Inner PQC Cipher'),
              ),
              E(
                'select',
                {
                  class: 'cbi-input-select tachyon-wizard__select',
                  change: (ev: Event) => {
                    tewfaiInnerCipher = (ev.target as HTMLSelectElement).value;
                  },
                } as any,
                [
                  ['', 'Auto (ML-KEM-768 + ChaCha20-Poly1305)'],
                  ['aes-256-gcm', 'ML-KEM-768 + AES-256-GCM'],
                  ['none', 'None (Outer TLS Only)'],
                ].map(([val, lbl]) =>
                  E(
                    'option',
                    {
                      value: val,
                      selected: val === tewfaiInnerCipher ? true : undefined,
                    },
                    lbl,
                  ),
                ),
              ),
            ]),
            E('div', { class: 'tachyon-wizard__field' }, [
              E(
                'label',
                { class: 'tachyon-wizard__label' },
                tr(
                  'Профиль морфинга трафика (Traffic Shaper)',
                  'Traffic Morphing Profile',
                ),
              ),
              E(
                'select',
                {
                  class: 'cbi-input-select tachyon-wizard__select',
                  change: (ev: Event) => {
                    tewfaiMorphProfile = (ev.target as HTMLSelectElement).value;
                  },
                } as any,
                [
                  ['browsing', 'Web Browsing (HTTP/3 burst)'],
                  ['video', 'Video Streaming'],
                  ['webrtc', 'WebRTC Call'],
                  ['bulk', 'Bulk Transfer'],
                  ['', tr('Без шейпинга', 'Disabled')],
                ].map(([val, lbl]) =>
                  E(
                    'option',
                    {
                      value: val,
                      selected: val === tewfaiMorphProfile ? true : undefined,
                    },
                    lbl,
                  ),
                ),
              ),
            ]),
          ]),
        );
      } else if (customProto === 'shadowtls') {
        formFields.push(
          renderHostPortRow(),
          E('div', { class: 'tachyon-wizard__row-2col' }, [
            E('div', { class: 'tachyon-wizard__field' }, [
              E(
                'label',
                { class: 'tachyon-wizard__label' },
                tr('Пароль рукопожатия ShadowTLS', 'ShadowTLS Password'),
              ),
              E('input', {
                type: 'text',
                class: 'cbi-input-text tachyon-wizard__input',
                value: customPassword,
                input: (ev: Event) => {
                  customPassword = (ev.target as HTMLInputElement).value;
                },
              } as any),
            ]),
            E('div', { class: 'tachyon-wizard__field' }, [
              E(
                'label',
                { class: 'tachyon-wizard__label' },
                tr('Версия протокола ShadowTLS', 'ShadowTLS Version'),
              ),
              E(
                'select',
                {
                  class: 'cbi-input-select tachyon-wizard__select',
                  change: (ev: Event) => {
                    shadowtlsVersion = (ev.target as HTMLSelectElement).value;
                  },
                } as any,
                [
                  ['3', 'ShadowTLS v3 (рекомендуется)'],
                  ['2', 'ShadowTLS v2'],
                  ['1', 'ShadowTLS v1'],
                ].map(([val, lbl]) =>
                  E(
                    'option',
                    {
                      value: val,
                      selected: val === shadowtlsVersion ? true : undefined,
                    },
                    lbl,
                  ),
                ),
              ),
            ]),
          ]),
          E('div', { class: 'tachyon-wizard__field' }, [
            E(
              'label',
              { class: 'tachyon-wizard__label' },
              tr(
                'Домен маскировки TLS Handshake Server (SNI)',
                'TLS Handshake Camouflage Domain (SNI)',
              ),
            ),
            E('input', {
              type: 'text',
              class: 'cbi-input-text tachyon-wizard__input',
              placeholder: 'www.microsoft.com',
              value: customSni,
              input: (ev: Event) => {
                customSni = (ev.target as HTMLInputElement).value;
              },
            } as any),
          ]),
        );
      } else if (customProto === 'openconnect') {
        formFields.push(
          renderHostPortRow(
            tr('Адрес корпоративного VPN-шлюза', 'VPN Gateway Host / IP'),
            tr('Порт', 'Port'),
          ),
          E('div', { class: 'tachyon-wizard__row-2col' }, [
            E('div', { class: 'tachyon-wizard__field' }, [
              E(
                'label',
                { class: 'tachyon-wizard__label' },
                tr('Тип шлюза OpenConnect', 'OpenConnect Gateway Protocol'),
              ),
              E(
                'select',
                {
                  class: 'cbi-input-select tachyon-wizard__select',
                  change: (ev: Event) => {
                    openconnectProtocol = (ev.target as HTMLSelectElement)
                      .value;
                  },
                } as any,
                [
                  ['anyconnect', 'Cisco AnyConnect SSL / DTLS'],
                  ['gp', 'Palo Alto GlobalProtect'],
                  ['fortinet', 'Fortinet FortiGate SSL VPN'],
                  ['pulse', 'Ivanti / Pulse Connect Secure'],
                  ['nc', 'Juniper Network Connect'],
                  ['f5', 'F5 BIG-IP SSL VPN'],
                  ['array', 'Array Networks SSL VPN'],
                ].map(([val, lbl]) =>
                  E(
                    'option',
                    {
                      value: val,
                      selected: val === openconnectProtocol ? true : undefined,
                    },
                    lbl,
                  ),
                ),
              ),
            ]),
            E('div', { class: 'tachyon-wizard__field' }, [
              E(
                'label',
                { class: 'tachyon-wizard__label' },
                tr(
                  'Группа авторизации (Auth Group, необязательно)',
                  'Auth Group (optional)',
                ),
              ),
              E('input', {
                type: 'text',
                class: 'cbi-input-text tachyon-wizard__input',
                placeholder: 'Employees / Default',
                value: openconnectAuthgroup,
                input: (ev: Event) => {
                  openconnectAuthgroup = (ev.target as HTMLInputElement).value;
                },
              } as any),
            ]),
          ]),
          E('div', { class: 'tachyon-wizard__row-2col' }, [
            E('div', { class: 'tachyon-wizard__field' }, [
              E(
                'label',
                { class: 'tachyon-wizard__label' },
                tr('Имя пользователя (Username)', 'Username'),
              ),
              E('input', {
                type: 'text',
                class: 'cbi-input-text tachyon-wizard__input',
                value: customUsername,
                input: (ev: Event) => {
                  customUsername = (ev.target as HTMLInputElement).value;
                },
              } as any),
            ]),
            E('div', { class: 'tachyon-wizard__field' }, [
              E(
                'label',
                { class: 'tachyon-wizard__label' },
                tr('Пароль (Password)', 'Password'),
              ),
              E('input', {
                type: 'text',
                class: 'cbi-input-text tachyon-wizard__input',
                value: customPassword,
                input: (ev: Event) => {
                  customPassword = (ev.target as HTMLInputElement).value;
                },
              } as any),
            ]),
          ]),
          E('div', { class: 'tachyon-wizard__field' }, [
            E(
              'label',
              { class: 'tachyon-wizard__label' },
              tr(
                'Отпечаток сертификата сервера (pin-sha256:..., необязательно)',
                'Server Certificate Fingerprint (pin-sha256:..., optional)',
              ),
            ),
            E('input', {
              type: 'text',
              class: 'cbi-input-text tachyon-wizard__input',
              placeholder: 'pin-sha256:...',
              value: openconnectServercert,
              input: (ev: Event) => {
                openconnectServercert = (ev.target as HTMLInputElement).value;
              },
            } as any),
          ]),
          E('label', { class: 'tachyon-wizard__toggle-row' }, [
            E('input', {
              type: 'checkbox',
              checked: openconnectNoDtls ? true : undefined,
              change: (ev: Event) => {
                openconnectNoDtls = (ev.target as HTMLInputElement).checked;
              },
            } as any),
            E(
              'span',
              {},
              tr(
                'Отключить UDP DTLS (работать только поверх TCP TLS)',
                'Disable UDP DTLS (force TCP TLS only)',
              ),
            ),
          ]),
        );
      } else if (customProto === 'openvpn') {
        const parseOvpnText = (raw: string) => {
          const remoteMatch = raw.match(
            /^\s*remote\s+(\S+)(?:\s+(\d+))?(?:\s+(udp|tcp))?/im,
          );
          if (remoteMatch) {
            if (remoteMatch[1]) customHost = remoteMatch[1];
            if (remoteMatch[2]) customPort = remoteMatch[2];
            if (remoteMatch[3]) {
              openvpnProto = remoteMatch[3].toLowerCase() as 'udp' | 'tcp';
            }
          }
          const protoMatch = raw.match(/^\s*proto\s+(udp|tcp)/im);
          if (protoMatch && protoMatch[1]) {
            openvpnProto = protoMatch[1].toLowerCase() as 'udp' | 'tcp';
          }
          const cipherMatch = raw.match(/^\s*cipher\s+(\S+)/im);
          if (cipherMatch && cipherMatch[1]) {
            openvpnCipher = cipherMatch[1];
          }
        };

        const ovpnBtn = E(
          'button',
          {
            type: 'button',
            class: 'btn cbi-button cbi-button-action',
            style: 'margin-bottom: 8px;',
            click: () => {
              const inp = document.createElement('input');
              inp.type = 'file';
              inp.accept = '.ovpn,.conf,.txt';
              inp.addEventListener('change', () => {
                const file = inp.files?.[0];
                if (!file) return;
                const reader = new FileReader();
                reader.onload = (e) => {
                  openvpnConfig = String(e.target?.result || '').trim();
                  parseOvpnText(openvpnConfig);
                  if (!connName) {
                    connName = file.name.replace(/\.(ovpn|conf|txt)$/i, '');
                  }
                  rerender();
                };
                reader.readAsText(file);
              });
              inp.click();
            },
          },
          [
            renderFolderIcon(14),
            E(
              'span',
              {},
              tr('Загрузить профиль .ovpn', 'Upload .ovpn profile'),
            ),
          ],
        );

        formFields.push(
          E('div', { class: 'tachyon-wizard__field' }, [
            E(
              'label',
              { class: 'tachyon-wizard__label' },
              tr(
                'Профиль OpenVPN (.ovpn)',
                'OpenVPN Configuration Profile (.ovpn)',
              ),
            ),
            ovpnBtn,
            E(
              'textarea',
              {
                class: 'cbi-input-textarea tachyon-wizard__textarea',
                rows: 4,
                placeholder: 'client\ndev tun\nproto udp\nremote ...',
                input: (ev: Event) => {
                  openvpnConfig = (ev.target as HTMLTextAreaElement).value;
                  parseOvpnText(openvpnConfig);
                },
              } as any,
              openvpnConfig,
            ),
          ]),
          renderHostPortRow(
            tr('Адрес сервера OpenVPN', 'OpenVPN Remote Server'),
            tr('Порт', 'Port'),
            '1194',
          ),
          E('div', { class: 'tachyon-wizard__row-2col' }, [
            E('div', { class: 'tachyon-wizard__field' }, [
              E(
                'label',
                { class: 'tachyon-wizard__label' },
                tr('Транспорт и шифр (Cipher)', 'Transport & Cipher'),
              ),
              E('div', { class: 'tachyon-wizard__row-2col' }, [
                E(
                  'select',
                  {
                    class: 'cbi-input-select tachyon-wizard__select',
                    change: (ev: Event) => {
                      openvpnProto = (ev.target as HTMLSelectElement)
                        .value as any;
                    },
                  } as any,
                  [
                    ['udp', 'UDP'],
                    ['tcp', 'TCP'],
                  ].map(([val, lbl]) =>
                    E(
                      'option',
                      {
                        value: val,
                        selected: val === openvpnProto ? true : undefined,
                      },
                      lbl,
                    ),
                  ),
                ),
                E('input', {
                  type: 'text',
                  class: 'cbi-input-text tachyon-wizard__input',
                  placeholder: 'AES-256-GCM',
                  value: openvpnCipher,
                  input: (ev: Event) => {
                    openvpnCipher = (ev.target as HTMLInputElement).value;
                  },
                } as any),
              ]),
            ]),
            E('div', { class: 'tachyon-wizard__field' }, [
              E(
                'label',
                { class: 'tachyon-wizard__label' },
                tr(
                  'Логин и пароль (auth-user-pass, необязательно)',
                  'Username & Password (optional)',
                ),
              ),
              E('div', { class: 'tachyon-wizard__row-2col' }, [
                E('input', {
                  type: 'text',
                  class: 'cbi-input-text tachyon-wizard__input',
                  placeholder: tr('Логин', 'Username'),
                  value: customUsername,
                  input: (ev: Event) => {
                    customUsername = (ev.target as HTMLInputElement).value;
                  },
                } as any),
                E('input', {
                  type: 'text',
                  class: 'cbi-input-text tachyon-wizard__input',
                  placeholder: tr('Пароль', 'Password'),
                  value: customPassword,
                  input: (ev: Event) => {
                    customPassword = (ev.target as HTMLInputElement).value;
                  },
                } as any),
              ]),
            ]),
          ]),
        );
      } else if (customProto === 'tailscale') {
        formFields.push(
          E('div', { class: 'tachyon-wizard__field' }, [
            E(
              'label',
              { class: 'tachyon-wizard__label' },
              tr(
                'Сетевой интерфейс Tailscale на роутере',
                'Tailscale Interface Name on Router',
              ),
            ),
            E('input', {
              type: 'text',
              class: 'cbi-input-text tachyon-wizard__input',
              placeholder: 'tailscale0',
              value: customInterface || 'tailscale0',
              input: (ev: Event) => {
                customInterface = (ev.target as HTMLInputElement).value;
              },
            } as any),
          ]),
        );
      } else if (customProto === 'tor') {
        formFields.push(
          E('div', { class: 'tachyon-wizard__field' }, [
            E(
              'label',
              { class: 'tachyon-wizard__label' },
              tr(
                'Локальный SOCKS5-порт демона Tor (127.0.0.1)',
                'Local Tor Daemon SOCKS5 Port (127.0.0.1)',
              ),
            ),
            E('input', {
              type: 'number',
              class: 'cbi-input-text tachyon-wizard__input',
              placeholder: '9050',
              value: torSocksPort,
              input: (ev: Event) => {
                torSocksPort = (ev.target as HTMLInputElement).value;
              },
            } as any),
          ]),
        );
      } else if (customProto === 'interface') {
        formFields.push(
          E('div', { class: 'tachyon-wizard__field' }, [
            E(
              'label',
              { class: 'tachyon-wizard__label' },
              tr(
                'Имя сетевого интерфейса (или несколько через запятую)',
                'Network Interface Name (wg0, awg0, tun0)',
              ),
            ),
            E('input', {
              type: 'text',
              class: 'cbi-input-text tachyon-wizard__input',
              placeholder: 'wg0, awg0, tun0',
              value: customInterface,
              input: (ev: Event) => {
                customInterface = (ev.target as HTMLInputElement).value;
              },
            } as any),
          ]),
        );
      } else if (customProto === 'outbound_json') {
        formFields.push(
          E('div', { class: 'tachyon-wizard__field' }, [
            E(
              'label',
              { class: 'tachyon-wizard__label' },
              tr(
                'JSON-объект outbound (sing-box / tachyon-core)',
                'Raw Outbound JSON Object (sing-box / tachyon-core)',
              ),
            ),
            E(
              'textarea',
              {
                class: 'cbi-input-textarea tachyon-wizard__textarea',
                rows: 5,
                placeholder:
                  '{\n  "type": "vless",\n  "server": "example.com",\n  "server_port": 443,\n  "uuid": "..."\n}',
                input: (ev: Event) => {
                  outboundJsonText = (ev.target as HTMLTextAreaElement).value;
                },
              } as any,
              outboundJsonText,
            ),
          ]),
        );
      }
    }

    return E('div', { class: 'tachyon-wizard__body' }, [
      E('div', { class: 'tachyon-wizard__methods-grid' }, methodCards),
      E('div', { class: 'tachyon-wizard__form-box' }, formFields),
    ]);
  }

  function renderTachyonListsSelector() {
    const { element: step3HintBanner, showHint: showStep3Hint } =
      createInteractiveHintBanner();

    const presetDomainSet = new Set<string>();
    for (const preset of TRAFFIC_PRESETS) {
      if (selectedPresets.has(preset.id)) {
        for (const d of preset.domains) presetDomainSet.add(d);
      }
    }
    const combinedSelectedSet = new Set<string>([
      ...presetDomainSet,
      ...selectedIndividualLists,
    ]);
    const step3SubsumedMap = getSubsumedCommunityLists(combinedSelectedSet);

    return E('div', { class: 'tachyon-wizard__new-section-box' }, [
      E('div', { class: 'tachyon-wizard__field' }, [
        E(
          'label',
          { class: 'tachyon-wizard__label' },
          tr(
            'Быстрые пакеты маршрутизации (tachyon-lists)',
            'Quick Routing Presets (tachyon-lists)',
          ),
        ),
        E(
          'div',
          { class: 'tachyon-wizard__chips' },
          TRAFFIC_PRESETS.map((preset) => {
            const active = selectedPresets.has(preset.id);
            const firstKey = Array.isArray(preset.domains)
              ? preset.domains[0]
              : '';
            return E(
              'button',
              {
                type: 'button',
                class: `tachyon-wizard__chip ${active ? 'is-active' : ''}`,
                mouseenter: () => {
                  if (firstKey) showStep3Hint(firstKey);
                },
                click: () => {
                  if (selectedPresets.has(preset.id)) {
                    selectedPresets.delete(preset.id);
                  } else {
                    selectedPresets.add(preset.id);
                  }
                  rerender();
                },
              } as any,
              [
                active
                  ? renderCheckIcon(12)
                  : renderCommunityListServiceIcon(preset.id, 12),
                E('span', {}, tr(preset.labelRu, preset.labelEn)),
              ],
            );
          }),
        ),
      ]),
      step3HintBanner,
      E('div', { class: 'tachyon-wizard__field' }, [
        E(
          'div',
          {
            style:
              'display:flex;align-items:center;justify-content:space-between;gap:8px;flex-wrap:wrap;',
          },
          [
            E(
              'label',
              { class: 'tachyon-wizard__label', style: 'margin:0;' },
              tr(
                'Точечный выбор списков из каталога tachyon-lists',
                'Individual Lists from tachyon-lists Catalog',
              ),
            ),
            E(
              'button',
              {
                type: 'button',
                class: 'btn cbi-button',
                style: 'padding:3px 10px;font-size:12px;',
                click: () => {
                  showAllTachyonLists = !showAllTachyonLists;
                  rerender();
                },
              },
              showAllTachyonLists
                ? tr('▲ Скрыть полный каталог списков', '▲ Hide full catalog')
                : tr(
                    `▼ Открыть все списки по категориям (${selectedIndividualLists.size > 0 ? `выбрано: ${selectedIndividualLists.size}` : '50+ списков'})`,
                    `▼ Browse all lists by category (${selectedIndividualLists.size > 0 ? `selected: ${selectedIndividualLists.size}` : '50+ lists'})`,
                  ),
            ),
          ],
        ),
        showAllTachyonLists
          ? E(
              'div',
              {
                style:
                  'display:flex;flex-direction:column;gap:10px;margin-top:8px;padding:10px 12px;border-radius:10px;border:1px solid rgba(139,92,246,0.22);background:rgba(139,92,246,0.03);',
              },
              TACHYON_LIST_CATEGORIES.map((cat) =>
                E('div', {}, [
                  E(
                    'div',
                    {
                      style:
                        'font-size:12px;font-weight:700;margin-bottom:6px;opacity:0.85;display:flex;align-items:center;gap:6px;',
                    },
                    [
                      renderCommunityListServiceIcon(cat.id, 13),
                      E('span', {}, tr(cat.titleRu, cat.titleEn)),
                    ],
                  ),
                  E(
                    'div',
                    { class: 'tachyon-wizard__chips' },
                    cat.keys.map((key) => {
                      const subsumedParents = step3SubsumedMap.get(key);
                      const isSubsumed = Boolean(
                        subsumedParents && subsumedParents.length > 0,
                      );
                      const active =
                        (selectedIndividualLists.has(key) ||
                          presetDomainSet.has(key)) &&
                        !isSubsumed;
                      const label = DOMAIN_LIST_OPTIONS[key] || key;
                      const rawHint = DOMAIN_LIST_HINTS[key] || '';
                      const parentLabels = (subsumedParents || []).map(
                        (p) =>
                          (DOMAIN_LIST_OPTIONS as Record<string, string>)[p] ||
                          p,
                      );
                      const hint = isSubsumed
                        ? tr(
                            `[Уже входит в: ${parentLabels.join(', ')}] ${rawHint}`,
                            `[Already included in: ${parentLabels.join(', ')}] ${rawHint}`,
                          )
                        : rawHint;
                      return E(
                        'button',
                        {
                          type: 'button',
                          class: `tachyon-wizard__chip ${active ? 'is-active' : ''} ${isSubsumed ? 'is-subsumed' : ''}`,
                          disabled: isSubsumed ? true : undefined,
                          'aria-disabled': isSubsumed ? 'true' : 'false',
                          title: hint,
                          mouseenter: () => showStep3Hint(key, subsumedParents),
                          focus: () => showStep3Hint(key, subsumedParents),
                          click: () => {
                            if (isSubsumed) {
                              showStep3Hint(key, subsumedParents);
                              return;
                            }
                            if (selectedIndividualLists.has(key)) {
                              selectedIndividualLists.delete(key);
                            } else {
                              selectedIndividualLists.add(key);
                              const nextCombined = new Set<string>([
                                ...presetDomainSet,
                                ...selectedIndividualLists,
                              ]);
                              const nextSub =
                                getSubsumedCommunityLists(nextCombined);
                              for (const subKey of nextSub.keys()) {
                                selectedIndividualLists.delete(subKey);
                              }
                            }
                            rerender();
                          },
                        } as any,
                        [
                          active
                            ? renderCheckIcon(11)
                            : renderCommunityListServiceIcon(key, 11),
                          E('span', {}, `${isSubsumed ? '⊂ ' : ''}${label}`),
                          E(
                            'span',
                            {
                              class: 'tachyon-ruleset-picker__chip-info',
                              title: hint,
                              click: (ev: Event) => {
                                ev.preventDefault();
                                ev.stopPropagation();
                                showStep3Hint(key, subsumedParents);
                              },
                            } as any,
                            'ⓘ',
                          ),
                        ],
                      );
                    }),
                  ),
                ]),
              ),
            )
          : '',
      ]),
      E('div', { class: 'tachyon-wizard__field' }, [
        E(
          'label',
          { class: 'tachyon-wizard__label' },
          tr(
            'Дополнительные домены (необязательно, через запятую или с новой строки)',
            'Additional custom domains (optional, comma or newline separated)',
          ),
        ),
        E('input', {
          type: 'text',
          class: 'cbi-input-text tachyon-wizard__input',
          placeholder: 'example.com, myservice.org',
          value: customDomainsText,
          input: (ev: Event) => {
            customDomainsText = (ev.target as HTMLInputElement).value;
          },
        } as any),
      ]),
    ]);
  }

  function renderStep3Outbound() {
    const canUseUrlTest =
      outboundMethod === 'subscription' ||
      outboundMethod === 'proxy_links' ||
      outboundMethod === 'amnezia_config';

    return E('div', { class: 'tachyon-wizard__body' }, [
      E('div', { class: 'tachyon-wizard__form-box' }, [
        E(
          'div',
          { class: 'tachyon-wizard__section-title' },
          tr(
            '1. Куда направить это подключение?',
            '1. Where should this connection be used?',
          ),
        ),
        E('div', { class: 'tachyon-wizard__radio-row' }, [
          existingSections.length > 0
            ? E(
                'button',
                {
                  type: 'button',
                  class: `tachyon-wizard__pill-btn ${targetMode === 'existing' ? 'is-active' : ''}`,
                  click: () => {
                    targetMode = 'existing';
                    rerender();
                  },
                },
                tr(
                  'В существующую секцию',
                  'Attach to existing routing section',
                ),
              )
            : '',
          E(
            'button',
            {
              type: 'button',
              class: `tachyon-wizard__pill-btn ${targetMode === 'new' ? 'is-active' : ''}`,
              click: () => {
                targetMode = 'new';
                rerender();
              },
            },
            tr(
              '+ Создать новую секцию маршрутизации',
              '+ Create new routing section',
            ),
          ),
          E(
            'button',
            {
              type: 'button',
              class: `tachyon-wizard__pill-btn ${targetMode === 'pool_only' ? 'is-active' : ''}`,
              click: () => {
                targetMode = 'pool_only';
                rerender();
              },
            },
            tr(
              'Только в пул подключений (без секции)',
              'Add to Connections Pool only',
            ),
          ),
        ]),

        targetMode === 'pool_only'
          ? E(
              'div',
              { class: 'tachyon-wizard__toggle-box' },
              tr(
                'Подключение будет добавлено в раздел «Подключения (Аутбаунды)» без создания или изменения секций маршрутизации.',
                'The connection will be added to Outbound Connections without creating or modifying routing sections.',
              ),
            )
          : targetMode === 'existing' && existingSections.length > 0
            ? E('div', { class: 'tachyon-wizard__new-section-box' }, [
                E('div', { class: 'tachyon-wizard__field' }, [
                  E(
                    'label',
                    { class: 'tachyon-wizard__label' },
                    tr('Выберите секцию', 'Select Section'),
                  ),
                  E(
                    'select',
                    {
                      class: 'cbi-input-select tachyon-wizard__select',
                      change: (ev: Event) => {
                        targetExistingSection = (ev.target as HTMLSelectElement)
                          .value;
                      },
                    } as any,
                    existingSections.map((s: { id: string; label: string }) =>
                      E(
                        'option',
                        {
                          value: s.id,
                          selected:
                            s.id === targetExistingSection ? true : undefined,
                        },
                        `${s.label} (${s.id})`,
                      ),
                    ),
                  ),
                ]),
                E('div', { class: 'tachyon-wizard__toggle-box' }, [
                  E('label', { class: 'tachyon-wizard__checkbox-label' }, [
                    E('input', {
                      type: 'checkbox',
                      checked: appendPresetsToExisting ? true : undefined,
                      change: (ev: Event) => {
                        appendPresetsToExisting = (
                          ev.target as HTMLInputElement
                        ).checked;
                        rerender();
                      },
                    } as any),
                    E('div', {}, [
                      E(
                        'div',
                        { class: 'tachyon-wizard__checkbox-title' },
                        tr(
                          'Дополнить выбранную секцию новыми списками tachyon-lists',
                          'Also add tachyon-lists rules to the selected section',
                        ),
                      ),
                      E(
                        'div',
                        { class: 'tachyon-wizard__checkbox-desc' },
                        tr(
                          'Позволяет сразу прикрепить нужные списки сервисов и доменов к существующей секции',
                          'Allows attaching selected service lists and custom domains to the existing section right away',
                        ),
                      ),
                    ]),
                  ]),
                ]),
                appendPresetsToExisting ? renderTachyonListsSelector() : '',
              ])
            : E('div', { class: 'tachyon-wizard__new-section-box' }, [
                E('div', { class: 'tachyon-wizard__field' }, [
                  E(
                    'label',
                    { class: 'tachyon-wizard__label' },
                    tr('Название новой секции', 'New Section Name'),
                  ),
                  E('input', {
                    type: 'text',
                    class: 'cbi-input-text tachyon-wizard__input',
                    placeholder: tr(
                      'Например: Основной маршрут, Стриминг, Работа',
                      'e.g. Main Route, Streaming, Work',
                    ),
                    value: newSectionName || connName || 'Main',
                    input: (ev: Event) => {
                      newSectionName = (ev.target as HTMLInputElement).value;
                    },
                  } as any),
                ]),
                renderTachyonListsSelector(),
              ]),

        canUseUrlTest
          ? E('div', { class: 'tachyon-wizard__toggle-box' }, [
              E('label', { class: 'tachyon-wizard__checkbox-label' }, [
                E('input', {
                  type: 'checkbox',
                  checked: enableAutoUrlTest ? true : undefined,
                  change: (ev: Event) => {
                    enableAutoUrlTest = (ev.target as HTMLInputElement).checked;
                  },
                } as any),
                E('div', {}, [
                  E(
                    'div',
                    { class: 'tachyon-wizard__checkbox-title' },
                    tr(
                      'Автовыбор самого быстрого сервера (URLTest)',
                      'Auto-select fastest server (URLTest)',
                    ),
                  ),
                  E(
                    'div',
                    { class: 'tachyon-wizard__checkbox-desc' },
                    tr(
                      'Роутер сам измеряет задержку и автоматически переключает маршрут на самый быстрый живой узел без разрыва связи',
                      'Router automatically measures latency and switches to the fastest alive server seamlessly',
                    ),
                  ),
                ]),
              ]),
            ])
          : '',
      ]),
    ]);
  }

  function renderStep4Outbound() {
    if (!dnsBenchHydrated) {
      dnsBenchHydrated = true;
      void TachyonShellMethods.getDnsBenchmarkStatus()
        .then((res) => {
          if (!res?.success || !res.data) return;
          const d = res.data;
          if (d.recommendation) {
            dnsBenchRecommendation = d.recommendation;
          }
          if (d.running) {
            dnsBenchRunning = true;
            dnsBenchProgress = d.progress || 0;
            dnsBenchCurrentServer = d.current_server || '';
            startDnsBenchPolling();
          }
          if (step === 4 && (dnsBenchRecommendation || d.running)) {
            rerender();
          }
        })
        .catch(() => null);
    }

    async function pollDnsBenchmarkOnce() {
      if (dnsBenchPolling) return;
      if (!root.isConnected) {
        stopDnsBenchPollTimer();
        return;
      }
      dnsBenchPolling = true;
      try {
        const res = await TachyonShellMethods.getDnsBenchmarkStatus();
        if (!res?.success || !res.data) return;
        const d = res.data;
        const wasRunning = dnsBenchRunning;
        dnsBenchRunning = Boolean(d.running);
        dnsBenchProgress = typeof d.progress === 'number' ? d.progress : 0;
        dnsBenchCurrentServer = d.current_server || '';
        if (d.recommendation) {
          dnsBenchRecommendation = d.recommendation;
        }
        if (!d.running) {
          stopDnsBenchPollTimer();
          if (d.error) {
            dnsBenchError = d.error;
          } else if (d.recommendation) {
            dnsBenchError = null;
            globalDnsPreset = 'autotune';
            if (wasRunning) {
              showToast(
                tr(
                  'Автоподбор DNS завершён! Оптимальная связка выбрана.',
                  'DNS Auto-Tune completed! Optimal stack selected.',
                ),
                'success',
              );
            }
          }
          if (step === 4) rerender();
        } else if (step === 4) {
          const activeTag = document.activeElement?.tagName;
          if (activeTag !== 'INPUT' && activeTag !== 'TEXTAREA') {
            rerender();
          }
        }
      } catch {
        // ignore transient poll errors
      } finally {
        dnsBenchPolling = false;
      }
    }

    function startDnsBenchPolling() {
      stopDnsBenchPollTimer();
      dnsBenchPollTimer = window.setInterval(() => {
        void pollDnsBenchmarkOnce();
      }, 1000);
    }

    async function startWizardDnsBenchmark() {
      dnsBenchRunning = true;
      dnsBenchProgress = 5;
      dnsBenchCurrentServer = tr(
        'Замер скорости DNS...',
        'Benchmarking DNS...',
      );
      dnsBenchError = null;
      globalDnsPreset = 'autotune';
      rerender();

      try {
        const res = await TachyonShellMethods.startDnsBenchmark();
        if (!res?.success) {
          dnsBenchRunning = false;
          dnsBenchError =
            res?.error ||
            tr(
              'Не удалось запустить тест скорости DNS',
              'Failed to start DNS benchmark',
            );
          rerender();
          return;
        }
        startDnsBenchPolling();
        void pollDnsBenchmarkOnce();
      } catch (err) {
        dnsBenchRunning = false;
        dnsBenchError =
          (err as Error)?.message ||
          tr('Ошибка запуска автоподбора DNS', 'Error starting DNS benchmark');
        rerender();
      }
    }

    return E('div', { class: 'tachyon-wizard__body' }, [
      E('div', { class: 'tachyon-wizard__form-box' }, [
        E(
          'div',
          { class: 'tachyon-wizard__section-title' },
          tr('1. Основной DNS роутера', '1. Router Primary DNS'),
        ),
        E('div', { class: 'tachyon-wizard__field' }, [
          E(
            'div',
            { class: 'tachyon-wizard__dns-presets-grid' },
            WIZARD_GLOBAL_DNS_PRESETS.map((p) => {
              const active = p.id === globalDnsPreset;
              const isAuto = p.id === 'autotune';
              let dynamicDesc = tr(p.descRu, p.descEn);
              if (isAuto) {
                if (dnsBenchRunning) {
                  dynamicDesc = `${dnsBenchCurrentServer || tr('Замер скорости...', 'Benchmarking...')} (${dnsBenchProgress}%)`;
                } else if (dnsBenchError) {
                  dynamicDesc = String(dnsBenchError);
                } else if (dnsBenchRecommendation) {
                  const primaryStr = (
                    dnsBenchRecommendation.dns_server || []
                  ).join(', ');
                  const bootStr = (
                    dnsBenchRecommendation.bootstrap_dns_server || []
                  ).join(', ');
                  dynamicDesc = `${(dnsBenchRecommendation.dns_type || 'doh').toUpperCase()}: ${primaryStr}${bootStr ? ` · Bootstrap: ${bootStr}` : ''}`;
                }
              }

              return E(
                'button',
                {
                  type: 'button',
                  class: `tachyon-wizard__dns-preset-card ${active ? 'is-selected' : ''} ${isAuto ? 'is-autotune' : ''}`,
                  click: () => {
                    globalDnsPreset = p.id;
                    if (isAuto && !dnsBenchRunning) {
                      void startWizardDnsBenchmark();
                      return;
                    }
                    rerender();
                  },
                },
                [
                  E('div', { class: 'tachyon-wizard__dns-preset-top' }, [
                    E(
                      'span',
                      {
                        class: 'tachyon-wizard__dns-preset-title',
                        style: 'display:flex;align-items:center;gap:6px;',
                      },
                      [
                        renderCommunityListServiceIcon(p.id, 13),
                        E('span', {}, tr(p.shortRu, p.shortEn)),
                      ],
                    ),
                    E(
                      'span',
                      { class: 'tachyon-wizard__dns-preset-badge' },
                      isAuto && dnsBenchRunning
                        ? `${dnsBenchProgress}%`
                        : isAuto && dnsBenchRecommendation
                          ? tr('Замерить', 'Re-test')
                          : p.badge,
                    ),
                  ]),
                  E(
                    'div',
                    { class: 'tachyon-wizard__dns-preset-desc' },
                    dynamicDesc,
                  ),
                ],
              );
            }),
          ),
        ]),
        globalDnsPreset === 'custom'
          ? E('div', { class: 'tachyon-wizard__row-2col' }, [
              E('div', { class: 'tachyon-wizard__field' }, [
                E(
                  'label',
                  { class: 'tachyon-wizard__label' },
                  tr('Протокол DNS', 'DNS Protocol'),
                ),
                E(
                  'select',
                  {
                    class: 'cbi-input-select tachyon-wizard__select',
                    change: (ev: Event) => {
                      customGlobalDnsType = (ev.target as HTMLSelectElement)
                        .value as 'udp' | 'doh' | 'dot';
                    },
                  } as any,
                  [
                    ['udp', 'UDP (порт 53)'],
                    ['doh', 'DNS over HTTPS (DoH)'],
                    ['dot', 'DNS over TLS (DoT)'],
                  ].map(([val, lbl]) =>
                    E(
                      'option',
                      {
                        value: val,
                        selected:
                          val === customGlobalDnsType ? true : undefined,
                      },
                      lbl,
                    ),
                  ),
                ),
              ]),
              E('div', { class: 'tachyon-wizard__field' }, [
                E(
                  'label',
                  { class: 'tachyon-wizard__label' },
                  tr('Адрес DNS-сервера', 'DNS Server Address'),
                ),
                E('input', {
                  type: 'text',
                  class: 'cbi-input-text tachyon-wizard__input',
                  placeholder: '77.88.8.8, 1.1.1.1 или https://...',
                  value: customGlobalDnsServer,
                  input: (ev: Event) => {
                    customGlobalDnsServer = (ev.target as HTMLInputElement)
                      .value;
                  },
                } as any),
              ]),
            ])
          : '',
        targetMode !== 'pool_only'
          ? E('div', { class: 'tachyon-wizard__toggle-box' }, [
              E('label', { class: 'tachyon-wizard__checkbox-label' }, [
                E('input', {
                  type: 'checkbox',
                  checked: enableDnsDetour ? true : undefined,
                  change: (ev: Event) => {
                    enableDnsDetour = (ev.target as HTMLInputElement).checked;
                  },
                } as any),
                E('div', {}, [
                  E(
                    'div',
                    {
                      class: 'tachyon-wizard__checkbox-title',
                      style: 'display:inline-flex;align-items:center;gap:6px;',
                    },
                    [
                      renderLockIcon(14),
                      tr(
                        'Направлять DNS-запросы через этот туннель (DNS Detour)',
                        'Route DNS queries through this tunnel (DNS Detour)',
                      ),
                    ],
                  ),
                  E(
                    'div',
                    { class: 'tachyon-wizard__checkbox-desc' },
                    tr(
                      'Защищает зарубежные DNS-серверы (Cloudflare/Google/Quad9) от подмены и блокировки со стороны провайдера',
                      'Prevents ISP DNS spoofing or blocking when using foreign resolvers like Cloudflare or Google',
                    ),
                  ),
                ]),
              ]),
            ])
          : '',

        E(
          'div',
          {
            class: 'tachyon-wizard__section-title',
            style: 'margin-top: 14px;',
          },
          tr(
            '2. Прямой проброс игр и сервисов РФ через провайдера + Яндекс DNS',
            '2. Direct ISP Route for Games & RU Services + Yandex DNS',
          ),
        ),
        E('div', { class: 'tachyon-wizard__toggle-box' }, [
          E('label', { class: 'tachyon-wizard__checkbox-label' }, [
            E('input', {
              type: 'checkbox',
              checked: enableDirectGamesBypass ? true : undefined,
              change: (ev: Event) => {
                enableDirectGamesBypass = (ev.target as HTMLInputElement)
                  .checked;
                rerender();
              },
            } as any),
            E('div', {}, [
              E(
                'div',
                {
                  class: 'tachyon-wizard__checkbox-title',
                  style: 'display:inline-flex;align-items:center;gap:6px;',
                },
                [
                  renderGamepad2Icon(14),
                  tr(
                    'Прокинуть игры и сервисы РФ напрямую через провайдера с Яндекс DNS (77.88.8.8)',
                    'Route games & Russian services directly via ISP with Yandex DNS (77.88.8.8)',
                  ),
                ],
              ),
              E(
                'div',
                { class: 'tachyon-wizard__checkbox-desc' },
                tr(
                  'Создаёт приоритетную секцию прямого выхода (WAN Direct) с разрешением доменов через российский DNS (Яндекс 77.88.8.8). Игры (Steam, Valorant/Riot, CS2, Epic, Tarkov) и сервисы РФ (Госуслуги, банки, Ozon, WB) работают без лишнего пинга VPN и скачивают обновления с ближайших российских серверов провайдера на максимальной скорости.',
                  'Creates a top-priority direct bypass section with Russian DNS resolution (Yandex 77.88.8.8) so games and local services get minimal latency and connect to the nearest ISP CDN servers.',
                ),
              ),
            ]),
          ]),
        ]),

        enableDirectGamesBypass
          ? E('div', { class: 'tachyon-wizard__new-section-box' }, [
              E('div', { class: 'tachyon-wizard__field' }, [
                E(
                  'label',
                  { class: 'tachyon-wizard__label' },
                  tr(
                    'DNS-сервер для прямого маршрута игр и РФ (Routed Direct DNS)',
                    'DNS Resolver for Direct Games & RU Route',
                  ),
                ),
                E(
                  'select',
                  {
                    class: 'cbi-input-select tachyon-wizard__select',
                    change: (ev: Event) => {
                      directBypassDnsPreset = (ev.target as HTMLSelectElement)
                        .value;
                      rerender();
                    },
                  } as any,
                  DIRECT_BYPASS_DNS_PRESETS.map((p) =>
                    E(
                      'option',
                      {
                        value: p.id,
                        selected:
                          p.id === directBypassDnsPreset ? true : undefined,
                      },
                      tr(p.labelRu, p.labelEn),
                    ),
                  ),
                ),
              ]),
              directBypassDnsPreset === 'custom'
                ? E('div', { class: 'tachyon-wizard__field' }, [
                    E(
                      'label',
                      { class: 'tachyon-wizard__label' },
                      tr(
                        'IP-адрес DNS провайдера (или несколько через запятую)',
                        'ISP DNS IP address (comma separated)',
                      ),
                    ),
                    E('input', {
                      type: 'text',
                      class: 'cbi-input-text tachyon-wizard__input',
                      placeholder: '77.88.8.8, 77.88.8.1',
                      value: customDirectBypassDnsServer,
                      input: (ev: Event) => {
                        customDirectBypassDnsServer = (
                          ev.target as HTMLInputElement
                        ).value;
                      },
                    } as any),
                  ])
                : '',
              (() => {
                const { element: step4HintBanner, showHint: showStep4Hint } =
                  createInteractiveHintBanner();
                const step4SubsumedMap = getSubsumedCommunityLists(
                  selectedDirectBypassLists,
                );
                return E('div', { class: 'tachyon-wizard__field' }, [
                  E(
                    'label',
                    { class: 'tachyon-wizard__label' },
                    tr(
                      'Какие игры и сервисы пустить напрямую через провайдера?',
                      'Which games & services should go directly through your ISP?',
                    ),
                  ),
                  step4HintBanner,
                  E(
                    'div',
                    { class: 'tachyon-wizard__chips' },
                    DIRECT_BYPASS_PRESETS.map((item) => {
                      const subsumedParents = step4SubsumedMap.get(item.key);
                      const isSubsumed = Boolean(
                        subsumedParents && subsumedParents.length > 0,
                      );
                      const active =
                        selectedDirectBypassLists.has(item.key) && !isSubsumed;
                      const rawHint = DOMAIN_LIST_HINTS[item.key] || '';
                      const parentLabels = (subsumedParents || []).map(
                        (p) =>
                          (DOMAIN_LIST_OPTIONS as Record<string, string>)[p] ||
                          p,
                      );
                      const hint = isSubsumed
                        ? tr(
                            `[Уже входит в: ${parentLabels.join(', ')}] ${rawHint}`,
                            `[Already included in: ${parentLabels.join(', ')}] ${rawHint}`,
                          )
                        : rawHint;
                      return E(
                        'button',
                        {
                          type: 'button',
                          class: `tachyon-wizard__chip ${active ? 'is-active' : ''} ${isSubsumed ? 'is-subsumed' : ''}`,
                          disabled: isSubsumed ? true : undefined,
                          'aria-disabled': isSubsumed ? 'true' : 'false',
                          title: hint,
                          mouseenter: () =>
                            showStep4Hint(item.key, subsumedParents),
                          focus: () => showStep4Hint(item.key, subsumedParents),
                          click: () => {
                            if (isSubsumed) {
                              showStep4Hint(item.key, subsumedParents);
                              return;
                            }
                            if (selectedDirectBypassLists.has(item.key)) {
                              selectedDirectBypassLists.delete(item.key);
                            } else {
                              selectedDirectBypassLists.add(item.key);
                              const nextSub = getSubsumedCommunityLists(
                                selectedDirectBypassLists,
                              );
                              for (const subKey of nextSub.keys()) {
                                selectedDirectBypassLists.delete(subKey);
                              }
                            }
                            rerender();
                          },
                        } as any,
                        [
                          renderCommunityListServiceIcon(item.key, 12),
                          E(
                            'span',
                            {
                              style:
                                'display:inline-flex;align-items:center;gap:4px;',
                            },
                            [
                              active
                                ? renderCheckIcon(11)
                                : isSubsumed
                                  ? '⊂ '
                                  : '',
                              tr(item.labelRu, item.labelEn),
                            ],
                          ),
                          E(
                            'span',
                            {
                              class: 'tachyon-ruleset-picker__chip-info',
                              title: hint,
                              click: (ev: Event) => {
                                ev.preventDefault();
                                ev.stopPropagation();
                                showStep4Hint(item.key, subsumedParents);
                              },
                            } as any,
                            'i',
                          ),
                        ],
                      );
                    }),
                  ),
                ]);
              })(),
              E('div', { class: 'tachyon-wizard__row-2col' }, [
                E('div', { class: 'tachyon-wizard__field' }, [
                  E(
                    'label',
                    { class: 'tachyon-wizard__label' },
                    tr(
                      'Свои домены/игры напрямую (необязательно)',
                      'Custom direct domains/games (optional)',
                    ),
                  ),
                  E('input', {
                    type: 'text',
                    class: 'cbi-input-text tachyon-wizard__input',
                    placeholder:
                      'lesta.ru, tanki.su, vkplay.ru, warthunder.com',
                    value: directBypassCustomDomains,
                    input: (ev: Event) => {
                      directBypassCustomDomains = (
                        ev.target as HTMLInputElement
                      ).value;
                    },
                  } as any),
                ]),
                E('div', { class: 'tachyon-wizard__field' }, [
                  E(
                    'label',
                    { class: 'tachyon-wizard__label' },
                    tr(
                      'IP устройств в LAN для полного прямого выхода (необязательно)',
                      'LAN Device IPs for direct bypass (optional)',
                    ),
                  ),
                  E('input', {
                    type: 'text',
                    class: 'cbi-input-text tachyon-wizard__input',
                    placeholder: '192.168.1.50 (например, консоль или ПК)',
                    value: directBypassSourceIps,
                    input: (ev: Event) => {
                      directBypassSourceIps = (ev.target as HTMLInputElement)
                        .value;
                    },
                  } as any),
                ]),
              ]),
            ])
          : '',

        E('div', { class: 'tachyon-wizard__toggle-box' }, [
          E('label', { class: 'tachyon-wizard__checkbox-label' }, [
            E('input', {
              type: 'checkbox',
              checked: enableAdBlockSection ? true : undefined,
              change: (ev: Event) => {
                enableAdBlockSection = (ev.target as HTMLInputElement).checked;
              },
            } as any),
            E('div', {}, [
              E(
                'div',
                {
                  class: 'tachyon-wizard__checkbox-title',
                  style: 'display:inline-flex;align-items:center;gap:6px;',
                },
                [
                  renderBanIcon(14),
                  tr(
                    'Блокировать рекламу, трекеры и телеметрию Windows (Hagezi PRO + WinSpy)',
                    'Block Ads, Trackers & Windows Telemetry (Hagezi PRO + WinSpy)',
                  ),
                ],
              ),
              E(
                'div',
                { class: 'tachyon-wizard__checkbox-desc' },
                tr(
                  'Создаёт секцию блокировки (Block) со списками ads_hagezi_pro и win_spy из каталога tachyon-lists на уровне роутера',
                  'Creates a router-level Block section using ads_hagezi_pro and win_spy lists from tachyon-lists',
                ),
              ),
            ]),
          ]),
        ]),
      ]),
    ]);
  }

  function renderStep2Inbound() {
    return E('div', { class: 'tachyon-wizard__body' }, [
      E(
        'p',
        { class: 'tachyon-wizard__subtitle' },
        tr(
          'Выберите протокол для вашего входящего сервера на роутере. Ключи шифрования, UUID и сертификаты сгенерируются автоматически.',
          'Select the protocol for your router inbound server. Encryption keys, UUIDs, and certificates will be generated automatically.',
        ),
      ),
      E(
        'div',
        { class: 'tachyon-wizard__methods-grid' },
        INBOUND_PROTOCOLS.map((p) =>
          E(
            'button',
            {
              type: 'button',
              class: `tachyon-wizard__method-card ${inboundProto === p.id ? 'is-selected' : ''}`,
              click: () => {
                inboundProto = p.id;
                inboundPort = p.defaultPort;
                inboundName = `Tachyon ${p.title.split(' ')[0]}`;
                rerender();
              },
            },
            [
              E('div', { class: 'tachyon-wizard__method-header' }, [
                E('span', { class: 'tachyon-wizard__method-title' }, p.title),
                E('span', { class: 'tachyon-wizard__method-badge' }, p.badge),
              ]),
              E(
                'div',
                { class: 'tachyon-wizard__method-desc' },
                tr(p.descRu, p.descEn),
              ),
            ],
          ),
        ),
      ),
    ]);
  }

  function renderStep3Inbound() {
    return E('div', { class: 'tachyon-wizard__body' }, [
      E('div', { class: 'tachyon-wizard__form-box' }, [
        E('div', { class: 'tachyon-wizard__row-2col' }, [
          E('div', { class: 'tachyon-wizard__field' }, [
            E(
              'label',
              { class: 'tachyon-wizard__label' },
              tr('Название сервера', 'Server Label'),
            ),
            E('input', {
              type: 'text',
              class: 'cbi-input-text tachyon-wizard__input',
              value: inboundName,
              input: (ev: Event) => {
                inboundName = (ev.target as HTMLInputElement).value;
              },
            } as any),
          ]),
          E('div', { class: 'tachyon-wizard__field' }, [
            E(
              'label',
              { class: 'tachyon-wizard__label' },
              tr('Порт прослушивания', 'Listen Port'),
            ),
            E('input', {
              type: 'number',
              class: 'cbi-input-text tachyon-wizard__input',
              value: inboundPort,
              input: (ev: Event) => {
                inboundPort = (ev.target as HTMLInputElement).value;
              },
            } as any),
          ]),
        ]),

        inboundProto === 'vless'
          ? E('div', { class: 'tachyon-wizard__field' }, [
              E(
                'label',
                { class: 'tachyon-wizard__label' },
                tr(
                  'Домен маскировки Reality (SNI)',
                  'Reality Camouflage Domain (SNI)',
                ),
              ),
              E('input', {
                type: 'text',
                class: 'cbi-input-text tachyon-wizard__input',
                value: inboundSni,
                input: (ev: Event) => {
                  inboundSni = (ev.target as HTMLInputElement).value;
                },
              } as any),
            ])
          : '',

        E('div', { class: 'tachyon-wizard__row-2col' }, [
          E('div', { class: 'tachyon-wizard__field' }, [
            E(
              'label',
              { class: 'tachyon-wizard__label' },
              tr('Маршрутизация трафика клиентов', 'Client Traffic Routing'),
            ),
            E(
              'select',
              {
                class: 'cbi-input-select tachyon-wizard__select',
                change: (ev: Event) => {
                  inboundRoutingMode = (ev.target as HTMLSelectElement).value;
                },
              } as any,
              [
                E(
                  'option',
                  {
                    value: 'rules',
                    selected: inboundRoutingMode === 'rules' ? true : undefined,
                  },
                  tr(
                    'По правилам секций Tachyon (обход блокировок)',
                    'Through Tachyon Routing Rules',
                  ),
                ),
                E(
                  'option',
                  {
                    value: 'direct',
                    selected:
                      inboundRoutingMode === 'direct' ? true : undefined,
                  },
                  tr(
                    'Напрямую через домашний интернет',
                    'Direct via router WAN',
                  ),
                ),
              ],
            ),
          ]),
          E('div', { class: 'tachyon-wizard__field' }, [
            E(
              'label',
              { class: 'tachyon-wizard__label' },
              tr('Код страны (флаг в ссылке)', 'Country Flag Code'),
            ),
            E('input', {
              type: 'text',
              class: 'cbi-input-text tachyon-wizard__input',
              value: inboundCountry,
              placeholder: 'RU',
              input: (ev: Event) => {
                inboundCountry = (ev.target as HTMLInputElement).value
                  .trim()
                  .toUpperCase();
              },
            } as any),
          ]),
        ]),

        E('div', { class: 'tachyon-wizard__toggle-box' }, [
          E('label', { class: 'tachyon-wizard__checkbox-label' }, [
            E('input', {
              type: 'checkbox',
              checked: inboundOpenFirewall ? true : undefined,
              change: (ev: Event) => {
                inboundOpenFirewall = (ev.target as HTMLInputElement).checked;
              },
            } as any),
            E('div', {}, [
              E(
                'div',
                {
                  class: 'tachyon-wizard__checkbox-title',
                  style: 'display:inline-flex;align-items:center;gap:6px;',
                },
                [
                  renderShieldIcon(14),
                  tr(
                    'Автоматически открыть порт в межсетевом экране (nftables)',
                    'Automatically open port in router firewall (nftables)',
                  ),
                ],
              ),
              E(
                'div',
                { class: 'tachyon-wizard__checkbox-desc' },
                tr(
                  'Разрешает входящие подключения из WAN на выбранный порт сервера',
                  'Allows inbound WAN connections to the selected server port',
                ),
              ),
            ]),
          ]),
        ]),
      ]),
    ]);
  }

  let isSubmitting = false;

  async function persistAndFinish(
    dir: 'outbound' | 'inbound',
    sectionId: string,
    displayLabel: string,
    applyImmediately: boolean,
  ) {
    if (isSubmitting) return;
    isSubmitting = true;
    try {
      if (typeof uciObj.save === 'function') {
        await Promise.resolve(uciObj.save());
      }
      if (uiObj.changes && typeof uiObj.changes.init === 'function') {
        await Promise.resolve(uiObj.changes.init());
      }
      if (
        applyImmediately &&
        uiObj.changes &&
        typeof uiObj.changes.apply === 'function'
      ) {
        await Promise.resolve(uiObj.changes.apply(true));
        try {
          await TachyonShellMethods.serviceActionStart('reload');
          if (
            typeof window !== 'undefined' &&
            typeof window.setTimeout === 'function'
          ) {
            window.setTimeout(() => {
              TachyonShellMethods.getUiState()
                .then((res) => {
                  if (res?.success) applyUiStateToStore(res.data);
                })
                .catch(() => null);
            }, 600);
          }
        } catch {
          // ignore reload trigger error
        }
      }
    } catch {
      // ignore save error in mock environments
    } finally {
      isSubmitting = false;
    }

    stopDnsBenchPollTimer();
    uiObj.hideModal();
    showToast(
      applyImmediately
        ? tr(
            `«${displayLabel}» создано и применено!`,
            `"${displayLabel}" created and applied!`,
          )
        : tr(
            `«${displayLabel}» сохранено! Нажмите «Сохранить и применить» для запуска.`,
            `"${displayLabel}" saved! Click "Save & Apply" to activate.`,
          ),
      'success',
    );
    options.onComplete?.({ direction: dir, sectionId });
  }

  async function finishOutboundWizard(applyImmediately = false) {
    const finalName =
      connName.trim() ||
      (targetMode === 'new' && newSectionName.trim()
        ? newSectionName.trim()
        : '') ||
      (outboundMethod === 'subscription'
        ? tr('Подписка', 'Subscription')
        : outboundMethod === 'proxy_links'
          ? tr('Прокси-узлы', 'Proxy Nodes')
          : outboundMethod === 'amnezia_config'
            ? 'AmneziaWG'
            : outboundMethod === 'warp'
              ? 'Cloudflare WARP'
              : outboundMethod === 'desync'
                ? 'Tachyon Desync'
                : outboundMethod === 'fptn'
                  ? 'FPTN VPN'
                  : customProto.toUpperCase());

    if (outboundMethod === 'subscription' && !subUrl.trim()) {
      showToast(
        tr('Укажите ссылку на подписку (URL)', 'Please enter Subscription URL'),
        'error',
      );
      return;
    }
    if (outboundMethod === 'proxy_links' && !proxyLinksText.trim()) {
      showToast(
        tr(
          'Вставьте хотя бы одну ссылку на сервер',
          'Please paste at least one share link',
        ),
        'error',
      );
      return;
    }
    if (outboundMethod === 'amnezia_config' && !amneziaText.trim()) {
      showToast(
        tr(
          'Вставьте ключ vpn:// или загрузите файл .conf',
          'Please paste a vpn:// link or upload a .conf file',
        ),
        'error',
      );
      return;
    }

    const srcId = sanitizeId(finalName, 'src');
    const actualSourceType =
      outboundMethod === 'custom_proto'
        ? customProto
        : outboundMethod === 'desync'
          ? dpiEngineType
          : outboundMethod;

    uciObj.add(TACHYON_UCI_PACKAGE, 'outbound_source', srcId);
    uciObj.set(TACHYON_UCI_PACKAGE, srcId, 'enabled', '1');
    uciObj.set(TACHYON_UCI_PACKAGE, srcId, 'name', finalName);
    uciObj.set(TACHYON_UCI_PACKAGE, srcId, 'source_type', actualSourceType);

    if (outboundMethod === 'subscription') {
      uciObj.set(TACHYON_UCI_PACKAGE, srcId, 'url', subUrl.trim());
    } else if (outboundMethod === 'proxy_links') {
      const links = proxyLinksText
        .split(/\r?\n/)
        .map((l) => l.trim())
        .filter(Boolean);
      uciObj.set(TACHYON_UCI_PACKAGE, srcId, 'proxy_links', links);
    } else if (outboundMethod === 'amnezia_config') {
      const trimmed = amneziaText.trim();
      if (trimmed.startsWith('vpn://')) {
        const links = trimmed
          .split(/\r?\n/)
          .map((l) => l.trim())
          .filter(Boolean);
        uciObj.set(TACHYON_UCI_PACKAGE, srcId, 'amnezia_configs', links);
      } else {
        uciObj.set(TACHYON_UCI_PACKAGE, srcId, 'amnezia_conf_text', trimmed);
        uciObj.set(TACHYON_UCI_PACKAGE, srcId, 'amnezia_configs', [
          JSON.stringify({ name: finalName, config: trimmed }),
        ]);
      }
    } else if (outboundMethod === 'warp') {
      if (!warpPrivateKey.trim()) {
        const g = globalThis as any;
        const fsObj =
          (typeof fs !== 'undefined' && fs) || g.fs || g.L?.fs || null;
        if (fsObj && typeof fsObj.exec === 'function') {
          try {
            showToast(
              tr(
                'Регистрация ключей Cloudflare WARP...',
                'Registering Cloudflare WARP keys...',
              ),
              'success',
            );
            const res = await fsObj.exec('/usr/bin/tachyon', ['generate_warp']);
            if (res && res.code === 0 && res.stdout) {
              const data = JSON.parse(String(res.stdout).trim());
              applyGeneratedWarpPayload(data);
            }
          } catch {
            // Ignore; fallback check below handles empty key
          }
        }
      }
      if (warpPrivateKey.trim()) {
        uciObj.set(
          TACHYON_UCI_PACKAGE,
          srcId,
          'warp_private_key',
          warpPrivateKey.trim(),
        );
      }
      if (warpPeerPublicKey.trim()) {
        uciObj.set(
          TACHYON_UCI_PACKAGE,
          srcId,
          'warp_peer_public_key',
          warpPeerPublicKey.trim(),
        );
      }
      if (warpLocalAddress.trim()) {
        uciObj.set(
          TACHYON_UCI_PACKAGE,
          srcId,
          'warp_local_address',
          warpLocalAddress.trim(),
        );
      }
      if (warpIpv6.trim()) {
        uciObj.set(TACHYON_UCI_PACKAGE, srcId, 'warp_ipv6', warpIpv6.trim());
      }
      if (warpServer.trim()) {
        uciObj.set(
          TACHYON_UCI_PACKAGE,
          srcId,
          'warp_server',
          warpServer.trim(),
        );
      }
      if (warpServerPort.trim()) {
        uciObj.set(
          TACHYON_UCI_PACKAGE,
          srcId,
          'warp_server_port',
          warpServerPort.trim(),
        );
      }
      if (warpReserved.trim()) {
        uciObj.set(
          TACHYON_UCI_PACKAGE,
          srcId,
          'warp_reserved',
          warpReserved.trim(),
        );
      }
      if (warpMtu.trim()) {
        uciObj.set(TACHYON_UCI_PACKAGE, srcId, 'warp_mtu', warpMtu.trim());
      }
      if (warpFakePackets.trim()) {
        uciObj.set(
          TACHYON_UCI_PACKAGE,
          srcId,
          'warp_fake_packets',
          warpFakePackets.trim(),
        );
      }
      for (const [ak, av] of Object.entries(warpAwgOptions)) {
        if (av) {
          uciObj.set(TACHYON_UCI_PACKAGE, srcId, ak, av);
        }
      }
    } else if (outboundMethod === 'desync') {
      if (dpiEngineType === 'desync') {
        uciObj.set(
          TACHYON_UCI_PACKAGE,
          srcId,
          'desync_preset',
          desyncPresetKey || 'fake_split',
        );
        if (desyncPresetKey === 'custom' || desyncPresetKey === 'auto') {
          if (desyncPresetKey === 'custom') {
            uciObj.set(TACHYON_UCI_PACKAGE, srcId, 'desync_mode', desyncMode);
            uciObj.set(
              TACHYON_UCI_PACKAGE,
              srcId,
              'desync_split_pos',
              desyncSplitPos,
            );
          }
          if (desyncFakeTtl.trim()) {
            uciObj.set(
              TACHYON_UCI_PACKAGE,
              srcId,
              'desync_fake_ttl',
              desyncFakeTtl.trim(),
            );
          }
          if (desyncFakeSni.trim()) {
            uciObj.set(
              TACHYON_UCI_PACKAGE,
              srcId,
              'desync_fake_sni',
              desyncFakeSni.trim(),
            );
          }
          uciObj.set(
            TACHYON_UCI_PACKAGE,
            srcId,
            'desync_udp_fake',
            desyncUdpFake ? '1' : '0',
          );
          if (desyncPreset.trim()) {
            uciObj.set(
              TACHYON_UCI_PACKAGE,
              srcId,
              'desync_opts',
              desyncPreset.trim(),
            );
          }
        }
      } else if (dpiEngineType === 'zapret2') {
        uciObj.set(
          TACHYON_UCI_PACKAGE,
          srcId,
          'nfqws2_opt',
          nfqws2Opt.trim() || ZAPRET2_DEFAULT_NFQWS2_OPT,
        );
        uciObj.set(
          TACHYON_UCI_PACKAGE,
          srcId,
          'direct_nfqws',
          directNfqws ? '1' : '0',
        );
      } else if (dpiEngineType === 'zapret') {
        uciObj.set(
          TACHYON_UCI_PACKAGE,
          srcId,
          'nfqws_opt',
          nfqwsOpt.trim() || ZAPRET_DEFAULT_NFQWS_OPT,
        );
        uciObj.set(
          TACHYON_UCI_PACKAGE,
          srcId,
          'direct_nfqws',
          directNfqws ? '1' : '0',
        );
      } else if (dpiEngineType === 'byedpi') {
        uciObj.set(
          TACHYON_UCI_PACKAGE,
          srcId,
          'byedpi_cmd_opts',
          byedpiCmdOpts.trim() || BYEDPI_DEFAULT_CMD_OPTS,
        );
      }
    } else if (outboundMethod === 'fptn') {
      uciObj.set(TACHYON_UCI_PACKAGE, srcId, 'access_token', fptnToken.trim());
      uciObj.set(
        TACHYON_UCI_PACKAGE,
        srcId,
        'bypass_method',
        fptnBypassMethod || 'obfuscation',
      );
      if (fptnSni.trim()) {
        uciObj.set(TACHYON_UCI_PACKAGE, srcId, 'sni', fptnSni.trim());
      }
      if (fptnPreferredServer.trim()) {
        uciObj.set(
          TACHYON_UCI_PACKAGE,
          srcId,
          'preferred_server',
          fptnPreferredServer.trim(),
        );
      }
    } else if (outboundMethod === 'custom_proto') {
      if (customProto === 'interface' || customProto === 'tailscale') {
        const iface =
          customInterface.trim() ||
          (customProto === 'tailscale' ? 'tailscale0' : 'wg0');
        uciObj.set(TACHYON_UCI_PACKAGE, srcId, 'interface_name', iface);
        uciObj.set(TACHYON_UCI_PACKAGE, srcId, 'interface', iface);
      } else if (customProto === 'tor') {
        uciObj.set(
          TACHYON_UCI_PACKAGE,
          srcId,
          'tor_socks_port',
          torSocksPort.trim() || '9050',
        );
      } else if (customProto === 'outbound_json') {
        if (outboundJsonText.trim()) {
          uciObj.set(TACHYON_UCI_PACKAGE, srcId, 'outbound_jsons', [
            outboundJsonText.trim(),
          ]);
        }
      } else if (customProto === 'openvpn') {
        if (openvpnConfig.trim()) {
          uciObj.set(
            TACHYON_UCI_PACKAGE,
            srcId,
            'openvpn_config',
            openvpnConfig.trim(),
          );
        }
        if (customHost.trim()) {
          uciObj.set(
            TACHYON_UCI_PACKAGE,
            srcId,
            'openvpn_server',
            customHost.trim(),
          );
          uciObj.set(TACHYON_UCI_PACKAGE, srcId, 'server', customHost.trim());
        }
        if (customPort.trim()) {
          uciObj.set(
            TACHYON_UCI_PACKAGE,
            srcId,
            'openvpn_server_port',
            customPort.trim(),
          );
          uciObj.set(
            TACHYON_UCI_PACKAGE,
            srcId,
            'server_port',
            customPort.trim(),
          );
        }
        uciObj.set(
          TACHYON_UCI_PACKAGE,
          srcId,
          'openvpn_proto',
          openvpnProto || 'udp',
        );
        if (openvpnCipher.trim()) {
          uciObj.set(
            TACHYON_UCI_PACKAGE,
            srcId,
            'openvpn_cipher',
            openvpnCipher.trim(),
          );
        }
        if (customUsername.trim()) {
          uciObj.set(
            TACHYON_UCI_PACKAGE,
            srcId,
            'openvpn_username',
            customUsername.trim(),
          );
          uciObj.set(
            TACHYON_UCI_PACKAGE,
            srcId,
            'username',
            customUsername.trim(),
          );
        }
        if (customPassword.trim()) {
          uciObj.set(
            TACHYON_UCI_PACKAGE,
            srcId,
            'openvpn_password',
            customPassword.trim(),
          );
          uciObj.set(
            TACHYON_UCI_PACKAGE,
            srcId,
            'password',
            customPassword.trim(),
          );
        }
      } else {
        if (customHost.trim()) {
          uciObj.set(
            TACHYON_UCI_PACKAGE,
            srcId,
            `${customProto}_server`,
            customHost.trim(),
          );
          uciObj.set(TACHYON_UCI_PACKAGE, srcId, 'server', customHost.trim());
        }
        if (customPort.trim()) {
          uciObj.set(
            TACHYON_UCI_PACKAGE,
            srcId,
            `${customProto}_port`,
            customPort.trim(),
          );
          uciObj.set(
            TACHYON_UCI_PACKAGE,
            srcId,
            'server_port',
            customPort.trim(),
          );
        }
        if (customUsername.trim()) {
          uciObj.set(
            TACHYON_UCI_PACKAGE,
            srcId,
            `${customProto}_username`,
            customUsername.trim(),
          );
          uciObj.set(
            TACHYON_UCI_PACKAGE,
            srcId,
            'username',
            customUsername.trim(),
          );
        }
        if (customPassword.trim()) {
          uciObj.set(
            TACHYON_UCI_PACKAGE,
            srcId,
            `${customProto}_password`,
            customPassword.trim(),
          );
          uciObj.set(
            TACHYON_UCI_PACKAGE,
            srcId,
            'password',
            customPassword.trim(),
          );
        }
        if (customSni.trim()) {
          uciObj.set(TACHYON_UCI_PACKAGE, srcId, 'sni', customSni.trim());
        }
        if (customInsecure) {
          uciObj.set(TACHYON_UCI_PACKAGE, srcId, 'insecure', '1');
        }

        if (customProto === 'anytls') {
          const alpnList = anytlsAlpn
            .split(',')
            .map((a) => a.trim())
            .filter(Boolean);
          if (alpnList.length > 0) {
            uciObj.set(TACHYON_UCI_PACKAGE, srcId, 'anytls_alpn', alpnList);
          }
          if (anytlsIdleInterval.trim()) {
            uciObj.set(
              TACHYON_UCI_PACKAGE,
              srcId,
              'anytls_idle_session_check_interval',
              anytlsIdleInterval.trim(),
            );
          }
          if (anytlsIdleTimeout.trim()) {
            uciObj.set(
              TACHYON_UCI_PACKAGE,
              srcId,
              'anytls_idle_session_timeout',
              anytlsIdleTimeout.trim(),
            );
          }
          if (anytlsMinIdle.trim()) {
            uciObj.set(
              TACHYON_UCI_PACKAGE,
              srcId,
              'anytls_min_idle_session',
              anytlsMinIdle.trim(),
            );
          }
        } else if (customProto === 'naive') {
          uciObj.set(
            TACHYON_UCI_PACKAGE,
            srcId,
            'naive_quic',
            naiveQuic ? '1' : '0',
          );
          if (naiveCongestion) {
            uciObj.set(
              TACHYON_UCI_PACKAGE,
              srcId,
              'naive_quic_congestion_control',
              naiveCongestion,
            );
          }
          if (naiveConcurrency.trim()) {
            uciObj.set(
              TACHYON_UCI_PACKAGE,
              srcId,
              'naive_insecure_concurrency',
              naiveConcurrency.trim(),
            );
          }
          uciObj.set(
            TACHYON_UCI_PACKAGE,
            srcId,
            'naive_udp_over_tcp',
            naiveUot ? '1' : '0',
          );
          if (naiveExtraHeaders.trim()) {
            uciObj.set(
              TACHYON_UCI_PACKAGE,
              srcId,
              'naive_extra_headers',
              naiveExtraHeaders.trim(),
            );
          }
        } else if (customProto === 'mieru') {
          uciObj.set(
            TACHYON_UCI_PACKAGE,
            srcId,
            'mieru_transport',
            mieruTransport || 'TCP',
          );
          if (mieruMultiplexing) {
            uciObj.set(
              TACHYON_UCI_PACKAGE,
              srcId,
              'mieru_multiplexing',
              mieruMultiplexing,
            );
          }
          if (mieruHandshake) {
            uciObj.set(
              TACHYON_UCI_PACKAGE,
              srcId,
              'mieru_handshake_mode',
              mieruHandshake,
            );
          }
        } else if (customProto === 'snell') {
          uciObj.set(
            TACHYON_UCI_PACKAGE,
            srcId,
            'snell_version',
            snellVersion || '4',
          );
          if (snellObfs) {
            uciObj.set(TACHYON_UCI_PACKAGE, srcId, 'snell_obfs', snellObfs);
          }
          if (snellObfsHost.trim()) {
            uciObj.set(
              TACHYON_UCI_PACKAGE,
              srcId,
              'snell_obfs_host',
              snellObfsHost.trim(),
            );
          }
          uciObj.set(
            TACHYON_UCI_PACKAGE,
            srcId,
            'snell_uot',
            snellUot ? '1' : '0',
          );
        } else if (customProto === 'sudoku') {
          uciObj.set(
            TACHYON_UCI_PACKAGE,
            srcId,
            'sudoku_aead',
            sudokuAead || 'chacha20-poly1305',
          );
          uciObj.set(
            TACHYON_UCI_PACKAGE,
            srcId,
            'sudoku_ascii',
            sudokuAscii || 'prefer_entropy',
          );
          uciObj.set(
            TACHYON_UCI_PACKAGE,
            srcId,
            'sudoku_http_mask',
            sudokuHttpMask ? '1' : '0',
          );
          if (sudokuMaskHost.trim()) {
            uciObj.set(
              TACHYON_UCI_PACKAGE,
              srcId,
              'sudoku_http_mask_host',
              sudokuMaskHost.trim(),
            );
          }
        } else if (customProto === 'masque') {
          if (masquePublicKey.trim()) {
            uciObj.set(
              TACHYON_UCI_PACKAGE,
              srcId,
              'masque_public_key',
              masquePublicKey.trim(),
            );
          }
          if (masqueLocalAddr.trim()) {
            uciObj.set(
              TACHYON_UCI_PACKAGE,
              srcId,
              'masque_local_address',
              masqueLocalAddr.trim(),
            );
          }
          if (masqueIpv6.trim()) {
            uciObj.set(
              TACHYON_UCI_PACKAGE,
              srcId,
              'masque_ipv6',
              masqueIpv6.trim(),
            );
          }
          if (masqueUri.trim()) {
            uciObj.set(
              TACHYON_UCI_PACKAGE,
              srcId,
              'masque_uri',
              masqueUri.trim(),
            );
          }
          if (masqueMtu.trim()) {
            uciObj.set(
              TACHYON_UCI_PACKAGE,
              srcId,
              'masque_mtu',
              masqueMtu.trim(),
            );
          }
          uciObj.set(
            TACHYON_UCI_PACKAGE,
            srcId,
            'masque_vhttp',
            masqueVhttp ? '1' : '0',
          );
        } else if (customProto === 'trusttunnel') {
          uciObj.set(
            TACHYON_UCI_PACKAGE,
            srcId,
            'trusttunnel_quic',
            trusttunnelQuic ? '1' : '0',
          );
          uciObj.set(
            TACHYON_UCI_PACKAGE,
            srcId,
            'trusttunnel_health_check',
            trusttunnelHealthCheck ? '1' : '0',
          );
        } else if (customProto === 'tewfai') {
          const tList = tewfaiTransports
            .split(',')
            .map((t) => t.trim())
            .filter(Boolean);
          if (tList.length > 0) {
            uciObj.set(TACHYON_UCI_PACKAGE, srcId, 'tewfai_transport', tList);
          }
          if (tewfaiInnerCipher) {
            uciObj.set(
              TACHYON_UCI_PACKAGE,
              srcId,
              'tewfai_inner_cipher',
              tewfaiInnerCipher,
            );
          }
          if (tewfaiMorphProfile) {
            uciObj.set(
              TACHYON_UCI_PACKAGE,
              srcId,
              'tewfai_morph_profile',
              tewfaiMorphProfile,
            );
          }
        } else if (customProto === 'shadowtls') {
          uciObj.set(
            TACHYON_UCI_PACKAGE,
            srcId,
            'shadowtls_version',
            shadowtlsVersion || '3',
          );
        } else if (customProto === 'openconnect') {
          uciObj.set(
            TACHYON_UCI_PACKAGE,
            srcId,
            'openconnect_protocol',
            openconnectProtocol || 'anyconnect',
          );
          if (openconnectAuthgroup.trim()) {
            uciObj.set(
              TACHYON_UCI_PACKAGE,
              srcId,
              'openconnect_authgroup',
              openconnectAuthgroup.trim(),
            );
          }
          if (openconnectServercert.trim()) {
            uciObj.set(
              TACHYON_UCI_PACKAGE,
              srcId,
              'openconnect_servercert',
              openconnectServercert.trim(),
            );
          }
          uciObj.set(
            TACHYON_UCI_PACKAGE,
            srcId,
            'openconnect_no_dtls',
            openconnectNoDtls ? '1' : '0',
          );
        }
      }
    }

    if (targetMode === 'pool_only') {
      void persistAndFinish('outbound', srcId, finalName, applyImmediately);
      return;
    }

    // Create AdBlock section BEFORE main proxy section so it has higher priority in UCI order
    if (enableAdBlockSection) {
      const adLists = ['ads_hagezi_pro', 'win_spy'];
      const adSecId = 'AdBlock_Tachyon';
      const adCondId = 'cond_AdBlock_Tachyon';
      if (!uciObj.get(TACHYON_UCI_PACKAGE, adCondId)) {
        uciObj.add(TACHYON_UCI_PACKAGE, 'condition', adCondId);
      }
      uciObj.set(TACHYON_UCI_PACKAGE, adCondId, 'enabled', '1');
      uciObj.set(
        TACHYON_UCI_PACKAGE,
        adCondId,
        'name',
        tr('Реклама и телеметрия', 'Ads & Telemetry'),
      );
      uciObj.set(TACHYON_UCI_PACKAGE, adCondId, 'condition_type', 'atomic');
      uciObj.set(TACHYON_UCI_PACKAGE, adCondId, 'type', 'atomic');
      uciObj.set(TACHYON_UCI_PACKAGE, adCondId, 'community_lists', adLists);
      uciObj.set(TACHYON_UCI_PACKAGE, adCondId, 'domain_lists', adLists);

      if (!uciObj.get(TACHYON_UCI_PACKAGE, adSecId)) {
        uciObj.add(TACHYON_UCI_PACKAGE, 'section', adSecId);
      }
      uciObj.set(TACHYON_UCI_PACKAGE, adSecId, 'enabled', '1');
      uciObj.set(
        TACHYON_UCI_PACKAGE,
        adSecId,
        'name',
        tr('Блокировка рекламы', 'Ad Blocker'),
      );
      uciObj.set(
        TACHYON_UCI_PACKAGE,
        adSecId,
        'label',
        tr('Блокировка рекламы', 'Ad Blocker'),
      );
      uciObj.set(TACHYON_UCI_PACKAGE, adSecId, 'action', 'block');
      uciObj.set(TACHYON_UCI_PACKAGE, adSecId, 'community_lists', adLists);
      uciObj.set(TACHYON_UCI_PACKAGE, adSecId, 'condition_refs', [adCondId]);
    }

    // Create Direct Bypass + DNS sections for Games & RU services BEFORE main proxy section
    const customDirectDoms = directBypassCustomDomains
      .split(/[\s,]+/)
      .map((d) => d.trim())
      .filter(Boolean);
    const customDirectIps = directBypassSourceIps
      .split(/[\s,]+/)
      .map((d) => d.trim())
      .filter(Boolean);
    if (
      enableDirectGamesBypass &&
      (selectedDirectBypassLists.size > 0 ||
        customDirectDoms.length > 0 ||
        customDirectIps.length > 0)
    ) {
      const directLists = Array.from(selectedDirectBypassLists);
      const bypassSecId = 'Direct_Games_RU';
      const bypassCondId = 'cond_Direct_Games_RU';
      if (!uciObj.get(TACHYON_UCI_PACKAGE, bypassCondId)) {
        uciObj.add(TACHYON_UCI_PACKAGE, 'condition', bypassCondId);
      }
      uciObj.set(TACHYON_UCI_PACKAGE, bypassCondId, 'enabled', '1');
      uciObj.set(
        TACHYON_UCI_PACKAGE,
        bypassCondId,
        'name',
        tr('Игры и сервисы РФ (Прямой)', 'Games & RU Services (Direct)'),
      );
      uciObj.set(TACHYON_UCI_PACKAGE, bypassCondId, 'condition_type', 'atomic');
      uciObj.set(TACHYON_UCI_PACKAGE, bypassCondId, 'type', 'atomic');
      if (directLists.length > 0) {
        uciObj.set(
          TACHYON_UCI_PACKAGE,
          bypassCondId,
          'community_lists',
          directLists,
        );
        uciObj.set(
          TACHYON_UCI_PACKAGE,
          bypassCondId,
          'domain_lists',
          directLists,
        );
      }
      if (customDirectDoms.length > 0) {
        uciObj.set(
          TACHYON_UCI_PACKAGE,
          bypassCondId,
          'domain_suffix',
          customDirectDoms,
        );
        uciObj.set(
          TACHYON_UCI_PACKAGE,
          bypassCondId,
          'domain_suffix_text',
          customDirectDoms.join('\n'),
        );
        uciObj.set(
          TACHYON_UCI_PACKAGE,
          bypassCondId,
          'domains',
          customDirectDoms,
        );
      }
      if (customDirectIps.length > 0) {
        uciObj.set(
          TACHYON_UCI_PACKAGE,
          bypassCondId,
          'source_ip_cidr',
          customDirectIps,
        );
      }

      const dnsResolver = DIRECT_BYPASS_DNS_PRESETS.find(
        (r) => r.id === directBypassDnsPreset,
      );
      const resolvedDnsType = dnsResolver?.dnsType || 'udp';
      const customDirectDnsList = customDirectBypassDnsServer
        .split(/[\s,]+/)
        .map((s) => s.trim())
        .filter(Boolean);
      const resolvedDnsServer =
        directBypassDnsPreset === 'custom'
          ? customDirectDnsList.length > 1
            ? customDirectDnsList
            : customDirectDnsList[0] || '77.88.8.8'
          : dnsResolver?.servers && dnsResolver.servers.length > 1
            ? dnsResolver.servers
            : dnsResolver?.servers?.[0] || '77.88.8.8';

      if (
        directLists.length > 0 ||
        customDirectDoms.length > 0 ||
        customDirectIps.length > 0
      ) {
        const dnsSecId = 'Direct_Games_DNS';
        if (!uciObj.get(TACHYON_UCI_PACKAGE, dnsSecId)) {
          uciObj.add(TACHYON_UCI_PACKAGE, 'section', dnsSecId);
        }
        uciObj.set(TACHYON_UCI_PACKAGE, dnsSecId, 'enabled', '1');
        uciObj.set(
          TACHYON_UCI_PACKAGE,
          dnsSecId,
          'name',
          tr('DNS для Игр и РФ', 'DNS for Games & RU'),
        );
        uciObj.set(
          TACHYON_UCI_PACKAGE,
          dnsSecId,
          'label',
          tr('DNS для Игр и РФ', 'DNS for Games & RU'),
        );
        uciObj.set(TACHYON_UCI_PACKAGE, dnsSecId, 'action', 'dns');
        uciObj.set(TACHYON_UCI_PACKAGE, dnsSecId, 'dns_type', resolvedDnsType);
        uciObj.set(
          TACHYON_UCI_PACKAGE,
          dnsSecId,
          'dns_server',
          resolvedDnsServer,
        );
        if (directLists.length > 0) {
          uciObj.set(
            TACHYON_UCI_PACKAGE,
            dnsSecId,
            'community_lists',
            directLists,
          );
        }
        if (
          customDirectIps.length > 0 &&
          directLists.length === 0 &&
          customDirectDoms.length === 0
        ) {
          uciObj.set(
            TACHYON_UCI_PACKAGE,
            dnsSecId,
            'fully_routed_ips',
            customDirectIps,
          );
        }
        uciObj.set(TACHYON_UCI_PACKAGE, dnsSecId, 'condition_refs', [
          bypassCondId,
        ]);
      }

      if (!uciObj.get(TACHYON_UCI_PACKAGE, bypassSecId)) {
        uciObj.add(TACHYON_UCI_PACKAGE, 'section', bypassSecId);
      }
      uciObj.set(TACHYON_UCI_PACKAGE, bypassSecId, 'enabled', '1');
      uciObj.set(
        TACHYON_UCI_PACKAGE,
        bypassSecId,
        'name',
        tr('Игры и РФ напрямую', 'Games & RU Direct'),
      );
      uciObj.set(
        TACHYON_UCI_PACKAGE,
        bypassSecId,
        'label',
        tr('Игры и РФ напрямую', 'Games & RU Direct'),
      );
      uciObj.set(TACHYON_UCI_PACKAGE, bypassSecId, 'action', 'bypass');
      if (directLists.length > 0) {
        uciObj.set(
          TACHYON_UCI_PACKAGE,
          bypassSecId,
          'community_lists',
          directLists,
        );
      }
      uciObj.set(TACHYON_UCI_PACKAGE, bypassSecId, 'condition_refs', [
        bypassCondId,
      ]);
    }

    // Determine target section
    let secId = targetExistingSection;
    const isCreatingNewSection = targetMode === 'new' || !secId;
    const rawSecTitle = isCreatingNewSection
      ? newSectionName.trim() || finalName || 'Main'
      : uciObj.get(TACHYON_UCI_PACKAGE, secId, 'name') ||
        uciObj.get(TACHYON_UCI_PACKAGE, secId, 'label') ||
        secId;

    if (isCreatingNewSection) {
      secId = sanitizeId(rawSecTitle, 'sec').replace(/^sec_/, '');
      if (uciObj.get(TACHYON_UCI_PACKAGE, secId)) {
        secId = sanitizeId(rawSecTitle, 'sec');
      }
      uciObj.add(TACHYON_UCI_PACKAGE, 'section', secId);
      uciObj.set(TACHYON_UCI_PACKAGE, secId, 'enabled', '1');
      uciObj.set(TACHYON_UCI_PACKAGE, secId, 'name', rawSecTitle);
      uciObj.set(TACHYON_UCI_PACKAGE, secId, 'label', rawSecTitle);
      uciObj.set(TACHYON_UCI_PACKAGE, secId, 'action', 'connection');
    }

    // Create condition if creating a new section OR appending rules to an existing section
    if (isCreatingNewSection || appendPresetsToExisting) {
      const domainLists: string[] = [];
      for (const preset of TRAFFIC_PRESETS) {
        if (selectedPresets.has(preset.id)) {
          domainLists.push(...preset.domains);
        }
      }
      for (const listKey of selectedIndividualLists) {
        if (listKey && !domainLists.includes(listKey)) {
          domainLists.push(listKey);
        }
      }
      const customDoms = customDomainsText
        .split(/[\s,]+/)
        .map((d) => d.trim())
        .filter(Boolean);

      if (domainLists.length > 0 || customDoms.length > 0) {
        const condId = sanitizeId(rawSecTitle, 'cond');
        const uniqueLists = Array.from(new Set(domainLists));
        uciObj.add(TACHYON_UCI_PACKAGE, 'condition', condId);
        uciObj.set(TACHYON_UCI_PACKAGE, condId, 'enabled', '1');
        uciObj.set(TACHYON_UCI_PACKAGE, condId, 'name', `${rawSecTitle} Rules`);
        uciObj.set(TACHYON_UCI_PACKAGE, condId, 'condition_type', 'atomic');
        uciObj.set(TACHYON_UCI_PACKAGE, condId, 'type', 'atomic');
        if (uniqueLists.length > 0) {
          uciObj.set(
            TACHYON_UCI_PACKAGE,
            condId,
            'community_lists',
            uniqueLists,
          );
          uciObj.set(TACHYON_UCI_PACKAGE, condId, 'domain_lists', uniqueLists);
        }
        if (customDoms.length > 0) {
          uciObj.set(TACHYON_UCI_PACKAGE, condId, 'domain_suffix', customDoms);
          uciObj.set(
            TACHYON_UCI_PACKAGE,
            condId,
            'domain_suffix_text',
            customDoms.join('\n'),
          );
          uciObj.set(TACHYON_UCI_PACKAGE, condId, 'domains', customDoms);
        }
        const curCondsRaw = uciObj.get(
          TACHYON_UCI_PACKAGE,
          secId,
          'condition_refs',
        );
        const curConds = Array.isArray(curCondsRaw)
          ? curCondsRaw
          : curCondsRaw
            ? String(curCondsRaw).split(/\s+/).filter(Boolean)
            : [];
        if (!curConds.includes(condId)) {
          uciObj.set(TACHYON_UCI_PACKAGE, secId, 'condition_refs', [
            ...curConds,
            condId,
          ]);
        }
      }
    }

    // Apply Step 4 Global DNS settings if selected
    if (globalDnsPreset !== 'keep') {
      if (globalDnsPreset === 'autotune' && dnsBenchRecommendation) {
        uciObj.set(
          TACHYON_UCI_PACKAGE,
          'settings',
          'dns_type',
          dnsBenchRecommendation.dns_type || 'doh',
        );
        if (
          Array.isArray(dnsBenchRecommendation.dns_server) &&
          dnsBenchRecommendation.dns_server.length > 0
        ) {
          uciObj.set(
            TACHYON_UCI_PACKAGE,
            'settings',
            'dns_server',
            dnsBenchRecommendation.dns_server,
          );
        }
        if (
          Array.isArray(dnsBenchRecommendation.bootstrap_dns_server) &&
          dnsBenchRecommendation.bootstrap_dns_server.length > 0
        ) {
          uciObj.set(
            TACHYON_UCI_PACKAGE,
            'settings',
            'bootstrap_dns_server',
            dnsBenchRecommendation.bootstrap_dns_server,
          );
        }
        if (
          Array.isArray(dnsBenchRecommendation.dns_fallback_server) &&
          dnsBenchRecommendation.dns_fallback_server.length > 0
        ) {
          uciObj.set(
            TACHYON_UCI_PACKAGE,
            'settings',
            'dns_fallback_server',
            dnsBenchRecommendation.dns_fallback_server,
          );
        }
        if (dnsBenchRecommendation.dns_upstream_mode) {
          uciObj.set(
            TACHYON_UCI_PACKAGE,
            'settings',
            'dns_upstream_mode',
            dnsBenchRecommendation.dns_upstream_mode,
          );
        }
      } else if (globalDnsPreset === 'custom') {
        uciObj.set(
          TACHYON_UCI_PACKAGE,
          'settings',
          'dns_type',
          customGlobalDnsType,
        );
        const customGlobalServers = customGlobalDnsServer
          .split(/[\s,]+/)
          .map((s) => s.trim())
          .filter(Boolean);
        uciObj.set(
          TACHYON_UCI_PACKAGE,
          'settings',
          'dns_server',
          customGlobalServers.length > 1
            ? customGlobalServers
            : customGlobalServers[0] || '77.88.8.8',
        );
      } else {
        const preset = WIZARD_GLOBAL_DNS_PRESETS.find(
          (p) => p.id === globalDnsPreset,
        );
        if (preset && preset.dnsType && preset.servers.length > 0) {
          uciObj.set(
            TACHYON_UCI_PACKAGE,
            'settings',
            'dns_type',
            preset.dnsType,
          );
          uciObj.set(
            TACHYON_UCI_PACKAGE,
            'settings',
            'dns_server',
            preset.servers.length === 1 ? preset.servers[0] : preset.servers,
          );
          if (preset.bootstrap && preset.bootstrap.length > 0) {
            uciObj.set(
              TACHYON_UCI_PACKAGE,
              'settings',
              'bootstrap_dns_server',
              preset.bootstrap,
            );
          }
        }
      }
      if (enableDnsDetour && secId) {
        uciObj.set(TACHYON_UCI_PACKAGE, 'settings', 'dns_detour_enabled', '1');
        uciObj.set(
          TACHYON_UCI_PACKAGE,
          'settings',
          'dns_detour_section',
          secId,
        );
      }
    }

    // Link outbound_source to target section
    const curSourcesRaw = uciObj.get(
      TACHYON_UCI_PACKAGE,
      secId,
      'outbound_source_refs',
    );
    const curSources = Array.isArray(curSourcesRaw)
      ? curSourcesRaw
      : curSourcesRaw
        ? String(curSourcesRaw).split(/\s+/).filter(Boolean)
        : [];
    if (!curSources.includes(srcId)) {
      uciObj.set(TACHYON_UCI_PACKAGE, secId, 'outbound_source_refs', [
        ...curSources,
        srcId,
      ]);
    }

    // Create URLTest balancer if requested
    const canUseUrlTest =
      outboundMethod === 'subscription' ||
      outboundMethod === 'proxy_links' ||
      outboundMethod === 'amnezia_config';
    if (canUseUrlTest && enableAutoUrlTest) {
      const curBalsRaw = uciObj.get(
        TACHYON_UCI_PACKAGE,
        secId,
        'balancer_refs',
      );
      const curBals = Array.isArray(curBalsRaw)
        ? curBalsRaw
        : curBalsRaw
          ? String(curBalsRaw).split(/\s+/).filter(Boolean)
          : [];
      if (curBals.length === 0) {
        const balId = sanitizeId(secId, 'bal_auto');
        uciObj.add(TACHYON_UCI_PACKAGE, 'balancer', balId);
        uciObj.set(TACHYON_UCI_PACKAGE, balId, 'enabled', '1');
        uciObj.set(TACHYON_UCI_PACKAGE, balId, 'balancer_type', 'urltest');
        uciObj.set(
          TACHYON_UCI_PACKAGE,
          balId,
          'name',
          `${finalName} (URLTest)`,
        );
        uciObj.set(
          TACHYON_UCI_PACKAGE,
          balId,
          'testing_url',
          'https://www.gstatic.com/generate_204',
        );
        uciObj.set(TACHYON_UCI_PACKAGE, balId, 'check_interval', '3m');
        uciObj.set(TACHYON_UCI_PACKAGE, balId, 'tolerance', '50');
        uciObj.set(TACHYON_UCI_PACKAGE, balId, 'idle_timeout', '30m');
        uciObj.set(TACHYON_UCI_PACKAGE, secId, 'balancer_refs', [balId]);
      } else {
        for (const existingBalId of curBals) {
          const balSrcRefsRaw = uciObj.get(
            TACHYON_UCI_PACKAGE,
            existingBalId,
            'source_refs',
          );
          const balSrcRefs = Array.isArray(balSrcRefsRaw)
            ? balSrcRefsRaw
            : balSrcRefsRaw
              ? String(balSrcRefsRaw).split(/\s+/).filter(Boolean)
              : [];
          if (balSrcRefs.length > 0 && !balSrcRefs.includes(srcId)) {
            uciObj.set(TACHYON_UCI_PACKAGE, existingBalId, 'source_refs', [
              ...balSrcRefs,
              srcId,
            ]);
          }
        }
      }
    } else if (outboundMethod !== 'desync') {
      const curBalsRaw = uciObj.get(
        TACHYON_UCI_PACKAGE,
        secId,
        'balancer_refs',
      );
      const curBals = Array.isArray(curBalsRaw)
        ? curBalsRaw
        : curBalsRaw
          ? String(curBalsRaw).split(/\s+/).filter(Boolean)
          : [];
      for (const existingBalId of curBals) {
        const balSrcRefsRaw = uciObj.get(
          TACHYON_UCI_PACKAGE,
          existingBalId,
          'source_refs',
        );
        const balSrcRefs = Array.isArray(balSrcRefsRaw)
          ? balSrcRefsRaw
          : balSrcRefsRaw
            ? String(balSrcRefsRaw).split(/\s+/).filter(Boolean)
            : [];
        if (balSrcRefs.length > 0 && !balSrcRefs.includes(srcId)) {
          uciObj.set(TACHYON_UCI_PACKAGE, existingBalId, 'source_refs', [
            ...balSrcRefs,
            srcId,
          ]);
        }
      }
    }

    void persistAndFinish('outbound', secId, finalName, applyImmediately);
  }

  async function finishInboundWizard(applyImmediately = false) {
    const label = inboundName.trim() || `Tachyon ${inboundProto.toUpperCase()}`;
    const srvId = sanitizeId(label, 'srv');
    const certPath = `/etc/tachyon/server-certs/${srvId}.crt`;
    const keyPath = `/etc/tachyon/server-certs/${srvId}.key`;
    const defaultTlsSni =
      (typeof window !== 'undefined' &&
      window.location?.hostname &&
      !/^[0-9.]+$/.test(window.location.hostname) &&
      window.location.hostname !== 'localhost'
        ? window.location.hostname
        : '') || 'tachyon.lan';

    uciObj.add(TACHYON_UCI_PACKAGE, 'server', srvId);
    uciObj.set(TACHYON_UCI_PACKAGE, srvId, 'enabled', '1');
    uciObj.set(TACHYON_UCI_PACKAGE, srvId, 'label', label);
    uciObj.set(TACHYON_UCI_PACKAGE, srvId, 'protocol', inboundProto);
    uciObj.set(TACHYON_UCI_PACKAGE, srvId, 'listen', '0.0.0.0');
    uciObj.set(
      TACHYON_UCI_PACKAGE,
      srvId,
      'listen_port',
      inboundPort.trim() || '443',
    );
    uciObj.set(
      TACHYON_UCI_PACKAGE,
      srvId,
      'server_country',
      inboundCountry.trim() || 'RU',
    );
    uciObj.set(
      TACHYON_UCI_PACKAGE,
      srvId,
      'open_firewall_port',
      inboundOpenFirewall ? '1' : '0',
    );
    uciObj.set(TACHYON_UCI_PACKAGE, srvId, 'routing_mode', inboundRoutingMode);

    let needsTlsCert = false;

    if (inboundProto === 'vless') {
      const sni = inboundSni.trim() || 'www.microsoft.com';
      uciObj.set(TACHYON_UCI_PACKAGE, srvId, 'security', 'reality');
      uciObj.set(TACHYON_UCI_PACKAGE, srvId, 'transport', 'tcp');
      uciObj.set(TACHYON_UCI_PACKAGE, srvId, 'vless_flow', 'xtls-rprx-vision');
      uciObj.set(TACHYON_UCI_PACKAGE, srvId, 'server_uuid', generateUuidV4());
      uciObj.set(TACHYON_UCI_PACKAGE, srvId, 'tls_server_name', sni);
      uciObj.set(TACHYON_UCI_PACKAGE, srvId, 'reality_handshake_server', sni);
      uciObj.set(
        TACHYON_UCI_PACKAGE,
        srvId,
        'reality_handshake_server_port',
        '443',
      );
      uciObj.set(
        TACHYON_UCI_PACKAGE,
        srvId,
        'reality_short_id',
        generateRandomHex(4),
      );
      uciObj.set(
        TACHYON_UCI_PACKAGE,
        srvId,
        'reality_max_time_difference',
        '1m',
      );
      uciObj.set(TACHYON_UCI_PACKAGE, srvId, 'client_fingerprint', 'chrome');
      try {
        const res = await executeShellCommand({
          command: '/usr/bin/tachyon',
          args: ['generate_reality_keypair'],
        });
        if (res.stdout) {
          const parsed = JSON.parse(res.stdout);
          if (parsed?.private_key && parsed?.public_key) {
            uciObj.set(
              TACHYON_UCI_PACKAGE,
              srvId,
              'reality_private_key',
              parsed.private_key,
            );
            uciObj.set(
              TACHYON_UCI_PACKAGE,
              srvId,
              'reality_public_key',
              parsed.public_key,
            );
          }
        }
      } catch {
        // Fallback if shell is unavailable in test environment
      }
    } else if (inboundProto === 'awg') {
      const serverSections =
        uciObj.sections(TACHYON_UCI_PACKAGE, 'server') || [];
      const usedSubnets = new Set<string>();
      for (const s of serverSections) {
        if (s['.name'] === srvId) continue;
        const la = uciObj.get(
          TACHYON_UCI_PACKAGE,
          s['.name'],
          'awg_local_address',
        );
        if (la) usedSubnets.add(String(la));
      }
      let localAddr = '10.8.0.1/24';
      let cliAddr = '10.8.0.2/32';
      let dnsAddr = '10.8.0.1';
      if (usedSubnets.has(localAddr)) {
        for (let idx = 1; idx < 100; idx++) {
          const candidate = `10.8.${idx}.1/24`;
          if (!usedSubnets.has(candidate)) {
            localAddr = candidate;
            cliAddr = `10.8.${idx}.2/32`;
            dnsAddr = `10.8.${idx}.1`;
            break;
          }
        }
      }
      uciObj.set(TACHYON_UCI_PACKAGE, srvId, 'awg_local_address', localAddr);
      uciObj.set(TACHYON_UCI_PACKAGE, srvId, 'awg_client_address', cliAddr);
      uciObj.set(TACHYON_UCI_PACKAGE, srvId, 'awg_dns', dnsAddr);
      uciObj.set(TACHYON_UCI_PACKAGE, srvId, 'awg_mtu', '1280');
      uciObj.set(TACHYON_UCI_PACKAGE, srvId, 'awg_keepalive', '25');
      uciObj.set(TACHYON_UCI_PACKAGE, srvId, 'awg_version', '2.0');
      uciObj.set(
        TACHYON_UCI_PACKAGE,
        srvId,
        'awg_preshared_key',
        generateBase64Key(32),
      );
      uciObj.set(
        TACHYON_UCI_PACKAGE,
        srvId,
        'awg_jc',
        String(randomIntInRange(4, 7)),
      );
      uciObj.set(TACHYON_UCI_PACKAGE, srvId, 'awg_jmin', '40');
      uciObj.set(TACHYON_UCI_PACKAGE, srvId, 'awg_jmax', '70');
      uciObj.set(
        TACHYON_UCI_PACKAGE,
        srvId,
        'awg_s1',
        String(randomIntInRange(15, 45)),
      );
      uciObj.set(
        TACHYON_UCI_PACKAGE,
        srvId,
        'awg_s2',
        String(randomIntInRange(15, 45)),
      );
      uciObj.set(TACHYON_UCI_PACKAGE, srvId, 'awg_s3', '0');
      uciObj.set(TACHYON_UCI_PACKAGE, srvId, 'awg_s4', '0');
      uciObj.set(
        TACHYON_UCI_PACKAGE,
        srvId,
        'awg_h1',
        String(randomIntInRange(100000000, 500000000)),
      );
      uciObj.set(
        TACHYON_UCI_PACKAGE,
        srvId,
        'awg_h2',
        String(randomIntInRange(500000001, 900000000)),
      );
      uciObj.set(
        TACHYON_UCI_PACKAGE,
        srvId,
        'awg_h3',
        String(randomIntInRange(900000001, 1400000000)),
      );
      uciObj.set(
        TACHYON_UCI_PACKAGE,
        srvId,
        'awg_h4',
        String(randomIntInRange(1400000001, 2000000000)),
      );
      const parseWgKeypair = (stdout: string) => {
        const matchPriv = stdout.match(/PrivateKey:\s*([^\s]+)/);
        const matchPub = stdout.match(/PublicKey:\s*([^\s]+)/);
        if (matchPriv && matchPub) {
          return { private_key: matchPriv[1], public_key: matchPub[1] };
        }
        return null;
      };
      try {
        const [srvRes, cliRes] = await Promise.all([
          executeShellCommand({
            command: '/usr/bin/tachyon',
            args: ['generate_wg_keypair'],
          }),
          executeShellCommand({
            command: '/usr/bin/tachyon',
            args: ['generate_wg_keypair'],
          }),
        ]);
        const srvPair = parseWgKeypair(srvRes.stdout || '');
        const cliPair = parseWgKeypair(cliRes.stdout || '');
        if (srvPair) {
          uciObj.set(
            TACHYON_UCI_PACKAGE,
            srvId,
            'awg_private_key',
            srvPair.private_key,
          );
          uciObj.set(
            TACHYON_UCI_PACKAGE,
            srvId,
            'awg_server_public_key',
            srvPair.public_key,
          );
        }
        if (cliPair) {
          uciObj.set(
            TACHYON_UCI_PACKAGE,
            srvId,
            'awg_client_private_key',
            cliPair.private_key,
          );
          uciObj.set(
            TACHYON_UCI_PACKAGE,
            srvId,
            'awg_peer_public_key',
            cliPair.public_key,
          );
        }
      } catch {
        // Fallback if shell is unavailable in test environment
      }
    } else if (inboundProto === 'hysteria2') {
      uciObj.set(TACHYON_UCI_PACKAGE, srvId, 'security', 'tls');
      uciObj.set(
        TACHYON_UCI_PACKAGE,
        srvId,
        'server_password',
        generateRandomHex(12),
      );
      uciObj.set(
        TACHYON_UCI_PACKAGE,
        srvId,
        'hysteria2_obfs_type',
        'salamander',
      );
      uciObj.set(
        TACHYON_UCI_PACKAGE,
        srvId,
        'hysteria2_obfs_password',
        generateRandomHex(12),
      );
      uciObj.set(TACHYON_UCI_PACKAGE, srvId, 'tls_server_name', defaultTlsSni);
      uciObj.set(TACHYON_UCI_PACKAGE, srvId, 'tls_alpn', ['h3']);
      uciObj.set(TACHYON_UCI_PACKAGE, srvId, 'tls_certificate_path', certPath);
      uciObj.set(TACHYON_UCI_PACKAGE, srvId, 'tls_key_path', keyPath);
      needsTlsCert = true;
    } else if (inboundProto === 'tuic') {
      uciObj.set(TACHYON_UCI_PACKAGE, srvId, 'security', 'tls');
      uciObj.set(TACHYON_UCI_PACKAGE, srvId, 'server_uuid', generateUuidV4());
      uciObj.set(
        TACHYON_UCI_PACKAGE,
        srvId,
        'server_password',
        generateRandomHex(12),
      );
      uciObj.set(TACHYON_UCI_PACKAGE, srvId, 'tuic_congestion_control', 'bbr');
      uciObj.set(TACHYON_UCI_PACKAGE, srvId, 'tls_server_name', defaultTlsSni);
      uciObj.set(TACHYON_UCI_PACKAGE, srvId, 'tls_alpn', ['h3']);
      uciObj.set(TACHYON_UCI_PACKAGE, srvId, 'tls_certificate_path', certPath);
      uciObj.set(TACHYON_UCI_PACKAGE, srvId, 'tls_key_path', keyPath);
      needsTlsCert = true;
    } else if (inboundProto === 'tewfai') {
      uciObj.set(TACHYON_UCI_PACKAGE, srvId, 'security', 'tls');
      uciObj.set(TACHYON_UCI_PACKAGE, srvId, 'tewfai_uuid', generateUuidV4());
      uciObj.set(
        TACHYON_UCI_PACKAGE,
        srvId,
        'tewfai_password',
        generateRandomHex(12),
      );
      uciObj.set(TACHYON_UCI_PACKAGE, srvId, 'tewfai_inbound_transport', 'tcp');
      uciObj.set(
        TACHYON_UCI_PACKAGE,
        srvId,
        'tewfai_inner_cipher',
        'aes-256-gcm',
      );
      uciObj.set(TACHYON_UCI_PACKAGE, srvId, 'tewfai_pqc_enabled', '1');
      uciObj.set(TACHYON_UCI_PACKAGE, srvId, 'tewfai_handover_enabled', '1');
      uciObj.set(TACHYON_UCI_PACKAGE, srvId, 'tewfai_fec_enabled', '0');
      uciObj.set(TACHYON_UCI_PACKAGE, srvId, 'tewfai_shaper_enabled', '1');
      uciObj.set(
        TACHYON_UCI_PACKAGE,
        srvId,
        'tewfai_shaper_profile',
        'adaptive',
      );
      uciObj.set(TACHYON_UCI_PACKAGE, srvId, 'tewfai_mtu', '1400');
      uciObj.set(TACHYON_UCI_PACKAGE, srvId, 'tls_server_name', defaultTlsSni);
      uciObj.set(TACHYON_UCI_PACKAGE, srvId, 'tls_alpn', ['h2', 'http/1.1']);
      uciObj.set(TACHYON_UCI_PACKAGE, srvId, 'tls_certificate_path', certPath);
      uciObj.set(TACHYON_UCI_PACKAGE, srvId, 'tls_key_path', keyPath);
      needsTlsCert = true;
    } else if (inboundProto === 'anytls') {
      uciObj.set(TACHYON_UCI_PACKAGE, srvId, 'security', 'tls');
      uciObj.set(
        TACHYON_UCI_PACKAGE,
        srvId,
        'server_password',
        generateRandomHex(12),
      );
      uciObj.set(TACHYON_UCI_PACKAGE, srvId, 'tls_server_name', defaultTlsSni);
      uciObj.set(TACHYON_UCI_PACKAGE, srvId, 'tls_certificate_path', certPath);
      uciObj.set(TACHYON_UCI_PACKAGE, srvId, 'tls_key_path', keyPath);
      needsTlsCert = true;
    } else if (inboundProto === 'trusttunnel') {
      uciObj.set(TACHYON_UCI_PACKAGE, srvId, 'security', 'tls');
      uciObj.set(TACHYON_UCI_PACKAGE, srvId, 'server_username', 'tachyon');
      uciObj.set(
        TACHYON_UCI_PACKAGE,
        srvId,
        'server_password',
        generateRandomHex(12),
      );
      uciObj.set(TACHYON_UCI_PACKAGE, srvId, 'trusttunnel_quic', '0');
      uciObj.set(TACHYON_UCI_PACKAGE, srvId, 'tls_server_name', defaultTlsSni);
      uciObj.set(TACHYON_UCI_PACKAGE, srvId, 'tls_alpn', ['h2', 'http/1.1']);
      uciObj.set(TACHYON_UCI_PACKAGE, srvId, 'tls_certificate_path', certPath);
      uciObj.set(TACHYON_UCI_PACKAGE, srvId, 'tls_key_path', keyPath);
      needsTlsCert = true;
    } else if (inboundProto === 'trojan') {
      uciObj.set(TACHYON_UCI_PACKAGE, srvId, 'security', 'tls');
      uciObj.set(TACHYON_UCI_PACKAGE, srvId, 'transport', 'tcp');
      uciObj.set(
        TACHYON_UCI_PACKAGE,
        srvId,
        'server_password',
        generateRandomHex(12),
      );
      uciObj.set(TACHYON_UCI_PACKAGE, srvId, 'tls_server_name', defaultTlsSni);
      uciObj.set(TACHYON_UCI_PACKAGE, srvId, 'tls_alpn', ['h2', 'http/1.1']);
      uciObj.set(TACHYON_UCI_PACKAGE, srvId, 'tls_certificate_path', certPath);
      uciObj.set(TACHYON_UCI_PACKAGE, srvId, 'tls_key_path', keyPath);
      needsTlsCert = true;
    } else if (inboundProto === 'shadowsocks') {
      uciObj.set(
        TACHYON_UCI_PACKAGE,
        srvId,
        'shadowsocks_method',
        'aes-128-gcm',
      );
      uciObj.set(
        TACHYON_UCI_PACKAGE,
        srvId,
        'server_password',
        generateBase64Key(16),
      );
    } else if (inboundProto === 'socks') {
      uciObj.set(TACHYON_UCI_PACKAGE, srvId, 'socks_auth_enabled', '1');
      uciObj.set(TACHYON_UCI_PACKAGE, srvId, 'server_username', 'tachyon');
      uciObj.set(
        TACHYON_UCI_PACKAGE,
        srvId,
        'server_password',
        generateRandomHex(12),
      );
    } else if (inboundProto === 'vmess') {
      uciObj.set(TACHYON_UCI_PACKAGE, srvId, 'security', 'none');
      uciObj.set(TACHYON_UCI_PACKAGE, srvId, 'transport', 'tcp');
      uciObj.set(TACHYON_UCI_PACKAGE, srvId, 'server_uuid', generateUuidV4());
      uciObj.set(TACHYON_UCI_PACKAGE, srvId, 'vmess_alter_id', '0');
    } else {
      uciObj.set(
        TACHYON_UCI_PACKAGE,
        srvId,
        'server_password',
        generateRandomHex(12),
      );
    }

    if (needsTlsCert) {
      try {
        await executeShellCommand({
          command: '/usr/bin/tachyon',
          args: ['generate_tls_keypair', srvId],
        });
      } catch {
        // Fallback if shell is unavailable in test environment
      }
    }

    await persistAndFinish('inbound', srvId, label, applyImmediately);
  }

  function rerender() {
    const header = E('div', { class: 'tachyon-wizard__header' }, [
      E('div', { class: 'tachyon-wizard__brand' }, [
        renderTachyonDuckMascotSvg(42),
        E('div', { class: 'tachyon-wizard__brand-text' }, [
          E(
            'div',
            { class: 'tachyon-wizard__title' },
            tr('Мастер подключения Tachyon', 'Tachyon Connection Wizard'),
          ),
          E(
            'div',
            { class: 'tachyon-wizard__caption' },
            direction === 'outbound'
              ? tr(
                  'Быстрая настройка исходящего маршрута и обхода блокировок',
                  'Quick setup for outbound routing & anti-censorship',
                )
              : tr(
                  'Быстрое создание своего VPN / Прокси сервера на роутере',
                  'Quick setup for hosting your own VPN / Proxy server',
                ),
          ),
        ]),
      ]),
      renderStepIndicator(),
    ]);

    const maxStep = direction === 'outbound' ? 4 : 3;

    const body =
      step === 1
        ? renderStep1()
        : direction === 'outbound'
          ? step === 2
            ? renderStep2Outbound()
            : step === 3
              ? renderStep3Outbound()
              : renderStep4Outbound()
          : step === 2
            ? renderStep2Inbound()
            : renderStep3Inbound();

    const footerButtons: HTMLElement[] = [
      E(
        'button',
        {
          type: 'button',
          class: 'btn cbi-button',
          click: () => {
            stopDnsBenchPollTimer();
            uiObj.hideModal();
          },
        },
        tr('Отмена', 'Cancel'),
      ),
    ];

    if (step > 1) {
      footerButtons.push(
        E(
          'button',
          {
            type: 'button',
            class: 'btn cbi-button',
            click: () => {
              step = (step - 1) as 1 | 2 | 3 | 4;
              rerender();
            },
          },
          tr('← Назад', '← Back'),
        ),
      );
    }

    if (step < maxStep) {
      footerButtons.push(
        E(
          'button',
          {
            type: 'button',
            class: 'btn cbi-button cbi-button-action important',
            click: () => {
              if (step === 2 && direction === 'outbound') {
                if (outboundMethod === 'subscription' && !subUrl.trim()) {
                  showToast(
                    tr(
                      'Укажите ссылку на подписку (URL)',
                      'Please enter Subscription URL',
                    ),
                    'error',
                  );
                  return;
                }
                if (
                  outboundMethod === 'proxy_links' &&
                  !proxyLinksText.trim()
                ) {
                  showToast(
                    tr(
                      'Вставьте хотя бы одну ссылку на сервер',
                      'Please paste at least one share link',
                    ),
                    'error',
                  );
                  return;
                }
                if (
                  outboundMethod === 'amnezia_config' &&
                  !amneziaText.trim()
                ) {
                  showToast(
                    tr(
                      'Вставьте ключ vpn:// или загрузите файл .conf',
                      'Please paste a vpn:// link or upload a .conf file',
                    ),
                    'error',
                  );
                  return;
                }
                if (outboundMethod === 'fptn' && !fptnToken.trim()) {
                  showToast(
                    tr(
                      'Вставьте токен доступа FPTN (fptn://)',
                      'Please paste FPTN access token',
                    ),
                    'error',
                  );
                  return;
                }
              }
              step = (step + 1) as 2 | 3 | 4;
              rerender();
            },
          },
          tr('Далее →', 'Next →'),
        ),
      );
    } else {
      footerButtons.push(
        E(
          'button',
          {
            type: 'button',
            class: 'btn cbi-button cbi-button-action',
            click: () => {
              if (direction === 'outbound') {
                void finishOutboundWizard(false);
              } else {
                void finishInboundWizard(false);
              }
            },
          },
          [
            renderCheckIcon(14),
            ' ',
            direction === 'outbound'
              ? tr('Создать (в черновик)', 'Create (Draft)')
              : tr('Создать сервер (в черновик)', 'Create Server (Draft)'),
          ],
        ),
        E(
          'button',
          {
            type: 'button',
            class: 'btn cbi-button cbi-button-positive important',
            click: () => {
              if (direction === 'outbound') {
                void finishOutboundWizard(true);
              } else {
                void finishInboundWizard(true);
              }
            },
          },
          [
            renderZapIcon(14),
            ' ',
            direction === 'outbound'
              ? tr('Создать и применить', 'Create & Apply')
              : tr('Создать и запустить', 'Create & Start'),
          ],
        ),
      );
    }

    const footer = E('div', { class: 'tachyon-wizard__footer' }, footerButtons);

    root.replaceChildren(header, body, footer);
  }

  rerender();
  const dlg = uiObj.showModal('', [root], 'cbi-modal');
  const modalEl =
    (dlg && typeof (dlg as any).classList?.add === 'function'
      ? (dlg as HTMLElement)
      : null) || (root.closest?.('.modal') as HTMLElement | null);
  if (modalEl) {
    modalEl.classList.add('cbi-modal', 'tachyon-wizard-modal');
    const emptyH4 = modalEl.querySelector?.(':scope > h4');
    if (emptyH4 && !emptyH4.textContent?.trim()) {
      (emptyH4 as HTMLElement).style.display = 'none';
    }
  }
}
