#!/usr/bin/env node
import { spawn, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import http from 'node:http';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(__dirname, '..');

function defaultBinPath() {
  const exe = process.platform === 'win32' ? 'tachyon.exe' : 'tachyon';
  const rel = path.join(REPO_ROOT, 'target', 'release', exe);
  if (fs.existsSync(rel)) return rel;
  return path.join(REPO_ROOT, 'target', 'debug', exe);
}

function parseArgs(argv) {
  const opts = {
    lang: 'all',
    luciBaseUrl: 'http://192.168.1.1',
    luciBaseDir: '',
    chrome: '',
    outDir: path.join(REPO_ROOT, 'docs', 'images'),
    bin: defaultBinPath(),
    only: '',
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--lang' && argv[i + 1]) opts.lang = argv[++i];
    else if (a === '--luci-base-url' && argv[i + 1]) opts.luciBaseUrl = argv[++i];
    else if (a === '--luci-base-dir' && argv[i + 1]) opts.luciBaseDir = argv[++i];
    else if (a === '--chrome' && argv[i + 1]) opts.chrome = argv[++i];
    else if (a === '--out-dir' && argv[i + 1]) opts.outDir = path.resolve(REPO_ROOT, argv[++i]);
    else if (a === '--bin' && argv[i + 1]) opts.bin = path.resolve(REPO_ROOT, argv[++i]);
    else if (a === '--only' && argv[i + 1]) opts.only = argv[++i];
  }
  return opts;
}

function findChromeBinary(explicit) {
  const candidates = [
    explicit,
    process.env.CHROME_BIN,
    'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe',
    'C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe',
    'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe',
    'C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe',
    '/usr/bin/google-chrome',
    '/usr/bin/chromium',
    '/usr/bin/chromium-browser',
  ].filter(Boolean);
  for (const c of candidates) {
    if (fs.existsSync(c)) return c;
  }
  throw new Error('Headless Chrome/Edge binary not found. Pass --chrome <path>.');
}

function getFreePort() {
  return new Promise((resolve, reject) => {
    const srv = net.createServer();
    srv.unref();
    srv.on('error', reject);
    srv.listen(0, '127.0.0.1', () => {
      const addr = srv.address();
      const port = typeof addr === 'object' && addr ? addr.port : 0;
      srv.close((err) => (err ? reject(err) : resolve(port)));
    });
  });
}

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

async function waitForHttp(url, timeoutMs = 15000) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    try {
      const res = await fetch(url);
      if (res.ok || res.status === 200 || res.status === 404) return;
    } catch {
      // retry
    }
    await sleep(150);
  }
  throw new Error(`Timed out waiting for ${url}`);
}

function buildDemoStoreData(lang, daemonPort, dataDir) {
  return {
    settings: {
      config_version: '2.0.0',
      listen_addr: '127.0.0.1',
      listen_port: daemonPort,
      web_base_path: '/tachyon',
      admin_user: 'root',
      admin_pass_hash: '',
      admin_pass_salt: '',
      session_secret: 'docs-demo-session-secret',
      ui_mode: 'advanced',
      lite_mode: false,
      sidebar_pos: 'top',
      sidebar_collapsed: false,
      accent_theme: 'blue',
      lang,
      default_tab: 'dashboard',
      core_bin_path: '/usr/bin/tachyon-core',
      core_config_path: path.join(dataDir, 'core-config.json'),
      cache_path: path.join(dataDir, 'cache.db'),
      rulesets_dir: path.join(dataDir, 'rulesets'),
      clash_api_addr: '127.0.0.1:9090',
      clash_api_secret: '',
      proxy_mode: 'tproxy',
      tun_interface: 'tun0',
      tun_stack: 'mixed',
      tun_mtu: 1500,
      tun_inet4: '172.19.0.1/30',
      tun_kill_switch: true,
      smart_queue: true,
      sqm_download_kbps: 500000,
      sqm_upload_kbps: 250000,
      sqm_interface: 'wan',
      tcp_profile: 'auto',
      tcp_bbr: true,
      selector_auto_failover: true,
      source_network_interfaces: ['br-lan'],
      ipv6_mode: 'auto',
      ipv6_leak_guard: true,
      disable_quic: false,
      dns_intercept_all: true,
      dns_intercept_all_mode: 'auto',
      webrtc_leak_protect: true,
      webrtc_leak_protect_mode: 'auto',
      tailscale_enabled: true,
      tailscale_web_access: 'auto',
      dns_type: 'doh',
      dns_servers: [
        'https://dns.google/dns-query',
        'https://1.1.1.1/dns-query',
      ],
      bootstrap_dns_servers: ['77.88.8.8', '1.1.1.1'],
      dns_fallback_servers: ['1.1.1.1'],
      dns_local_cache: true,
      dns_turbo_cache: true,
      fakeip_enabled: true,
      fakeip_inet4_range: '198.18.0.0/15',
      fakeip_inet6_range: 'fc00::/18',
      hosts_enabled: true,
      hosts_block_ads: true,
      enable_watchdog: true,
      smart_detect: true,
      smart_detect_mode: 'suggest',
      list_update_enabled: true,
      update_interval: '24h',
      component_update_channel: 'beta',
      component_update_check_enabled: true,
      component_update_check_interval: '1d',
      component_backup_enabled: true,
      server_subscription_enabled: true,
      server_subscription_token: 'demo-sub-token-example',
      enable_ai_doctor: true,
      enable_rag: true,
      ai_doctor_provider: 'openai',
      ai_doctor_model: 'gpt-4o-mini',
      ai_doctor_api_key: '',
      ai_doctor_lang: lang,
      flash_wear_protection: true,
    },
    sections: [
      {
        id: 'sec_stream',
        enabled: true,
        label: 'Streaming & Media',
        description: lang === 'ru'
          ? 'Медиасервисы через балансировщик устойчивости'
          : 'Media traffic balanced across low-jitter EU nodes',
        connection_type: 'proxy',
        action: 'proxy',
        condition_refs: ['cond_stream'],
        outbound_source_refs: ['src_nl', 'src_hy2', 'src_sub'],
        balancer_refs: ['bal_eu'],
        community_lists: ['youtube', 'twitch'],
      },
      {
        id: 'sec_work',
        enabled: true,
        label: 'Work & Dev (Fail-Closed)',
        description: lang === 'ru'
          ? 'Рабочие ресурсы со строгим Fail-Closed и Kill-Switch'
          : 'Corporate hosts with Fail-Closed and Kill-Switch guard',
        connection_type: 'proxy',
        action: 'proxy',
        condition_refs: ['cond_work'],
        outbound_source_refs: ['src_awg', 'src_wdtt'],
        balancer_refs: ['bal_work'],
        fail_closed: true,
        kill_switch: true,
      },
      {
        id: 'sec_desync',
        enabled: true,
        label: 'Adaptive Packet Desync',
        description: lang === 'ru'
          ? 'Локальная десинхронизация пакетов для выбранных доменов'
          : 'Native packet desynchronization for selected hosts',
        connection_type: 'desync',
        action: 'desync',
        outbound_source_refs: ['src_desync'],
        user_domains: ['media.example.org', 'cdn.example.net'],
      },
      {
        id: 'sec_direct',
        enabled: true,
        label: 'Local & LAN Direct',
        description: lang === 'ru'
          ? 'Прямое соединение без проксирования'
          : 'Direct WAN route without tunneling',
        connection_type: 'direct',
        action: 'direct',
        condition_refs: ['cond_direct'],
      },
    ],
    conditions: [
      {
        id: 'cond_stream',
        enabled: true,
        name: 'Media .trs Lists',
        condition_type: 'atomic',
        community_lists: ['youtube', 'netflix', 'twitch'],
        community_subnets: true,
      },
      {
        id: 'cond_work',
        enabled: true,
        name: 'Corporate Domains',
        condition_type: 'atomic',
        user_domains: ['git.example.org', 'ci.example.com', 'docs.example.org'],
        user_subnets: ['198.51.100.0/25'],
      },
      {
        id: 'cond_direct',
        enabled: true,
        name: 'Direct Subnets',
        condition_type: 'atomic',
        user_domains: ['intranet.example.local'],
        user_subnets: ['203.0.113.0/24'],
      },
    ],
    outbound_sources: [
      {
        id: 'src_nl',
        enabled: true,
        name: 'VLESS Reality NL',
        source_type: 'proxy_links',
        proxy_links: [
          'vless://11111111-1111-1111-1111-111111111111@198.51.100.11:443?encryption=none&security=reality&sni=example.com&fp=chrome&pbk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&sid=01ab&type=tcp&flow=xtls-rprx-vision#NL-Amsterdam',
        ],
      },
      {
        id: 'src_awg',
        enabled: true,
        name: 'AmneziaWG 3.1 DE',
        source_type: 'awg',
        wg_endpoint: '198.51.100.12:51820',
        wg_local_address: '10.8.0.2/32',
        wg_peer_public_key: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
        wg_private_key: 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=',
        wg_mtu: 1380,
        awg_version: '3.1',
        awg_jc: 4,
        awg_jmin: 40,
        awg_jmax: 70,
        awg_s1: 32,
        awg_s2: 48,
        awg_h1: '10112233',
        awg_h2: '20112233',
        awg_h3: '30112233',
        awg_h4: '40112233',
      },
      {
        id: 'src_hy2',
        enabled: true,
        name: 'Hysteria2 FI',
        source_type: 'proxy_links',
        proxy_links: [
          'hysteria2://demo-pass@198.51.100.13:443?sni=hy2.example.com#FI-Helsinki',
        ],
      },
      {
        id: 'src_wdtt',
        enabled: true,
        name: 'WDTT Call Relay',
        source_type: 'proxy_links',
        proxy_links: [
          'wdtt://demo-pass@198.51.100.14:3478?mode=csqtt&media=vk&vk_auth_mode=cookie#WDTT-Relay',
        ],
      },
      {
        id: 'src_sub',
        enabled: true,
        name: 'EU Cluster Subscription',
        source_type: 'subscription',
        subscription_urls: ['https://sub.example.com/tachyon/main'],
        subscription_update_interval: '12h',
      },
      {
        id: 'src_desync',
        enabled: true,
        name: 'Adaptive TLS Desync',
        source_type: 'desync',
        desync_preset: 'adaptive',
        desync_auto_tune: true,
        desync_mode: 'multisplit',
        desync_ttl: 5,
        desync_fooling: 'badsum',
      },
    ],
    balancers: [
      {
        id: 'bal_eu',
        enabled: true,
        name: 'EU Auto Stability',
        balancer_type: 'urltest',
        mode: 'stability',
        testing_url: 'https://cp.cloudflare.com/generate_204',
        check_interval: 180,
        tolerance: 50,
      },
      {
        id: 'bal_work',
        enabled: true,
        name: 'Work Priority Failover',
        balancer_type: 'priority',
        mode: 'priority',
        testing_url: 'https://cp.cloudflare.com/generate_204',
        check_interval: 120,
        tolerance: 30,
      },
    ],
    outbound_groups: [],
    servers: [
      {
        id: 'srv_awg',
        enabled: true,
        label: 'Home AWG 3.1 Server',
        country: 'DE',
        protocol: 'awg',
        listen: '0.0.0.0',
        listen_port: 51820,
        public_host: 'vpn.example.com',
        open_firewall_port: true,
        awg_version: '3.1',
      },
      {
        id: 'srv_vless',
        enabled: true,
        label: 'VLESS Reality Ingress',
        country: 'NL',
        protocol: 'vless',
        listen: '0.0.0.0',
        listen_port: 8443,
        public_host: 'vpn.example.com',
        sni: 'cdn.example.com',
        open_firewall_port: true,
      },
    ],
    profiles: [
      {
        id: 'prof_kids',
        enabled: true,
        label: 'Kids Tablet',
        device_ips: ['192.168.1.24'],
        safe_search: true,
        block_doh: true,
        daily_quota_minutes: 120,
        used_minutes_today: 75,
      },
      {
        id: 'prof_tv',
        enabled: true,
        label: 'Living Room TV',
        device_ips: ['192.168.1.35'],
        safe_search: false,
        block_doh: false,
        daily_quota_minutes: 240,
        used_minutes_today: 90,
      },
    ],
    schedules: [
      {
        id: 'sched_kids_school',
        enabled: true,
        label: lang === 'ru' ? 'Ночной режим для детей' : 'Kids Bedtime Window',
        start_time: '22:00',
        end_time: '07:00',
      },
    ],
    guest_mode: {
      enabled: true,
      mode: 'selected',
      guest_devices: ['192.168.1.48'],
      trusted_devices: ['192.168.1.10'],
      isolate_lan: true,
      block_router_admin: true,
      allow_proxy: true,
      bandwidth_limit_mbps: 25,
      daily_traffic_limit: 2048,
      daily_time_limit: 240,
      start_time: '08:00',
      end_time: '23:00',
    },
    telegram: {
      enabled: true,
      bot_token: '123456789:DEMO-TOKEN-EXAMPLE-ONLY',
      admin_ids: [10000001],
      router_name: 'Flint2-Home',
      poll_interval: 3,
      notify_crash: true,
      notify_restart: true,
      notify_server_switch: true,
      notify_subscription: true,
      notify_dns_leak: true,
      fleet_routers: [
        {
          id: 'branch_1',
          name: 'Branch-Office',
          url: 'https://198.51.100.50:1680',
          token: 'demo-fleet-token',
        },
      ],
    },
    device_registry: {},
    applied_migrations: [],
  };
}

function buildDemoConfigSections(lang) {
  let idx = 0;
  const entry = (type, name, fields) => ({
    '.anonymous': false,
    '.type': type,
    '.name': name,
    '.index': idx++,
    ...fields,
  });

  return {
    settings: entry('settings', 'settings', {
      proxy_mode: 'tproxy',
      tun_interface: 'tun0',
      tun_stack: 'mixed',
      tun_mtu: '1500',
      tun_inet4: '172.19.0.1/30',
      tun_kill_switch: '1',
      dns_type: 'doh',
      dns_server: ['https://dns.google/dns-query', 'https://1.1.1.1/dns-query'],
      bootstrap_dns_server: ['77.88.8.8', '1.1.1.1'],
      dns_fallback_server: ['1.1.1.1'],
      dns_local_cache: '1',
      dns_turbo_cache: '1',
      fakeip_enabled: '1',
      fakeip_inet4_range: '198.18.0.0/15',
      fakeip_inet6_range: 'fc00::/18',
      dns_intercept_all: '1',
      dns_intercept_all_mode: 'auto',
      ipv6_mode: 'auto',
      ipv6_leak_guard: '1',
      disable_quic: '0',
      webrtc_leak_protect: '1',
      webrtc_leak_protect_mode: 'auto',
      hosts_enabled: '1',
      hosts_block_ads: '1',
      smart_queue: '1',
      sqm_download_kbps: '500000',
      sqm_upload_kbps: '250000',
      sqm_interface: 'wan',
      tcp_profile: 'auto',
      tcp_bbr: '1',
      selector_auto_failover: '1',
      source_network_interfaces: ['br-lan'],
      tailscale_enabled: '1',
      tailscale_web_access: 'auto',
      list_update_enabled: '1',
      update_interval: '24h',
      component_update_channel: 'beta',
      component_update_check_enabled: '1',
      component_update_check_interval: '1d',
      component_backup_enabled: '1',
      server_subscription_enabled: '1',
      server_subscription_token: 'demo-sub-token-example',
      enable_ai_doctor: '1',
      enable_rag: '1',
      ai_doctor_provider: 'openai',
      ai_doctor_model: 'gpt-4o-mini',
      ai_doctor_lang: lang,
      enable_watchdog: '1',
      smart_detect: '1',
      smart_detect_mode: 'suggest',
      flash_wear_protection: '1',
      ui_mode: 'advanced',
      sidebar_pos: 'top',
      accent_theme: 'blue',
      lang,
      default_tab: 'dashboard',
    }),
    sec_stream: entry('section', 'sec_stream', {
      enabled: '1',
      label: 'Streaming & Media',
      description: lang === 'ru'
        ? 'Медиасервисы через балансировщик устойчивости'
        : 'Media traffic balanced across low-jitter EU nodes',
      connection_type: 'proxy',
      action: 'proxy',
      condition_refs: ['cond_stream'],
      outbound_source_refs: ['src_nl', 'src_hy2', 'src_sub'],
      balancer_refs: ['bal_eu'],
      community_lists: ['youtube', 'twitch'],
    }),
    sec_work: entry('section', 'sec_work', {
      enabled: '1',
      label: 'Work & Dev (Fail-Closed)',
      description: lang === 'ru'
        ? 'Рабочие ресурсы со строгим Fail-Closed и Kill-Switch'
        : 'Corporate hosts with Fail-Closed and Kill-Switch guard',
      connection_type: 'proxy',
      action: 'proxy',
      condition_refs: ['cond_work'],
      outbound_source_refs: ['src_awg', 'src_wdtt'],
      balancer_refs: ['bal_work'],
      fail_closed: '1',
      kill_switch: '1',
    }),
    sec_desync: entry('section', 'sec_desync', {
      enabled: '1',
      label: 'Adaptive Packet Desync',
      description: lang === 'ru'
        ? 'Локальная десинхронизация пакетов для выбранных доменов'
        : 'Native packet desynchronization for selected hosts',
      connection_type: 'desync',
      action: 'desync',
      outbound_source_refs: ['src_desync'],
      user_domains: ['media.example.org', 'cdn.example.net'],
    }),
    sec_direct: entry('section', 'sec_direct', {
      enabled: '1',
      label: 'Local & LAN Direct',
      description: lang === 'ru'
        ? 'Прямое соединение без проксирования'
        : 'Direct WAN route without tunneling',
      connection_type: 'direct',
      action: 'direct',
      condition_refs: ['cond_direct'],
    }),
    cond_stream: entry('condition', 'cond_stream', {
      enabled: '1',
      name: 'Media .trs Lists',
      condition_type: 'atomic',
      community_lists: ['youtube', 'netflix', 'twitch'],
      community_subnets: '1',
    }),
    cond_work: entry('condition', 'cond_work', {
      enabled: '1',
      name: 'Corporate Domains',
      condition_type: 'atomic',
      user_domains: ['git.example.org', 'ci.example.com', 'docs.example.org'],
      user_subnets: ['198.51.100.0/25'],
    }),
    cond_direct: entry('condition', 'cond_direct', {
      enabled: '1',
      name: 'Direct Subnets',
      condition_type: 'atomic',
      user_domains: ['intranet.example.local'],
      user_subnets: ['203.0.113.0/24'],
    }),
    src_nl: entry('outbound_source', 'src_nl', {
      enabled: '1',
      name: 'VLESS Reality NL',
      source_type: 'proxy_links',
      proxy_links: [
        'vless://11111111-1111-1111-1111-111111111111@198.51.100.11:443?encryption=none&security=reality&sni=example.com&fp=chrome&pbk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&sid=01ab&type=tcp&flow=xtls-rprx-vision#NL-Amsterdam',
      ],
    }),
    src_awg: entry('outbound_source', 'src_awg', {
      enabled: '1',
      name: 'AmneziaWG 3.1 DE',
      source_type: 'awg',
      wg_endpoint: '198.51.100.12:51820',
      wg_local_address: '10.8.0.2/32',
      wg_peer_public_key: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
      wg_private_key: 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=',
      wg_mtu: '1380',
      awg_version: '3.1',
      awg_jc: '4',
      awg_jmin: '40',
      awg_jmax: '70',
      awg_s1: '32',
      awg_s2: '48',
      awg_h1: '10112233',
      awg_h2: '20112233',
      awg_h3: '30112233',
      awg_h4: '40112233',
    }),
    src_hy2: entry('outbound_source', 'src_hy2', {
      enabled: '1',
      name: 'Hysteria2 FI',
      source_type: 'proxy_links',
      proxy_links: [
        'hysteria2://demo-pass@198.51.100.13:443?sni=hy2.example.com#FI-Helsinki',
      ],
    }),
    src_wdtt: entry('outbound_source', 'src_wdtt', {
      enabled: '1',
      name: 'WDTT Call Relay',
      source_type: 'proxy_links',
      proxy_links: [
        'wdtt://demo-pass@198.51.100.14:3478?mode=csqtt&media=vk&vk_auth_mode=cookie#WDTT-Relay',
      ],
    }),
    src_sub: entry('outbound_source', 'src_sub', {
      enabled: '1',
      name: 'EU Cluster Subscription',
      source_type: 'subscription',
      subscription_urls: ['https://sub.example.com/tachyon/main'],
      subscription_update_interval: '12h',
    }),
    src_desync: entry('outbound_source', 'src_desync', {
      enabled: '1',
      name: 'Adaptive TLS Desync',
      source_type: 'desync',
      desync_preset: 'adaptive',
      desync_auto_tune: '1',
      desync_mode: 'multisplit',
      desync_ttl: '5',
      desync_fooling: 'badsum',
    }),
    bal_eu: entry('balancer', 'bal_eu', {
      enabled: '1',
      name: 'EU Auto Stability',
      balancer_type: 'urltest',
      mode: 'stability',
      testing_url: 'https://cp.cloudflare.com/generate_204',
      check_interval: '180',
      tolerance: '50',
    }),
    bal_work: entry('balancer', 'bal_work', {
      enabled: '1',
      name: 'Work Priority Failover',
      balancer_type: 'priority',
      mode: 'priority',
      testing_url: 'https://cp.cloudflare.com/generate_204',
      check_interval: '120',
      tolerance: '30',
    }),
    srv_awg: entry('server', 'srv_awg', {
      enabled: '1',
      label: 'Home AWG 3.1 Server',
      country: 'DE',
      protocol: 'awg',
      listen: '0.0.0.0',
      listen_port: '51820',
      public_host: 'vpn.example.com',
      open_firewall_port: '1',
      awg_version: '3.1',
    }),
    srv_vless: entry('server', 'srv_vless', {
      enabled: '1',
      label: 'VLESS Reality Ingress',
      country: 'NL',
      protocol: 'vless',
      listen: '0.0.0.0',
      listen_port: '8443',
      public_host: 'vpn.example.com',
      sni: 'cdn.example.com',
      open_firewall_port: '1',
    }),
    prof_kids: entry('profile', 'prof_kids', {
      enabled: '1',
      label: 'Kids Tablet',
      devices: ['192.168.1.24'],
      device_ips: ['192.168.1.24'],
      safe_search: '1',
      block_doh: '1',
      daily_quota_minutes: '120',
      used_minutes_today: '75',
    }),
    prof_tv: entry('profile', 'prof_tv', {
      enabled: '1',
      label: 'Living Room TV',
      devices: ['192.168.1.35'],
      device_ips: ['192.168.1.35'],
      safe_search: '0',
      block_doh: '0',
      daily_quota_minutes: '240',
      used_minutes_today: '90',
    }),
    sched_kids_school: entry('schedule', 'sched_kids_school', {
      enabled: '1',
      label: lang === 'ru' ? 'Ночной режим для детей' : 'Kids Bedtime Window',
      profile: ['prof_kids'],
      start_time: '22:00',
      end_time: '07:00',
      days: ['mon', 'tue', 'wed', 'thu', 'fri'],
      action: 'block',
    }),
    guest_mode: entry('guest_mode', 'guest_mode', {
      enabled: '1',
      mode: 'selected',
      guest_devices: ['192.168.1.48'],
      trusted_devices: ['192.168.1.10'],
      isolate_lan: '1',
      block_router_admin: '1',
      allow_proxy: '1',
      bandwidth_limit_mbps: '25',
      daily_traffic_limit: '2048',
      daily_time_limit: '240',
      start_time: '08:00',
      end_time: '23:00',
    }),
    telegram: entry('telegram', 'telegram', {
      enabled: '1',
      bot_token: '123456789:DEMO-TOKEN-EXAMPLE-ONLY',
      admin_ids: ['10000001'],
      router_name: 'Flint2-Home',
      poll_interval: '3',
      notify_crash: '1',
      notify_restart: '1',
      notify_server_switch: '1',
      notify_subscription: '1',
      notify_dns_leak: '1',
    }),
  };
}

function buildDemoTelemetry(lang) {
  const nowSec = Math.floor(Date.now() / 1000);
  const nowIso = new Date().toISOString();

  const systemInfo = {
    tachyon_version: '2.0.0-beta.20',
    tachyon_commit_sha: 'a1b2c3d4',
    tachyon_latest_version: '2.0.0-rc.1',
    tachyon_update_available: 1,
    tachyon_release_url: 'https://github.com/Dushnilin/tachyon/releases/tag/v2.0.0-rc.1',
    tachyon_backup_version: '2.0.0-beta.19',
    tachyon_backup_time: nowSec - 86400 * 3,
    luci_app_version: '2.0.0-beta.20',
    tachyon_core_version: '0.6.3',
    tachyon_core_latest_version: '0.6.4',
    tachyon_core_update_available: 1,
    tachyon_core_release_url: 'https://github.com/Dushnilin/tachyon-core/releases/tag/v0.6.4',
    tachyon_core_repo_url: 'https://github.com/Dushnilin/tachyon-core',
    tachyon_core_backup_version: '0.6.2',
    tachyon_core_backup_time: nowSec - 86400 * 5,
    tachyon_core_installed: 1,
    tachyon_core_tailscale: 1,
    tachyon_core_cert_pin: 1,
    sing_box_version: '0.6.3',
    sing_box_latest_version: '0.6.4',
    sing_box_update_available: 1,
    sing_box_tachyon_core: 1,
    active_engine: 'tachyon-core',
    openwrt_version: 'OpenWrt 24.10.0',
    device_model: 'GL.iNet GL-MT6000 (Flint 2)',
    kernel_version: '6.6.73',
    cpu_arch: 'aarch64_cortex-a53',
    uptime_seconds: 311040,
    ram_total_mb: 1024,
    ram_free_mb: 742,
    mem_total_mb: 1024,
    mem_used_mb: 282,
    mem_free_mb: 742,
    mem_used_pct: 27,
    conntrack_count: 412,
    conntrack_max: 65536,
    wan_ip: '198.51.100.42',
    wan_ipv6: '2001:db8:1::42',
    lan_ip: '192.168.1.1',
    wan6_available: 1,
    wan6_iface: 'wan6',
    router_hostname: 'Flint2-Home',
    server_inbounds_enabled_count: 2,
    active_sections_count: 4,
    total_sections_count: 4,
    quarantined_sections_count: 0,
    deferred_sections_count: 0,
    ipv6_effective_state: 'full',
  };

  const uiState = {
    active_engine: 'tachyon-core',
    service: {
      tachyon: {
        running: 1,
        enabled: 1,
        status: 'running & enabled',
        dns_configured: 1,
        lite_mode: 0,
        pid: 1842,
        memory_rss_mb: 14,
        uptime_seconds: 311040,
        uptime_pretty: '3d 14h',
        cpu_load_percent: 3.2,
        cpu_temp_c: 49.5,
      },
      tachyon_core: {
        running: 1,
        enabled: 1,
        status: 'running & enabled',
        memory_rss_mb: 19,
        pid: 1905,
        uptime_seconds: 311020,
        uptime_pretty: '3d 14h',
        engine_variant: 'tachyon-core',
        engine_version: '0.6.3',
      },
      sing_box: {
        running: 1,
        enabled: 1,
        status: 'running & enabled',
        memory_rss_mb: 19,
        pid: 1905,
        uptime_seconds: 311020,
        uptime_pretty: '3d 14h',
        engine_variant: 'tachyon-core',
        engine_version: '0.6.3',
      },
      dnsmasq: {
        running: 1,
        pid: 1120,
        memory_rss_mb: 6,
        local_cache_enabled: 1,
        cache_size: 1500,
      },
      watchdog: { running: 1, pid: 1842 },
    },
    capabilities: {
      tachyon_core_installed: 1,
      tachyon_core_fptn: 0,
      tachyon_core_tailscale: 1,
      tachyon_core_cert_pin: 1,
      i18n_ru_installed: 1,
      luci_lang: lang,
      server_inbounds_enabled_count: 2,
    },
    ui_prefs: {
      ui_mode: 'advanced',
      sidebar_pos: 'top',
      dashboard_show_hidden: false,
    },
    actions: { service: [], latency: [], component: [], subscription: [] },
  };

  const clashProxies = {
    proxies: {
      'sec_stream-out': {
        name: 'sec_stream-out',
        type: 'Selector',
        udp: true,
        now: 'bal_eu',
        all: ['bal_eu', 'NL-Amsterdam', 'FI-Helsinki'],
        history: [{ time: nowIso, delay: 42 }],
      },
      'sec_work-out': {
        name: 'sec_work-out',
        type: 'Selector',
        udp: true,
        now: 'bal_work',
        all: ['bal_work', 'AmneziaWG 3.1 DE', 'WDTT-Relay'],
        history: [{ time: nowIso, delay: 38 }],
      },
      'sec_desync-out': {
        name: 'sec_desync-out',
        type: 'Selector',
        udp: true,
        now: 'Adaptive TLS Desync',
        all: ['Adaptive TLS Desync'],
        history: [{ time: nowIso, delay: 14 }],
      },
      bal_eu: {
        name: 'bal_eu',
        type: 'URLTest',
        mode: 'stability',
        udp: true,
        now: 'NL-Amsterdam',
        all: ['NL-Amsterdam', 'FI-Helsinki'],
        history: [{ time: nowIso, delay: 42 }],
      },
      bal_work: {
        name: 'bal_work',
        type: 'Fallback',
        mode: 'priority',
        udp: true,
        now: 'AmneziaWG 3.1 DE',
        all: ['AmneziaWG 3.1 DE', 'WDTT-Relay'],
        history: [{ time: nowIso, delay: 38 }],
      },
      'NL-Amsterdam': {
        name: 'NL-Amsterdam',
        type: 'VLESS',
        udp: true,
        history: [{ time: nowIso, delay: 42 }],
      },
      'AmneziaWG 3.1 DE': {
        name: 'AmneziaWG 3.1 DE',
        type: 'WireGuard',
        udp: true,
        history: [{ time: nowIso, delay: 38 }],
      },
      'FI-Helsinki': {
        name: 'FI-Helsinki',
        type: 'Hysteria2',
        udp: true,
        history: [{ time: nowIso, delay: 29 }],
      },
      'WDTT-Relay': {
        name: 'WDTT-Relay',
        type: 'WDTT',
        udp: true,
        history: [{ time: nowIso, delay: 64 }],
      },
      'Adaptive TLS Desync': {
        name: 'Adaptive TLS Desync',
        type: 'Desync',
        udp: true,
        history: [{ time: nowIso, delay: 14 }],
      },
    },
  };

  const clashConnections = {
    downloadTotal: 1482910420,
    uploadTotal: 284190220,
    memory: 19922944,
    connections: [
      {
        id: 'conn-1',
        dataSource: 'core',
        metadata: {
          network: 'tcp',
          type: 'TProxy',
          sourceIP: '192.168.1.10',
          sourcePort: '54122',
          destinationIP: '198.18.0.45',
          destinationPort: '443',
          host: 'video.example.com',
          dnsMode: 'fake-ip',
        },
        upload: 184200,
        download: 24910400,
        start: nowIso,
        chains: ['NL-Amsterdam', 'bal_eu', 'sec_stream-out'],
        rule: 'rule_set:trs-youtube',
      },
      {
        id: 'conn-2',
        dataSource: 'core',
        metadata: {
          network: 'tcp',
          type: 'TProxy',
          sourceIP: '192.168.1.10',
          sourcePort: '54188',
          destinationIP: '198.18.0.72',
          destinationPort: '443',
          host: 'git.example.org',
          dnsMode: 'fake-ip',
        },
        upload: 612000,
        download: 3840100,
        start: nowIso,
        chains: ['AmneziaWG 3.1 DE', 'bal_work', 'sec_work-out'],
        rule: 'domain_suffix:git.example.org',
      },
      {
        id: 'conn-3',
        dataSource: 'core',
        metadata: {
          network: 'udp',
          type: 'TProxy',
          sourceIP: '192.168.1.35',
          sourcePort: '48210',
          destinationIP: '203.0.113.18',
          destinationPort: '443',
          host: 'cdn.example.net',
          dnsMode: 'normal',
        },
        upload: 92400,
        download: 8140200,
        start: nowIso,
        chains: ['Adaptive TLS Desync', 'sec_desync-out'],
        rule: 'domain:cdn.example.net',
      },
      {
        id: 'conn-4',
        dataSource: 'conntrack',
        metadata: {
          network: 'tcp',
          type: 'Direct',
          sourceIP: '192.168.1.24',
          sourcePort: '51904',
          destinationIP: '203.0.113.77',
          destinationPort: '443',
          host: 'school.example.org',
          dnsMode: 'normal',
        },
        upload: 24500,
        download: 312000,
        start: nowIso,
        chains: ['DIRECT'],
        rule: 'direct',
      },
    ],
  };

  const coreTelemetrySnapshot = {
    success: true,
    memory: {
      rss_bytes: 19922944,
      vm_bytes: 58720256,
      system_available_bytes: 778043392,
      total_ram_mb: 1024,
      pressure_level: 'normal',
      under_pressure: false,
      connections: {
        active_connections: 4,
        device_buckets: 3,
        inbound_buckets: 2,
        user_buckets: 1,
      },
      dns: {
        cache_entries: 1842,
        reverse_entries: 614,
        fakeip_entries: 928,
      },
    },
    traffic: {
      upload_bps: 384000,
      download_bps: 4820000,
      upload_total: clashConnections.uploadTotal,
      download_total: clashConnections.downloadTotal,
      proxied_upload: 279000000,
      proxied_download: 1460000000,
      direct_upload: 5190220,
      direct_download: 22910420,
      total_devices: 4,
      active_connections: 4,
      history: Array.from({ length: 60 }, (_, idx) => [
        120000 + ((idx * 17) % 11) * 42000,
        1400000 + ((idx * 23) % 13) * 380000,
      ]),
    },
    protocols: { tcp: 3, udp: 0, quic: 1 },
    outbounds: [
      {
        tag: 'NL-Amsterdam',
        display_name: 'NL-Amsterdam (VLESS Reality)',
        active_connections: 2,
        upload: 184200,
        download: 24910400,
        recent_hits: 142,
      },
      {
        tag: 'AmneziaWG 3.1 DE',
        display_name: 'AmneziaWG 3.1 DE',
        active_connections: 1,
        upload: 612000,
        download: 3840100,
        recent_hits: 64,
      },
      {
        tag: 'Adaptive TLS Desync',
        display_name: 'Adaptive TLS Desync',
        active_connections: 1,
        upload: 92400,
        download: 8140200,
        recent_hits: 38,
      },
    ],
    failover: {
      any_on_backup: false,
      groups: [
        {
          tag: 'bal_eu',
          display_name: 'EU Auto Stability',
          type: 'urltest',
          mode: 'stability',
          primary: 'NL-Amsterdam',
          primary_display_name: 'NL-Amsterdam',
          current: 'NL-Amsterdam',
          current_display_name: 'NL-Amsterdam',
          on_backup: false,
          primary_healthy: true,
          primary_rtt_ms: 42,
          primary_failures: 0,
          primary_quarantine_rem_s: 0,
          member_count: 2,
        },
        {
          tag: 'bal_work',
          display_name: 'Work Priority Failover',
          type: 'priority',
          mode: 'priority',
          primary: 'AmneziaWG 3.1 DE',
          primary_display_name: 'AmneziaWG 3.1 DE',
          current: 'AmneziaWG 3.1 DE',
          current_display_name: 'AmneziaWG 3.1 DE',
          on_backup: false,
          primary_healthy: true,
          primary_rtt_ms: 38,
          primary_failures: 0,
          primary_quarantine_rem_s: 0,
          member_count: 2,
        },
      ],
    },
    leak: {
      status: 'ok',
      ipv4: {
        outbound: 'sec_stream-out',
        outbound_display_name: 'Streaming & Media',
        rule: 'rule_set:trs-youtube',
        is_direct: false,
      },
      ipv6: {
        outbound: 'sec_stream-out',
        outbound_display_name: 'Streaming & Media',
        rule: 'ipv6-leak-guard',
        is_direct: false,
        leak_risk: false,
      },
      webrtc_stun: {
        outbound: 'sec_stream-out',
        outbound_display_name: 'Streaming & Media',
        rule: 'webrtc-guard',
        is_direct: false,
        leak_risk: false,
      },
      dns: { engine_enabled: true },
    },
    flight: {
      count: 2,
      entries: [
        {
          id: 101,
          timestamp_ms: Date.now() - 4500,
          network: 'tcp',
          inbound: 'tproxy-in',
          source: '192.168.1.10',
          host: 'video.example.com',
          destination: '198.18.0.45:443',
          outbound: 'NL-Amsterdam',
          outbound_display_name: 'NL-Amsterdam',
          rule: 'rule_set:trs-youtube',
          upload: 184200,
          download: 24910400,
          duration_ms: 42,
          status: 'ok',
        },
        {
          id: 102,
          timestamp_ms: Date.now() - 1200,
          network: 'tcp',
          inbound: 'tproxy-in',
          source: '192.168.1.10',
          host: 'git.example.org',
          destination: '198.18.0.72:443',
          outbound: 'AmneziaWG 3.1 DE',
          outbound_display_name: 'AmneziaWG 3.1 DE',
          rule: 'domain_suffix:git.example.org',
          upload: 612000,
          download: 3840100,
          duration_ms: 38,
          status: 'ok',
        },
      ],
    },
    health: { status: 'ok', ok: true },
    anomalies: { count: 0, hosts: [] },
  };

  const updateCheckCache = {
    enabled: true,
    results: [
      {
        success: true,
        component: 'tachyon',
        action: 'check_update',
        message: lang === 'ru' ? 'Доступна версия 2.0.0-rc.1' : 'Version 2.0.0-rc.1 available',
        current_version: '2.0.0-beta.20',
        latest_version: '2.0.0-rc.1',
        release_url: 'https://github.com/Dushnilin/tachyon/releases/tag/v2.0.0-rc.1',
        release_notes: lang === 'ru'
          ? 'Кандидат в релиз 2.0.0: канал обновлений, баннер уведомлений и усиленная изоляция.'
          : 'Release candidate 2.0.0: selectable update channels, notification banner, and hardened isolation.',
        changed: true,
        status: 'outdated',
        updated_at: nowSec - 120,
      },
      {
        success: true,
        component: 'tachyon-core',
        action: 'check_update',
        message: lang === 'ru' ? 'Доступна версия 0.6.4' : 'Version 0.6.4 available',
        current_version: '0.6.3',
        latest_version: '0.6.4',
        release_url: 'https://github.com/Dushnilin/tachyon-core/releases/tag/v0.6.4',
        release_notes: lang === 'ru'
          ? 'Оптимизация QUIC-окон, потоков XHTTP и снижение RSS на встраиваемых роутерах.'
          : 'QUIC window tuning, XHTTP flow optimization, and lower RSS footprint on embedded routers.',
        changed: true,
        status: 'outdated',
        updated_at: nowSec - 120,
      },
    ],
  };

  const releasesMap = {
    tachyon: [
      {
        tag: 'v2.0.0-rc.1',
        name: 'v2.0.0-rc.1',
        published: nowIso,
        prerelease: true,
        release_url: 'https://github.com/Dushnilin/tachyon/releases/tag/v2.0.0-rc.1',
      },
      {
        tag: 'v2.0.0-beta.20',
        name: 'v2.0.0-beta.20',
        published: nowIso,
        prerelease: true,
        release_url: 'https://github.com/Dushnilin/tachyon/releases/tag/v2.0.0-beta.20',
      },
    ],
    'tachyon-core': [
      {
        tag: 'v0.6.4',
        name: 'v0.6.4',
        published: nowIso,
        prerelease: false,
        release_url: 'https://github.com/Dushnilin/tachyon-core/releases/tag/v0.6.4',
      },
      {
        tag: 'v0.6.3',
        name: 'v0.6.3',
        published: nowIso,
        prerelease: false,
        release_url: 'https://github.com/Dushnilin/tachyon-core/releases/tag/v0.6.3',
      },
    ],
  };

  const doctorReport = {
    overall: 'healthy',
    checks_passed: 9,
    checks_total: 9,
    summary: lang === 'ru'
      ? 'Все подсистемы активны: nftables, FakeIP, DoH и балансировщик EU Auto Stability работают штатно.'
      : 'All subsystems healthy: nftables, FakeIP, DoH upstream, and EU Auto Stability balancer operational.',
    findings: [],
  };

  const aiDoctorReport = {
    success: true,
    async: false,
    running: false,
    completed: true,
    status: 'completed',
    score: 98,
    report: lang === 'ru'
      ? 'Состояние маршрутизатора стабильно (98/100). Перехват TProxy на порту 1602, таблица inet TachyonTable и защита IPv6/WebRTC активны; утечек DNS и конфликтов маршрутов не обнаружено.'
      : 'Router state is healthy (98/100). TProxy intercept (:1602), inet TachyonTable, and IPv6/WebRTC guards are active; zero DNS leaks or routing conflicts detected.',
    quick_fixes: [],
    nodes: [
      { name: 'WAN', status: 'OK' },
      { name: 'DNS', status: 'OK' },
      { name: 'Core', status: 'OK' },
      { name: 'Outbound', status: 'OK' },
    ],
    mode: 'local_rag',
    provider: 'openai',
    model: 'gpt-4o-mini',
    generated_at: nowSec - 60,
  };

  const benchDomains = [
    'google.com',
    'youtube.com',
    'facebook.com',
    'instagram.com',
    'chatgpt.com',
    'x.com',
    'whatsapp.com',
    'reddit.com',
    'wikipedia.org',
    'amazon.com',
    'tiktok.com',
    'pinterest.com',
  ];
  const makeSamples = (baseMs, spreadMs) =>
    benchDomains.map((domain, i) => ({
      domain,
      ms: Number((baseMs + ((i * 1.7) % spreadMs)).toFixed(2)),
      ok: true,
    }));

  const dnsSpeedState = {
    id: 'dns-bench-demo-1',
    running: false,
    progress: 100,
    domains: benchDomains,
    results: [
      {
        server: 'https://dns.google/dns-query',
        stats: { min: 14.2, median: 18.6, avg: 19.4, max: 27.1, success: 12, total: 12 },
        samples: makeSamples(14.2, 12.9),
      },
      {
        server: 'https://1.1.1.1/dns-query',
        stats: { min: 11.8, median: 15.3, avg: 16.2, max: 23.0, success: 12, total: 12 },
        samples: makeSamples(11.8, 11.2),
      },
      {
        server: '77.88.8.8',
        stats: { min: 9.4, median: 12.1, avg: 13.0, max: 18.5, success: 12, total: 12 },
        samples: makeSamples(9.4, 9.1),
      },
      {
        server: '1.1.1.1',
        stats: { min: 10.9, median: 14.7, avg: 15.1, max: 21.3, success: 12, total: 12 },
        samples: makeSamples(10.9, 10.4),
      },
    ],
    error: null,
  };

  const dnsBlockStats = {
    ok: true,
    period: '24h',
    generated_at: nowSec,
    total_blocked: 3194,
    unique_clients: 3,
    unique_domains: 128,
    clients: [
      {
        client_ip: '192.168.1.10',
        client_name: 'workstation-lan',
        blocked_count: 1420,
        unique_domains: 54,
        last_seen: nowSec - 15,
        top_domains: [
          {
            domain: 'ads.example.com',
            count: 420,
            matched_rule: '||ads.example.com^',
            list_source: 'HaGeZi Multi PRO',
            last_seen: nowSec - 15,
          },
        ],
      },
      {
        client_ip: '192.168.1.24',
        client_name: 'kids-tablet',
        blocked_count: 1120,
        unique_domains: 48,
        last_seen: nowSec - 42,
        top_domains: [],
      },
      {
        client_ip: '192.168.1.35',
        client_name: 'living-room-tv',
        blocked_count: 654,
        unique_domains: 26,
        last_seen: nowSec - 90,
        top_domains: [],
      },
    ],
    top_domains: [
      {
        domain: 'ads.example.com',
        count: 640,
        matched_rule: '||ads.example.com^',
        list_source: 'HaGeZi Multi PRO',
        last_seen: nowSec - 15,
      },
      {
        domain: 'telemetry.example.net',
        count: 412,
        matched_rule: '||telemetry.example.net^',
        list_source: 'OISD Big',
        last_seen: nowSec - 28,
      },
      {
        domain: 'tracker.example.org',
        count: 285,
        matched_rule: '||tracker.example.org^',
        list_source: 'HaGeZi Multi PRO',
        last_seen: nowSec - 55,
      },
    ],
    top_rules: [
      { matched_rule: '||ads.example.com^', list_source: 'HaGeZi Multi PRO', count: 640 },
      { matched_rule: '||telemetry.example.net^', list_source: 'OISD Big', count: 412 },
    ],
    top_lists: [
      { list_source: 'HaGeZi Multi PRO', count: 2110 },
      { list_source: 'OISD Big', count: 1084 },
    ],
    recent_events: [
      {
        timestamp_unix: nowSec - 15,
        client_ip: '192.168.1.10',
        client_name: 'workstation-lan',
        domain: 'ads.example.com',
        matched_rule: '||ads.example.com^',
        list_source: 'HaGeZi Multi PRO',
      },
      {
        timestamp_unix: nowSec - 28,
        client_ip: '192.168.1.24',
        client_name: 'kids-tablet',
        domain: 'telemetry.example.net',
        matched_rule: '||telemetry.example.net^',
        list_source: 'OISD Big',
      },
    ],
  };

  const lanDevices = {
    success: true,
    total: 4,
    clients: [
      { ip: '192.168.1.10', mac: '02:11:22:33:44:10', hostname: 'workstation-lan', is_online: true, mode: 'proxied' },
      { ip: '192.168.1.24', mac: '02:11:22:33:44:24', hostname: 'kids-tablet', is_online: true, mode: 'proxied' },
      { ip: '192.168.1.35', mac: '02:11:22:33:44:35', hostname: 'living-room-tv', is_online: true, mode: 'proxied' },
      { ip: '192.168.1.48', mac: '02:11:22:33:44:48', hostname: 'guest-laptop', is_online: true, mode: 'direct' },
    ],
  };

  const tailscalePeers = {
    configured: true,
    backend_state: 'Running',
    self: {
      name: 'flint2-home',
      dns_name: 'flint2-home.example.ts.net',
      ips: ['100.64.0.10'],
      online: true,
      rx_bytes: 52428800,
      tx_bytes: 18432000,
    },
    peers: [
      {
        name: 'workstation',
        dns_name: 'workstation.example.ts.net',
        ips: ['100.64.0.21'],
        online: true,
        rx_bytes: 14680064,
        tx_bytes: 6291456,
      },
      {
        name: 'branch-router',
        dns_name: 'branch-router.example.ts.net',
        ips: ['100.64.0.32'],
        online: true,
        rx_bytes: 9437184,
        tx_bytes: 4194304,
      },
    ],
  };

  return {
    systemInfo,
    uiState,
    clashProxies,
    clashConnections,
    coreTelemetrySnapshot,
    updateCheckCache,
    releasesMap,
    doctorReport,
    aiDoctorReport,
    dnsSpeedState,
    dnsBlockStats,
    lanDevices,
    tailscalePeers,
  };
}

async function fetchLuciStatic(relPath, cacheDir, luciBaseUrl, luciBaseDir) {
  const safeRel = relPath.replace(/\?.*$/, '').replace(/^\/+/, '');
  if (!safeRel || safeRel.includes('..') || safeRel.includes('\\')) return null;

  if (luciBaseDir) {
    const localCandidate = path.join(luciBaseDir, safeRel);
    if (fs.existsSync(localCandidate) && fs.statSync(localCandidate).isFile()) {
      return { buf: fs.readFileSync(localCandidate), contentType: guessMime(safeRel) };
    }
  }

  const cachedPath = path.join(cacheDir, safeRel);
  if (fs.existsSync(cachedPath) && fs.statSync(cachedPath).isFile()) {
    return { buf: fs.readFileSync(cachedPath), contentType: guessMime(safeRel) };
  }

  const targetUrl = `${luciBaseUrl.replace(/\/+$/, '')}/luci-static/${safeRel}`;
  const res = await fetch(targetUrl);
  if (!res.ok) return null;
  const buf = Buffer.from(await res.arrayBuffer());
  fs.mkdirSync(path.dirname(cachedPath), { recursive: true });
  fs.writeFileSync(cachedPath, buf);
  return { buf, contentType: res.headers.get('content-type') || guessMime(safeRel) };
}

function guessMime(p) {
  if (p.endsWith('.js')) return 'application/javascript; charset=utf-8';
  if (p.endsWith('.css')) return 'text/css; charset=utf-8';
  if (p.endsWith('.svg')) return 'image/svg+xml';
  if (p.endsWith('.png')) return 'image/png';
  if (p.endsWith('.woff2')) return 'font/woff2';
  if (p.endsWith('.json')) return 'application/json; charset=utf-8';
  return 'application/octet-stream';
}

function execReply(obj) {
  return [0, { code: 0, stdout: `${JSON.stringify(obj)}\n`, stderr: '' }];
}

function tryMockUbusItem(item, demo) {
  const params = Array.isArray(item?.params) ? item.params : [];
  const obj = params[1];
  const meth = params[2];
  const args = params[3] || {};

  if (obj === 'luci-rpc' && meth === 'getHostHints') {
    const hints = {};
    for (const c of demo.lanDevices.clients) {
      hints[c.mac.toUpperCase()] = { name: c.hostname, ipaddrs: [c.ip], ip6addrs: [] };
    }
    return [0, hints];
  }
  if (obj === 'luci-rpc' && meth === 'getDHCPLeases') {
    return [
      0,
      {
        dhcp_leases: demo.lanDevices.clients.map((c) => ({
          ipaddr: c.ip,
          macaddr: c.mac,
          hostname: c.hostname,
          expires: 3600,
        })),
        dhcp6_leases: [],
      },
    ];
  }
  if (obj === 'luci-rpc' && meth === 'getBoardJSON') {
    return [
      0,
      {
        kernel: '6.6.73',
        hostname: 'Flint2-Home',
        model: 'GL.iNet GL-MT6000 (Flint 2)',
        system: 'ARMv8 Processor rev 4',
        release: { distribution: 'OpenWrt', version: '24.10.0', description: 'OpenWrt 24.10.0' },
      },
    ];
  }
  if (obj === 'network.interface' && meth === 'dump') {
    return [
      0,
      {
        interface: [
          { interface: 'lan', up: true, l3_device: 'br-lan', 'ipv4-address': [{ address: '192.168.1.1', mask: 24 }] },
          { interface: 'wan', up: true, l3_device: 'eth1', 'ipv4-address': [{ address: '198.51.100.42', mask: 24 }] },
        ],
      },
    ];
  }

  if (obj === 'file' && meth === 'read') {
    const fpath = String(args.path || '');
    if (fpath === '/var/run/tachyon/section-errors.json') {
      return [0, { data: '{}' }];
    }
    if (fpath === '/var/run/tachyon/ui-state/clash-proxies.json') {
      return [0, { data: JSON.stringify(demo.clashProxies) }];
    }
    if (fpath === '/var/run/tachyon/ui-state/clash-connections.json') {
      return [0, { data: JSON.stringify(demo.clashConnections) }];
    }
    if (fpath === '/var/run/tachyon/system-info.json') {
      return [0, { data: JSON.stringify(demo.systemInfo) }];
    }
    return null;
  }

  if (obj !== 'file' || meth !== 'exec') return null;
  const cmd = String(args.command || '');
  const cmdParams = Array.isArray(args.params) ? args.params : [];
  if (cmd !== '/usr/bin/tachyon' && cmd !== '/usr/bin/tachyon-read') return null;

  const sub = String(cmdParams[0] || '').replace(/-/g, '_');
  const rest = cmdParams.slice(1);

  if (sub === 'get_system_info') return execReply(demo.systemInfo);
  if (sub === 'get_ui_state') return execReply(demo.uiState);
  if (sub === 'get_status') return execReply(demo.uiState.service.tachyon);
  if (sub === 'get_sing_box_status' || sub === 'get_tachyon_core_status' || sub === 'get_engine_status') {
    return execReply(demo.uiState.service.tachyon_core);
  }
  if (sub === 'get_watchdog_status') return execReply(demo.uiState.service.watchdog);
  if (sub === 'ai_status' || sub === 'ai_status_full') {
    return execReply({ running: 1, enabled: true, healthy: true, anomalies: [], restarts_last_24h: 0 });
  }
  if (sub === 'get_connections') return execReply(demo.clashConnections);
  if (sub === 'core_telemetry_snapshot') return execReply(demo.coreTelemetrySnapshot);
  if (sub === 'dns_block_stats') return execReply(demo.dnsBlockStats);
  if (sub === 'lan_clients') return execReply(demo.lanDevices);
  if (sub === 'get_tailscale_peers' || sub === 'tailscale_peers') return execReply(demo.tailscalePeers);
  if (sub === 'component_update_check_cache') return execReply(demo.updateCheckCache);
  if (sub === 'component_list_releases') {
    const comp = String(rest[0] || 'tachyon') === 'tachyon' ? 'tachyon' : 'tachyon-core';
    return execReply(demo.releasesMap[comp] || []);
  }
  if (sub === 'doctor' || sub === 'diagnose_json') return execReply(demo.doctorReport);
  if (sub === 'ai_doctor_last' || sub === 'ai_doctor') return execReply(demo.aiDoctorReport);
  if (sub === 'check_dns_available') {
    return execReply({ ok: true, success: true, details: 'DoH 1.1.1.1 / dns.google reachable (15 ms)' });
  }
  if (sub === 'check_tachyon_core') {
    return execReply({ ok: true, success: true, running: 1, version: '0.6.3' });
  }
  if (sub === 'check_nft' || sub === 'check_nft_rules') {
    return execReply({ ok: true, success: true, table: 'inet TachyonTable', rules_count: 24 });
  }
  if (sub === 'check_fakeip') {
    return execReply({ ok: true, success: true, ipv4: '198.18.0.14', ipv6: 'fc00::14' });
  }
  if (sub === 'check_inbounds' || sub === 'check_inbounds_config') {
    return execReply({ ok: true, success: true, enabled_count: 2, firewall_synced: true });
  }
  if (sub === 'dns_speed_test_start' || sub === 'dns_speed_test_status' || sub === 'dns_benchmark_status') {
    return execReply(demo.dnsSpeedState);
  }
  if (sub === 'telegram_status') {
    return [0, { code: 0, stdout: 'running (pid 1842) @tachyon_router_demo_bot\n', stderr: '' }];
  }
  if (sub === 'get_subscription_metadata') {
    return execReply([
      {
        source_id: 'src_sub',
        name: 'EU Cluster Subscription',
        node_count: 6,
        countries: ['NL', 'DE', 'FI'],
        used_bytes: 42949672960,
        total_bytes: 214748364800,
        expire: Math.floor(Date.now() / 1000) + 86400 * 24,
      },
    ]);
  }
  if (sub === 'clash_api') {
    const action = String(rest[0] || '');
    if (action === 'get_proxies') return execReply(demo.clashProxies);
    if (action === 'get_connections') return execReply(demo.clashConnections);
    if (action === 'get_proxy_delay') return execReply({ delay: 38 });
    if (action === 'get_group_latency') return execReply({ 'NL-Amsterdam': 42, 'FI-Helsinki': 29, 'AmneziaWG 3.1 DE': 38 });
    if (action === 'get_switch_history') return execReply({ events: [] });
  }
  return null;
}

function createProxyShim({ daemonPort, cacheDir, luciBaseUrl, luciBaseDir, demo, isShuttingDown }) {
  return new Promise((resolve, reject) => {
    const server = http.createServer(async (req, res) => {
      try {
        const reqUrl = req.url || '/';
        const urlPath = reqUrl.split('?')[0];

        if (req.method === 'GET' && urlPath.startsWith('/luci-static/') && !urlPath.startsWith('/luci-static/resources/view/tachyon/')) {
          const rel = urlPath.slice('/luci-static/'.length);
          const asset = await fetchLuciStatic(rel, cacheDir, luciBaseUrl, luciBaseDir);
          if (asset) {
            res.writeHead(200, { 'Content-Type': asset.contentType, 'Cache-Control': 'public, max-age=300' });
            res.end(asset.buf);
            return;
          }
          if (!isShuttingDown?.()) console.error(`[shim 404 static] ${reqUrl}`);
          res.writeHead(404);
          res.end('Not Found');
          return;
        }

        const chunks = [];
        for await (const chunk of req) chunks.push(chunk);
        const bodyBuf = Buffer.concat(chunks);

        if (req.method === 'POST' && (urlPath === '/ubus' || urlPath === '/ubus/' || urlPath === '/cgi-bin/luci/admin/ubus')) {
          let reqJson = null;
          try {
            reqJson = JSON.parse(bodyBuf.toString('utf8'));
          } catch {
            reqJson = null;
          }

          if (Array.isArray(reqJson)) {
            const finalReplies = new Array(reqJson.length);
            const passthroughItems = [];
            const passthroughIdx = [];

            for (let i = 0; i < reqJson.length; i++) {
              const reqItem = reqJson[i];
              const mockRes = tryMockUbusItem(reqItem, demo);
              if (mockRes !== null) {
                finalReplies[i] = { jsonrpc: reqItem?.jsonrpc || '2.0', id: reqItem?.id ?? null, result: mockRes };
              } else {
                passthroughIdx.push(i);
                passthroughItems.push(reqItem);
              }
            }

            if (passthroughItems.length === 0) {
              res.writeHead(200, { 'Content-Type': 'application/json' });
              res.end(JSON.stringify(finalReplies));
              return;
            }

            const upstreamRes = await fetch(`http://127.0.0.1:${daemonPort}${reqUrl}`, {
              method: 'POST',
              headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify(passthroughItems),
            });
            const upstreamJson = await upstreamRes.json();
            if (Array.isArray(upstreamJson)) {
              for (let j = 0; j < passthroughIdx.length; j++) {
                finalReplies[passthroughIdx[j]] = upstreamJson[j];
              }
            }
            res.writeHead(upstreamRes.status, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify(finalReplies));
            return;
          }

          if (reqJson && typeof reqJson === 'object') {
            const mockRes = tryMockUbusItem(reqJson, demo);
            if (mockRes !== null) {
              res.writeHead(200, { 'Content-Type': 'application/json' });
              res.end(JSON.stringify({ jsonrpc: reqJson.jsonrpc || '2.0', id: reqJson.id ?? null, result: mockRes }));
              return;
            }
          }
        }

        const upstreamRes = await fetch(`http://127.0.0.1:${daemonPort}${reqUrl}`, {
          method: req.method,
          headers: { 'Content-Type': req.headers['content-type'] || 'application/json' },
          body: req.method === 'GET' || req.method === 'HEAD' ? undefined : bodyBuf,
        });

        const respBuf = Buffer.from(await upstreamRes.arrayBuffer());
        const ctype = upstreamRes.headers.get('content-type') || 'application/octet-stream';

        res.writeHead(upstreamRes.status, { 'Content-Type': ctype });
        res.end(respBuf);
        if (upstreamRes.status >= 400 && !isShuttingDown?.()) {
          console.error(`[shim ${upstreamRes.status}] ${req.method} ${reqUrl}`);
        }
      } catch (err) {
        if (!isShuttingDown?.()) {
          console.error(`[shim 502] ${req.method} ${req.url}:`, err?.message || err);
        }
        if (!res.headersSent) {
          res.writeHead(502, { 'Content-Type': 'text/plain' });
          res.end(String(err));
        }
      }
    });

    server.on('error', reject);
    server.listen(0, '127.0.0.1', () => {
      const addr = server.address();
      resolve({ server, port: typeof addr === 'object' && addr ? addr.port : 0 });
    });
  });
}

class CdpClient {
  constructor(ws) {
    this.ws = ws;
    this.nextId = 1;
    this.pending = new Map();
    this.events = [];
    ws.addEventListener('message', (ev) => {
      const msg = JSON.parse(String(ev.data));
      if (msg.id && this.pending.has(msg.id)) {
        const { resolve, reject } = this.pending.get(msg.id);
        this.pending.delete(msg.id);
        if (msg.error) reject(new Error(`${msg.error.code}: ${msg.error.message}`));
        else resolve(msg.result);
      } else if (msg.method) {
        if (msg.method === 'Runtime.consoleAPICalled' || msg.method === 'Runtime.exceptionThrown') {
          this.events.push(msg);
        }
      }
    });
  }

  static async connect(wsUrl) {
    const ws = new WebSocket(wsUrl);
    await new Promise((resolve, reject) => {
      ws.addEventListener('open', resolve, { once: true });
      ws.addEventListener('error', (e) => reject(e.error || new Error('CDP WebSocket error')), { once: true });
    });
    return new CdpClient(ws);
  }

  send(method, params = {}) {
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.ws.send(JSON.stringify({ id, method, params }));
    });
  }

  async evaluate(expression) {
    const res = await this.send('Runtime.evaluate', {
      expression,
      awaitPromise: true,
      returnByValue: true,
    });
    if (res?.exceptionDetails) {
      throw new Error(`Eval error: ${JSON.stringify(res.exceptionDetails)}`);
    }
    return res?.result?.value;
  }

  close() {
    try {
      this.ws.close();
    } catch {
      // ignore
    }
  }
}

async function launchChromeCdp(chromePath, profileDir) {
  const proc = spawn(
    chromePath,
    [
      '--headless=new',
      '--disable-gpu',
      '--no-sandbox',
      '--hide-scrollbars',
      '--remote-debugging-port=0',
      `--user-data-dir=${profileDir}`,
      'about:blank',
    ],
    { stdio: ['ignore', 'ignore', 'pipe'] },
  );

  const wsBrowserUrl = await new Promise((resolve, reject) => {
    let stderr = '';
    const timer = setTimeout(() => reject(new Error(`Chrome CDP timeout. stderr=${stderr}`)), 15000);
    proc.stderr.on('data', (chunk) => {
      stderr += chunk.toString('utf8');
      const m = stderr.match(/DevTools listening on (ws:\/\/[^\s]+)/);
      if (m) {
        clearTimeout(timer);
        resolve(m[1]);
      }
    });
    proc.on('exit', (code) => {
      clearTimeout(timer);
      reject(new Error(`Chrome exited early (${code}). stderr=${stderr}`));
    });
  });

  const browserCdp = await CdpClient.connect(wsBrowserUrl);
  const { targetId } = await browserCdp.send('Target.createTarget', { url: 'about:blank' });
  const browserUrl = new URL(wsBrowserUrl);
  const pageWsUrl = `ws://${browserUrl.host}/devtools/page/${targetId}`;
  const pageCdp = await CdpClient.connect(pageWsUrl);
  await pageCdp.send('Page.enable');
  await pageCdp.send('Runtime.enable');
  await pageCdp.send('Emulation.setDeviceMetricsOverride', {
    width: 1600,
    height: 960,
    deviceScaleFactor: 2,
    mobile: false,
  });
  await pageCdp.send('Emulation.setEmulatedMedia', {
    media: 'screen',
    features: [{ name: 'prefers-color-scheme', value: 'dark' }],
  });
  await pageCdp.send('Page.addScriptToEvaluateOnNewDocument', {
    source: `
      try {
        localStorage.setItem('tachyon_ui_mode_v1', 'advanced');
        localStorage.setItem('tachyon_sidebar_pos_v1', 'top');
        localStorage.removeItem('tachyon_dismissed_update_sig_v1');
      } catch (e) {}
    `,
  });

  return { proc, browserCdp, pageCdp };
}

async function waitForCondition(pageCdp, jsExpr, timeoutMs = 15000) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    const ok = await pageCdp.evaluate(`Boolean(${jsExpr})`).catch(() => false);
    if (ok) return true;
    await sleep(120);
  }
  return false;
}

const NAV_PARENT_BY_KEY = {
  'section:sections': 'routing',
  'section:outbounds': 'routing',
  'section:conditions': 'routing',
  'section:balancers': 'routing',
  profile: 'clients',
  schedule: 'clients',
  guest_mode: 'clients',
  server: 'clients',
  diagnostic: 'analytics',
  monitoring: 'analytics',
  'settings:navigation': 'system',
  'settings:dns': 'system',
  'settings:network': 'system',
  'settings:services': 'system',
  updates: 'system',
  'settings:updates': 'system',
  'settings:ai': 'system',
  telegram: 'system',
  'settings:advanced': 'system',
};

async function clickNav(pageCdp, navKey) {
  const tryClick = async () =>
    pageCdp.evaluate(`(() => {
      const el = document.querySelector('.tachyon-global-subtabs li[data-nav-key="${navKey}"] > a')
        || document.querySelector('.tachyon-sidebar__subitem[data-nav-key="${navKey}"]')
        || document.querySelector('.tachyon-sidebar__nav-item[data-nav-key="${navKey}"]')
        || document.querySelector('[data-nav-key="${navKey}"] > a')
        || document.querySelector('[data-nav-key="${navKey}"]');
      if (!el) return false;
      el.click();
      return true;
    })()`);

  let clicked = await tryClick();
  if (!clicked && NAV_PARENT_BY_KEY[navKey]) {
    const parentId = NAV_PARENT_BY_KEY[navKey];
    const parentClicked = await pageCdp.evaluate(`(() => {
      const p = document.querySelector('.tachyon-sidebar__nav-parent[data-parent-menu="${parentId}"]');
      if (!p) return false;
      p.click();
      return true;
    })()`);
    if (parentClicked) {
      await sleep(250);
      clicked = await tryClick();
    }
  }
  if (!clicked) throw new Error(`Navigation item not found: ${navKey}`);
  await pageCdp.evaluate(`(() => {
    const sc = document.querySelector('.tachyon-workspace-body') || document.scrollingElement;
    if (sc) sc.scrollTop = 0;
    window.scrollTo(0, 0);
  })()`);
  await sleep(500);
}

async function closeAnyModal(pageCdp) {
  await pageCdp.evaluate(`(() => {
    const closeBtns = document.querySelectorAll('.tachyon-wizard__close, #modal_overlay .cbi-button-negative, #modal_overlay button[data-action="cancel"], .cbi-modal .tachyon-modal-close');
    for (const b of closeBtns) b.click();
    if (typeof ui !== 'undefined' && typeof ui.hideModal === 'function') ui.hideModal();
    document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
  })()`);
  await sleep(250);
}

async function captureWebp(pageCdp, destPath) {
  const { data } = await pageCdp.send('Page.captureScreenshot', {
    format: 'webp',
    quality: 90,
  });
  const buf = Buffer.from(data, 'base64');
  if (buf.subarray(0, 4).toString('ascii') === 'RIFF' && buf.subarray(8, 12).toString('ascii') === 'WEBP') {
    fs.mkdirSync(path.dirname(destPath), { recursive: true });
    fs.writeFileSync(destPath, buf);
    return;
  }
  // Fallback via python Pillow if Chrome returned PNG
  const tmpPng = `${destPath}.tmp.png`;
  fs.mkdirSync(path.dirname(destPath), { recursive: true });
  fs.writeFileSync(tmpPng, buf);
  const pyRes = spawnSync(
    'python',
    ['-c', `from PIL import Image; Image.open(${JSON.stringify(tmpPng)}).save(${JSON.stringify(destPath)}, "WEBP", quality=90)`],
    { encoding: 'utf8' },
  );
  fs.rmSync(tmpPng, { force: true });
  if (pyRes.status !== 0) {
    throw new Error(`WebP conversion failed: ${pyRes.stderr}`);
  }
}

async function captureLanguage(lang, opts, chromePath) {
  const tmpBase = fs.mkdtempSync(path.join(os.tmpdir(), `tachyon-docs-${lang}-`));
  const dataDir = path.join(tmpBase, 'data');
  const profileDir = path.join(tmpBase, 'chrome-profile');
  const cacheDir = path.join(os.tmpdir(), 'tachyon-luci-base-cache');
  fs.mkdirSync(dataDir, { recursive: true });
  fs.mkdirSync(profileDir, { recursive: true });
  fs.mkdirSync(path.join(dataDir, 'rulesets'), { recursive: true });

  const daemonPort = await getFreePort();
  const demoStore = buildDemoStoreData(lang, daemonPort, dataDir);
  const demoConfigSections = buildDemoConfigSections(lang);
  fs.writeFileSync(path.join(dataDir, 'tachyon.json'), JSON.stringify(demoStore, null, 2), 'utf8');
  fs.writeFileSync(path.join(dataDir, 'config_sections.json'), JSON.stringify(demoConfigSections, null, 2), 'utf8');

  let shuttingDown = false;
  const daemon = spawn(opts.bin, ['daemon'], {
    cwd: REPO_ROOT,
    env: { ...process.env, TACHYON_DATA_DIR: dataDir },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  let daemonStderr = '';
  daemon.stdout.on('data', (d) => { daemonStderr += d.toString('utf8'); });
  daemon.stderr.on('data', (d) => { daemonStderr += d.toString('utf8'); });
  daemon.on('exit', (code, sig) => {
    if (!shuttingDown) {
      console.error(`[daemon exit] code=${code} sig=${sig}\n${daemonStderr}`);
    }
  });

  const demo = buildDemoTelemetry(lang);
  let shim = null;
  let chrome = null;

  try {
    await waitForHttp(`http://127.0.0.1:${daemonPort}/favicon.svg`, 15000).catch((e) => {
      throw new Error(`${e.message}\nDaemon stderr:\n${daemonStderr}`);
    });
    shim = await createProxyShim({
      daemonPort,
      cacheDir,
      luciBaseUrl: opts.luciBaseUrl,
      luciBaseDir: opts.luciBaseDir,
      demo,
      isShuttingDown: () => shuttingDown,
    });
    chrome = await launchChromeCdp(chromePath, profileDir);
    const { pageCdp } = chrome;

    await pageCdp.send('Page.navigate', { url: `http://127.0.0.1:${shim.port}/` });
    const booted = await waitForCondition(
      pageCdp,
      `document.querySelector('.tachyon-sidebar') && document.querySelector('#cbi-tachyon-dashboard') && !document.querySelector('.tachyon-boot-loader')`,
      20000,
    );
    if (!booted) {
      const mainText = await pageCdp.evaluate(`document.querySelector('#maincontent')?.innerText || ''`).catch(() => '');
      const diagInfo = await pageCdp.evaluate(`JSON.stringify({
        hasLuCI: typeof LuCI !== 'undefined',
        hasL: typeof L !== 'undefined',
        hasSidebar: Boolean(document.querySelector('.tachyon-sidebar')),
        hasDash: Boolean(document.querySelector('#cbi-tachyon-dashboard')),
        hasLoader: Boolean(document.querySelector('.tachyon-boot-loader')),
      })`).catch(() => '');
      throw new Error(`UI failed to boot within 25s (${lang}). diag=${diagInfo}\nmainText=${mainText}\nevents=${JSON.stringify(pageCdp.events.slice(0, 15))}`);
    }
    await waitForCondition(
      pageCdp,
      `document.querySelector('.tachyon-update-banner:not(.is-hidden)')`,
      8000,
    );
    await sleep(900);

    const outLangDir = path.join(opts.outDir, lang);
    const shouldCapture = (slug) => !opts.only || opts.only === slug;

    const shots = [
      {
        slug: '01-dashboard',
        run: async () => {
          await clickNav(pageCdp, 'dashboard');
          await waitForCondition(
            pageCdp,
            `document.querySelector('#dashboard-sections-grid [data-section-row-metrics], #dashboard-sections-grid .dashboard-sections-grid-item') && !document.querySelector('#dashboard-sections-grid .tachyon-skeleton, #dashboard-sections-grid .shimmer')`,
            8000,
          );
          await sleep(500);
        },
      },
      {
        slug: '02-quick-wizard',
        run: async () => {
          await clickNav(pageCdp, 'dashboard');
          await pageCdp.evaluate(`document.querySelector('.tachyon-topbar__wizard-btn')?.click()`);
          await waitForCondition(pageCdp, `document.querySelector('.tachyon-wizard')`, 5000);
          await sleep(400);
        },
        after: async () => closeAnyModal(pageCdp),
      },
      {
        slug: '03-sections',
        run: async () => {
          await clickNav(pageCdp, 'section:sections');
          await waitForCondition(pageCdp, `document.querySelector('#cbi-tachyon-section .tachyon-studio-card')`, 5000);
          await sleep(450);
        },
      },
      {
        slug: '04-outbounds',
        run: async () => {
          await clickNav(pageCdp, 'section:outbounds');
          await waitForCondition(pageCdp, `[data-subtab="outbounds"] .tachyon-studio-card`, 5000);
          await sleep(450);
        },
      },
      {
        slug: '05-outbound-modal',
        run: async () => {
          await clickNav(pageCdp, 'section:outbounds');
          await waitForCondition(pageCdp, `[data-subtab="outbounds"] .tachyon-studio-action-btn--primary`, 5000);
          await pageCdp.evaluate(`document.querySelector('[data-subtab="outbounds"] .tachyon-studio-action-btn--primary')?.click()`);
          await waitForCondition(pageCdp, `document.querySelector('#modal_overlay .cbi-modal, .cbi-modal')`, 5000);
          await sleep(450);
        },
        after: async () => closeAnyModal(pageCdp),
      },
      {
        slug: '06-conditions',
        run: async () => {
          await clickNav(pageCdp, 'section:conditions');
          await sleep(450);
        },
      },
      {
        slug: '07-balancers',
        run: async () => {
          await clickNav(pageCdp, 'section:balancers');
          await sleep(450);
        },
      },
      {
        slug: '08-dns-settings',
        run: async () => {
          await clickNav(pageCdp, 'settings:dns');
          await sleep(500);
        },
      },
      {
        slug: '09-dns-speed-test',
        run: async () => {
          await clickNav(pageCdp, 'settings:dns');
          await waitForCondition(pageCdp, `document.querySelector('.tachyon-dns-speed-value')`, 5000);
          await pageCdp.evaluate(`(() => {
            const btn = document.querySelector('.tachyon-dns-speed-value');
            if (btn) btn.click();
          })()`);
          await waitForCondition(pageCdp, `document.querySelector('#modal_overlay .tachyon-dns-speed-results, .cbi-modal .tachyon-dns-speed-results')`, 5000);
          await sleep(450);
        },
        after: async () => closeAnyModal(pageCdp),
      },
      {
        slug: '10-inbound-servers',
        run: async () => {
          await clickNav(pageCdp, 'server');
          await sleep(500);
        },
      },
      {
        slug: '11-profiles-parental',
        run: async () => {
          await clickNav(pageCdp, 'profile');
          await sleep(450);
        },
      },
      {
        slug: '12-guest-mode',
        run: async () => {
          await clickNav(pageCdp, 'guest_mode');
          await sleep(450);
        },
      },
      {
        slug: '13-monitoring',
        run: async () => {
          await clickNav(pageCdp, 'monitoring');
          await waitForCondition(
            pageCdp,
            `!document.querySelector('.tachyon_monitoring-page__state--loading') && document.querySelectorAll('.tachyon_monitoring-page tbody tr, .tachyon_monitoring-page__row').length > 0`,
            12000,
          );
          await sleep(600);
        },
      },
      {
        slug: '14-diagnostics-ai',
        run: async () => {
          await clickNav(pageCdp, 'diagnostic');
          await waitForCondition(
            pageCdp,
            `!(document.body.innerText || '').includes('Core RSS: 0 B')`,
            6000,
          );
          await sleep(700);
        },
      },
      {
        slug: '15-telegram-bot',
        run: async () => {
          await clickNav(pageCdp, 'telegram');
          await sleep(550);
        },
      },
      {
        slug: '16-updates',
        run: async () => {
          await clickNav(pageCdp, 'updates');
          await sleep(900);
        },
      },
      {
        slug: '17-settings-updates-channel',
        run: async () => {
          await clickNav(pageCdp, 'settings:updates');
          await pageCdp.evaluate(`(() => {
            const el = document.querySelector('[data-name="component_update_channel"], select[name*="component_update_channel"]');
            if (el) el.scrollIntoView({ behavior: 'instant', block: 'center' });
          })()`);
          await sleep(500);
        },
      },
      {
        slug: '18-settings-network-advanced',
        run: async () => {
          await clickNav(pageCdp, 'settings:network');
          await sleep(500);
        },
      },
    ];

    for (const s of shots) {
      if (!shouldCapture(s.slug)) continue;
      await s.run();
      const dest = path.join(outLangDir, `${s.slug}.webp`);
      await captureWebp(pageCdp, dest);
      const sz = fs.statSync(dest).size;
      console.log(`[${lang}] captured ${s.slug}.webp (${sz} bytes)`);
      if (s.after) await s.after();
    }
  } finally {
    shuttingDown = true;
    if (chrome) {
      chrome.pageCdp?.close();
      chrome.browserCdp?.close();
      try {
        chrome.proc.kill();
      } catch {
        // ignore
      }
      await sleep(150);
    }
    if (shim?.server) {
      await new Promise((r) => shim.server.close(r));
    }
    try {
      daemon.kill();
    } catch {
      // ignore
    }
    await sleep(300);
    fs.rmSync(tmpBase, { recursive: true, force: true });
  }
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  if (!fs.existsSync(opts.bin)) {
    throw new Error(`tachyon binary not found at ${opts.bin}. Build it first with: cargo build --bin tachyon`);
  }
  const chromePath = findChromeBinary(opts.chrome);
  const langs = opts.lang === 'all' ? ['ru', 'en'] : [opts.lang];
  for (const l of langs) {
    if (l !== 'ru' && l !== 'en') throw new Error(`Unsupported lang: ${l}`);
    await captureLanguage(l, opts, chromePath);
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
