use super::*;
use crate::store::{PortableAtomicU64, RoutingSection};
use std::path::PathBuf;
use std::sync::atomic::Ordering;

static TEST_DIR_SEQ: PortableAtomicU64 = PortableAtomicU64::new(1);

fn prompt_test_lock() -> &'static tokio::sync::Mutex<()> {
    static LOCK: OnceLock<tokio::sync::Mutex<()>> = OnceLock::new();
    LOCK.get_or_init(|| tokio::sync::Mutex::new(()))
}

fn override_test_lock() -> &'static std::sync::Mutex<()> {
    static LOCK: OnceLock<std::sync::Mutex<()>> = OnceLock::new();
    LOCK.get_or_init(|| std::sync::Mutex::new(()))
}

struct RuntimeOverrideReset;

impl Drop for RuntimeOverrideReset {
    fn drop(&mut self) {
        set_runtime_override(None);
    }
}

struct TempTestEnv {
    dir: PathBuf,
    state: Arc<AppState>,
    core: Arc<CoreManager>,
}

impl TempTestEnv {
    async fn new(tag: &str, admin_id: i64) -> Self {
        let seq = TEST_DIR_SEQ.fetch_add(1, Ordering::Relaxed);
        let dir = std::env::temp_dir().join(format!(
            "tachyon_tg_test_{tag}_{}_{}_{seq}",
            std::process::id(),
            crate::store::unix_now_secs()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("create temp test dir");

        let state_path = dir.join("tachyon-state.json");
        let state = AppState::load_or_create(&state_path).expect("load_or_create temp AppState");

        {
            let mut d = state.data.write().await;
            d.settings.core_bin_path = dir
                .join("missing-tachyon-core")
                .to_string_lossy()
                .to_string();
            d.settings.core_config_path =
                dir.join("core-config.json").to_string_lossy().to_string();
            d.settings.cache_path = dir.join("cache.db").to_string_lossy().to_string();
            d.settings.rulesets_dir = dir.join("rulesets").to_string_lossy().to_string();
            d.telegram.enabled = true;
            d.telegram.bot_token = "123456:TEST_BOT_TOKEN_UNIT".to_string();
            d.telegram.admin_ids = vec![admin_id];
            d.telegram.router_name = "TestRouter".to_string();
            d.telegram.language = "en".to_string();

            let sec_main = RoutingSection {
                id: "main".to_string(),
                enabled: true,
                label: "Main".to_string(),
                connection_type: "proxy".to_string(),
                domains: vec!["example.com".to_string()],
                ..Default::default()
            };

            let sec_desync = RoutingSection {
                id: "desync1".to_string(),
                enabled: true,
                label: "Desync Media".to_string(),
                connection_type: "desync".to_string(),
                desync_preset: "standard".to_string(),
                ..Default::default()
            };

            d.sections = vec![sec_main, sec_desync];
        }

        let core = CoreManager::new(Arc::clone(&state));
        Self { dir, state, core }
    }
}

impl Drop for TempTestEnv {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

#[test]
fn test_enforce_outbox_limit_keeps_newest_50_files() {
    let seq = TEST_DIR_SEQ.fetch_add(1, Ordering::Relaxed);
    let dir = std::env::temp_dir().join(format!(
        "tachyon_tg_outbox_{}_{}_{seq}",
        std::process::id(),
        crate::store::unix_now_secs()
    ));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("create outbox temp dir");

    for i in 1..=55u64 {
        let p = dir.join(format!("1700000000_{i}.txt"));
        std::fs::write(&p, format!("msg {i}")).expect("write outbox msg");
    }
    std::fs::write(dir.join("keep.lock"), b"1").expect("write lock");

    enforce_outbox_limit(&dir, TG_OUTBOX_MAX_FILES);

    let mut remaining: Vec<String> = std::fs::read_dir(&dir)
        .expect("read outbox dir")
        .filter_map(|e| e.ok())
        .filter_map(|e| e.file_name().into_string().ok())
        .filter(|name| name.ends_with(".txt"))
        .collect();
    remaining.sort_by(|a, b| parse_outbox_sort_key(a).cmp(&parse_outbox_sort_key(b)));

    assert_eq!(remaining.len(), 50);
    assert_eq!(
        remaining.first().map(String::as_str),
        Some("1700000000_6.txt")
    );
    assert_eq!(
        remaining.last().map(String::as_str),
        Some("1700000000_55.txt")
    );
    assert!(dir.join("keep.lock").exists());

    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn test_escape_html_escapes_special_chars() {
    assert_eq!(
        escape_html(r#"<script attr="x">a & b > c</script>"#),
        "&lt;script attr=&quot;x&quot;&gt;a &amp; b &gt; c&lt;/script&gt;"
    );
    assert_eq!(
        escape_html("plain-ascii_123 Привет"),
        "plain-ascii_123 Привет"
    );
    assert_eq!(escape_html(""), "");
}

#[test]
fn test_cb_btn_direct_and_tokenized_with_cap_512() {
    // 60 bytes goes verbatim
    let exact_60 = "a".repeat(60);
    let btn_60 = cb_btn("Exact60", &exact_60);
    assert_eq!(btn_60["callback_data"].as_str(), Some(exact_60.as_str()));
    assert_eq!(resolve_callback_data(&exact_60), exact_60);

    // 61+ bytes is tokenized as @t:... <= 64 bytes and resolves back
    let cmd_65 = "sec_view ".to_string() + &"z".repeat(56);
    assert!(cmd_65.len() > 60);
    let btn_tok = cb_btn("Long", &cmd_65);
    let cb_data = btn_tok["callback_data"]
        .as_str()
        .expect("tokenized callback_data string");
    assert!(cb_data.starts_with("@t:"));
    assert!(cb_data.len() <= 64);
    assert_eq!(resolve_callback_data(cb_data), cmd_65);

    // Duplicate command reuses same token
    let btn_dup = cb_btn("LongDup", &cmd_65);
    assert_eq!(btn_dup["callback_data"].as_str(), Some(cb_data));

    // >600 distinct long commands must keep callback_token_store capped at <= 512 without panic
    let prefix = format!(
        "long_cap_test_{}_{}_",
        std::process::id(),
        TEST_DIR_SEQ.fetch_add(1, Ordering::Relaxed)
    );
    let mut keys = Vec::with_capacity(610);
    for i in 0..610u32 {
        let cmd = format!("{prefix}{i:04}_{}", "x".repeat(48));
        let btn = cb_btn("Cap", &cmd);
        let tok = btn["callback_data"]
            .as_str()
            .expect("cap callback token")
            .to_string();
        assert!(tok.starts_with("@t:"));
        assert!(tok.len() <= 64);
        keys.push((tok, cmd));
    }

    {
        let guard = callback_token_store()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        assert!(guard.map.len() <= MAX_CB_TOKENS);
        assert!(guard.rev.len() <= MAX_CB_TOKENS);
        assert!(guard.order.len() <= MAX_CB_TOKENS);
    }

    // Oldest entry evicted, newest entry intact
    let (first_tok, _) = &keys[0];
    let (last_tok, last_cmd) = keys.last().expect("last key");
    assert_eq!(resolve_callback_data(first_tok), *first_tok);
    assert_eq!(resolve_callback_data(last_tok), *last_cmd);
}

#[tokio::test]
async fn test_chat_prompt_cap_and_expiry() {
    let _guard = prompt_test_lock().lock().await;

    let base_chat: i64 = 910_000;
    for i in 0..45i64 {
        set_chat_prompt(base_chat + i, PendingPromptKind::AiDoctorQuestion);
    }

    {
        let map = chat_prompt_store()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        assert!(map.len() <= MAX_CHAT_STATES);
    }

    // Oldest of the 45 entries was evicted while newest remained
    assert!(peek_chat_prompt(base_chat).is_none());
    assert_eq!(
        peek_chat_prompt(base_chat + 44),
        Some(PendingPromptKind::AiDoctorQuestion)
    );
    assert_eq!(
        take_chat_prompt(base_chat + 44),
        Some(PendingPromptKind::AiDoctorQuestion)
    );
    assert!(take_chat_prompt(base_chat + 44).is_none());

    // Expired prompt entry must be purged on access
    let expired_chat: i64 = 999_991;
    {
        let mut map = chat_prompt_store()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        map.insert(
            expired_chat,
            PromptEntry {
                kind: PendingPromptKind::SetRouterName,
                expires_at: Instant::now() - Duration::from_secs(5),
                seq: 0,
            },
        );
    }
    assert!(peek_chat_prompt(expired_chat).is_none());
    assert!(take_chat_prompt(expired_chat).is_none());

    for i in 0..45i64 {
        clear_chat_prompt(base_chat + i);
    }
}

#[test]
fn test_resolve_tg_proxy_url_modes() {
    let mut d = RouterStoreData::default();
    let sec_main = RoutingSection {
        id: "main_id".to_string(),
        label: "Main".to_string(),
        enabled: true,
        ..Default::default()
    };

    let sec_mixed = RoutingSection {
        id: "mixed_sec".to_string(),
        label: "Mixed".to_string(),
        enabled: true,
        mixed_proxy_enabled: true,
        mixed_proxy_port: 10809,
        mixed_proxy_auth_enabled: false,
        ..Default::default()
    };

    let sec_disabled = RoutingSection {
        id: "off_sec".to_string(),
        label: "Off".to_string(),
        enabled: false,
        mixed_proxy_enabled: true,
        mixed_proxy_port: 10810,
        ..Default::default()
    };

    d.sections = vec![sec_main, sec_mixed, sec_disabled];

    // Empty ("") -> service-mixed-in:4534 when core running, None otherwise
    d.telegram.bot_proxy_section.clear();
    assert_eq!(
        resolve_tg_proxy_url(&d, true).as_deref(),
        Some("http://127.0.0.1:4534")
    );
    assert_eq!(resolve_tg_proxy_url(&d, false), None);

    // "direct" -> None even when core running
    d.telegram.bot_proxy_section = "direct".to_string();
    assert_eq!(resolve_tg_proxy_url(&d, true), None);
    d.telegram.bot_proxy_section = "DIRECT".to_string();
    assert_eq!(resolve_tg_proxy_url(&d, true), None);

    // Section by label ("Main") without dedicated mixed proxy -> tg-bot-in:4535
    d.telegram.bot_proxy_section = "Main".to_string();
    assert_eq!(
        resolve_tg_proxy_url(&d, true).as_deref(),
        Some("http://127.0.0.1:4535")
    );
    assert_eq!(resolve_tg_proxy_url(&d, false), None);

    // Section with unauthenticated mixed proxy -> custom port
    d.telegram.bot_proxy_section = "mixed_sec".to_string();
    assert_eq!(
        resolve_tg_proxy_url(&d, true).as_deref(),
        Some("http://127.0.0.1:10809")
    );
    assert_eq!(
        resolve_tg_proxy_url(&d, false).as_deref(),
        Some("http://127.0.0.1:10809")
    );

    // Authenticated mixed proxy falls back to tg-bot-in:4535 when core running
    d.sections[1].mixed_proxy_auth_enabled = true;
    assert_eq!(
        resolve_tg_proxy_url(&d, true).as_deref(),
        Some("http://127.0.0.1:4535")
    );

    // Disabled section falls back to default service-mixed-in:4534
    d.telegram.bot_proxy_section = "off_sec".to_string();
    assert_eq!(
        resolve_tg_proxy_url(&d, true).as_deref(),
        Some("http://127.0.0.1:4534")
    );
}

#[test]
fn test_quiet_hours_overnight_and_daytime() {
    let mins_secs = |h: i64, m: i64| -> i64 { (h * 60 + m) * 60 };

    // Overnight 23:00 .. 07:00
    assert!(is_in_quiet_hours_at(mins_secs(23, 0), "23:00", "07:00"));
    assert!(is_in_quiet_hours_at(mins_secs(23, 30), "23:00", "07:00"));
    assert!(is_in_quiet_hours_at(mins_secs(0, 0), "23:00", "07:00"));
    assert!(is_in_quiet_hours_at(mins_secs(3, 0), "23:00", "07:00"));
    assert!(is_in_quiet_hours_at(mins_secs(6, 59), "23:00", "07:00"));
    assert!(!is_in_quiet_hours_at(mins_secs(7, 0), "23:00", "07:00"));
    assert!(!is_in_quiet_hours_at(mins_secs(12, 0), "23:00", "07:00"));
    assert!(!is_in_quiet_hours_at(mins_secs(22, 59), "23:00", "07:00"));

    // Daytime 09:00 .. 17:00
    assert!(!is_in_quiet_hours_at(mins_secs(8, 59), "09:00", "17:00"));
    assert!(is_in_quiet_hours_at(mins_secs(9, 0), "09:00", "17:00"));
    assert!(is_in_quiet_hours_at(mins_secs(13, 30), "09:00", "17:00"));
    assert!(is_in_quiet_hours_at(mins_secs(16, 59), "09:00", "17:00"));
    assert!(!is_in_quiet_hours_at(mins_secs(17, 0), "09:00", "17:00"));
    assert!(!is_in_quiet_hours_at(mins_secs(21, 0), "09:00", "17:00"));

    // Degenerate or invalid intervals return false
    assert!(!is_in_quiet_hours_at(mins_secs(10, 0), "10:00", "10:00"));
    assert!(!is_in_quiet_hours_at(mins_secs(10, 0), "bad", "07:00"));
}

#[test]
fn test_is_bot_effectively_running_and_override() {
    let _lock = override_test_lock()
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    let _reset = RuntimeOverrideReset;

    let mut d = RouterStoreData::default();
    d.telegram.enabled = false;
    d.telegram.bot_token = "12345:valid-token".to_string();
    d.telegram.admin_ids = vec![42];

    set_runtime_override(None);
    assert!(!is_bot_effectively_running(&d));

    set_runtime_override(Some(true));
    assert!(is_bot_effectively_running(&d));

    set_runtime_override(Some(false));
    assert!(!is_bot_effectively_running(&d));

    d.telegram.enabled = true;
    set_runtime_override(None);
    assert!(is_bot_effectively_running(&d));

    set_runtime_override(Some(false));
    assert!(!is_bot_effectively_running(&d));

    // Missing token or admins prevents running even with override Some(true)
    set_runtime_override(Some(true));
    d.telegram.bot_token.clear();
    assert!(!is_bot_effectively_running(&d));

    d.telegram.bot_token = "12345:valid-token".to_string();
    d.telegram.admin_ids.clear();
    assert!(!is_bot_effectively_running(&d));
}

#[tokio::test]
async fn test_unauthorized_chat_rejected_and_commands_routed() {
    let admin_id: i64 = 111_222_333;
    let intruder_id: i64 = 999_888_777;
    let env = TempTestEnv::new("routing", admin_id).await;

    // Unauthorized chats must receive None for both messages and callbacks
    assert!(
        handle_incoming_text(intruder_id, "/start", &env.state, &env.core)
            .await
            .is_none()
    );
    assert!(
        handle_incoming_callback(intruder_id, "menu", &env.state, &env.core)
            .await
            .is_none()
    );

    // /start -> Main menu
    let start_rep = handle_incoming_text(admin_id, "/start", &env.state, &env.core)
        .await
        .expect("authorized /start reply");
    assert!(!start_rep.text.is_empty());
    assert!(
        start_rep
            .keyboard
            .as_ref()
            .and_then(|k| k.get("inline_keyboard"))
            .is_some()
    );

    // /status -> Core status view
    let status_rep = handle_incoming_text(admin_id, "/status", &env.state, &env.core)
        .await
        .expect("authorized /status reply");
    assert!(status_rep.text.contains("RAM:"));
    assert!(status_rep.keyboard.is_some());

    // /sections -> Routing sections list containing seeded section
    let sec_rep = handle_incoming_text(admin_id, "/sections", &env.state, &env.core)
        .await
        .expect("authorized /sections reply");
    assert!(sec_rep.text.contains("Main"));
    assert!(sec_rep.text.contains("Desync Media"));

    // /doctor -> Local diagnostics
    let doc_rep = handle_incoming_text(admin_id, "/doctor", &env.state, &env.core)
        .await
        .expect("authorized /doctor reply");
    assert!(doc_rep.text.contains("Diagnostics"));
    assert!(doc_rep.keyboard.is_some());

    // /bot_settings -> Bot settings view
    let cfg_rep = handle_incoming_text(admin_id, "/bot_settings", &env.state, &env.core)
        .await
        .expect("authorized /bot_settings reply");
    assert!(cfg_rep.text.contains("TestRouter"));
    assert!(cfg_rep.text.contains("111222333"));

    // /lang ru -> Updates language in store
    let lang_rep = handle_incoming_text(admin_id, "/lang ru", &env.state, &env.core)
        .await
        .expect("authorized /lang reply");
    assert!(lang_rep.text.contains("[OK]"));
    {
        let d = env.state.data.read().await;
        assert_eq!(d.telegram.language, "ru");
    }

    // /trace youtube.com 192.168.1.50 -> Route trace output
    let trace_rep = handle_incoming_text(
        admin_id,
        "/trace youtube.com 192.168.1.50",
        &env.state,
        &env.core,
    )
    .await
    .expect("authorized /trace reply");
    assert!(trace_rep.text.contains("youtube.com"));
    assert!(trace_rep.text.contains("192.168.1.50"));

    // Unknown command returns fallback reply with Main Menu button
    let unknown_rep = handle_incoming_text(admin_id, "/does_not_exist", &env.state, &env.core)
        .await
        .expect("authorized unknown command reply");
    assert!(unknown_rep.keyboard.is_some());
}

#[test]
fn test_ops_apply_desync_strategy_to_section() {
    let mut sec = RoutingSection {
        id: "desync1".to_string(),
        connection_type: "desync".to_string(),
        ..Default::default()
    };

    ops::apply_desync_strategy_to_section(
        &mut sec,
        "mode=hostfakesplit split_pos=sniext+1 fooling=badsum,md5sig ttl=250 repeats=3 seqovl=4 syndata=true tlsrec_first=1 split_delay_ms=900 fake_sni=cdn.example.org sni_pool=a.com,b.com wsize=128 wscale=20 ipfrag=true udp_fake=1 udp_repeats=2 udp_fake_ttl=6 udplen=96 auto_tune=true fake_payload=tls_client_hello fake_tls=0x1603",
    );

    assert_eq!(sec.desync_preset, "custom");
    assert_eq!(sec.desync_mode, "hostfakesplit");
    assert_eq!(sec.desync_split_pos, "sniext+1");
    assert_eq!(sec.desync_fooling, "badsum,md5sig");
    assert_eq!(sec.desync_fake_ttl, 128); // clamped 1..=128
    assert_eq!(sec.desync_repeats, 3);
    assert_eq!(sec.desync_seqovl, 4);
    assert!(sec.desync_syndata);
    assert!(sec.desync_tlsrec_first);
    assert_eq!(sec.desync_split_delay_ms, 500); // clamped <= 500
    assert_eq!(sec.desync_fake_sni, "cdn.example.org");
    assert_eq!(
        sec.desync_sni_pool,
        vec!["a.com".to_string(), "b.com".to_string()]
    );
    assert_eq!(sec.desync_wsize, 128);
    assert_eq!(sec.desync_wscale, Some(14)); // clamped 0..=14
    assert!(sec.desync_ipfrag);
    assert!(sec.desync_udp_fake);
    assert_eq!(sec.desync_udp_repeats, 2);
    assert_eq!(sec.desync_udp_fake_ttl, 6);
    assert_eq!(sec.desync_udplen, 96);
    assert!(sec.desync_auto_tune);
    assert!(sec.desync_host_fake);
    assert_eq!(sec.desync_fake_payload, "tls_client_hello");
    assert_eq!(sec.desync_fake_tls, "0x1603");

    // Re-applying simpler preset clears stale fields from previous strategy
    ops::apply_desync_strategy_to_section(&mut sec, "preset=preset_one mode=multisplit");
    assert_eq!(sec.desync_preset, "preset_one");
    assert_eq!(sec.desync_mode, "multisplit");
    assert_eq!(sec.desync_fake_ttl, 0);
    assert!(!sec.desync_host_fake);
    assert!(!sec.desync_syndata);
    assert!(sec.desync_sni_pool.is_empty());
    assert_eq!(sec.desync_wscale, None);
}

#[test]
fn test_parse_hhmm_boundaries_and_invalid_inputs() {
    assert_eq!(parse_hhmm("00:00"), Some(0));
    assert_eq!(parse_hhmm("07:05"), Some(7 * 60 + 5));
    assert_eq!(parse_hhmm("23:59"), Some(23 * 60 + 59));
    assert_eq!(parse_hhmm(" 09:30 "), Some(9 * 60 + 30));
    assert_eq!(parse_hhmm("0"), Some(0));
    assert_eq!(parse_hhmm("7"), Some(7 * 60));
    assert_eq!(parse_hhmm("23"), Some(23 * 60));

    assert_eq!(parse_hhmm("24"), None);
    assert_eq!(parse_hhmm("24:00"), None);
    assert_eq!(parse_hhmm("12:60"), None);
    assert_eq!(parse_hhmm("-1:00"), None);
    assert_eq!(parse_hhmm("12:ab"), None);
    assert_eq!(parse_hhmm("1230"), None);
    assert_eq!(parse_hhmm(""), None);
}

#[tokio::test]
async fn test_ops_dns_preset_and_bot_settings_persistence() {
    let admin_id: i64 = 222_333_444;
    let env = TempTestEnv::new("settings", admin_id).await;

    // DNS preset update
    let dns_ok = Box::pin(ops::try_handle_ops(
        "dns_preset",
        "cloudflare",
        admin_id,
        &env.state,
        &env.core,
    ))
    .await
    .expect("dns_preset reply");
    assert!(dns_ok.text.contains("[OK]"));
    {
        let d = env.state.data.read().await;
        assert_eq!(d.settings.dns_type, "doh");
        assert!(d.settings.dns_servers.iter().any(|s| s.contains("1.1.1.1")));
    }

    let dns_bad = Box::pin(ops::try_handle_ops(
        "dns_preset",
        "invalid_dns",
        admin_id,
        &env.state,
        &env.core,
    ))
    .await
    .expect("invalid dns_preset reply");
    assert!(dns_bad.text.contains("[ERR]"));

    // Rename router
    let name_rep = Box::pin(ops::try_handle_ops(
        "/name", "Edge-GW", admin_id, &env.state, &env.core,
    ))
    .await
    .expect("/name reply");
    assert!(name_rep.text.contains("[OK]"));
    assert_eq!(env.state.data.read().await.telegram.router_name, "Edge-GW");

    // Toggle quiet hours & update window via prompt handler
    let qt_rep = Box::pin(ops::try_handle_ops(
        "bot_quiet_tog",
        "",
        admin_id,
        &env.state,
        &env.core,
    ))
    .await
    .expect("bot_quiet_tog reply");
    assert!(qt_rep.text.contains("[ON]"));
    assert!(env.state.data.read().await.telegram.quiet_hours_enabled);

    let qw_rep = Box::pin(ops::handle_ops_prompt(
        PendingPromptKind::SetQuietHours,
        "22:30-06:15",
        admin_id,
        &env.state,
        &env.core,
    ))
    .await
    .expect("SetQuietHours prompt reply");
    assert!(qw_rep.text.contains("[OK]"));
    {
        let d = env.state.data.read().await;
        assert_eq!(d.telegram.quiet_hours_start, "22:30");
        assert_eq!(d.telegram.quiet_hours_end, "06:15");
    }

    // Toggle notification field & add admin ID via prompt
    let prev_dns_leak = env.state.data.read().await.telegram.notify_dns_leak;
    let nt_rep = Box::pin(ops::try_handle_ops(
        "bot_notify_tog",
        "notify_dns_leak",
        admin_id,
        &env.state,
        &env.core,
    ))
    .await
    .expect("bot_notify_tog reply");
    assert!(nt_rep.text.contains("DNS") || nt_rep.text.contains("утеч"));
    assert_eq!(
        env.state.data.read().await.telegram.notify_dns_leak,
        !prev_dns_leak
    );

    let adm_rep = Box::pin(ops::handle_ops_prompt(
        PendingPromptKind::AddAdminId,
        "555666777",
        admin_id,
        &env.state,
        &env.core,
    ))
    .await
    .expect("AddAdminId prompt reply");
    assert!(adm_rep.text.contains("[OK]"));
    assert!(
        env.state
            .data
            .read()
            .await
            .telegram
            .admin_ids
            .contains(&555_666_777)
    );
}

#[tokio::test]
async fn test_ops_snapshots_transfer_code_and_lkg_lifecycle() {
    let admin_id: i64 = 333_444_555;
    let env = TempTestEnv::new("snapshots", admin_id).await;

    // Save snapshot with document (/backup)
    let backup_rep = ops::try_handle_ops("/backup", "", admin_id, &env.state, &env.core)
        .await
        .expect("/backup reply");
    assert!(backup_rep.text.contains("[OK]"));
    let doc = backup_rep
        .document
        .expect("/backup should attach snapshot document");
    assert!(doc.filename.ends_with(".tachyon-profile.json"));
    assert!(!doc.bytes.is_empty());

    // List snapshots shows the newly created file
    let list_rep = ops::try_handle_ops("/snapshots", "", admin_id, &env.state, &env.core)
        .await
        .expect("/snapshots reply");
    assert!(list_rep.text.contains("telegram"));

    // Download snapshot doc explicitly
    let doc_rep = ops::try_handle_ops("snap_doc", &doc.filename, admin_id, &env.state, &env.core)
        .await
        .expect("snap_doc reply");
    assert!(doc_rep.document.is_some());

    // Transfer code export produces tachyon://rs2/... (inline when <= 3200 B, document when > 3200 B)
    let code_rep = ops::try_handle_ops("snap_code", "", admin_id, &env.state, &env.core)
        .await
        .expect("snap_code reply");
    let exported_code = if let Some(ref transfer_doc) = code_rep.document {
        assert_eq!(transfer_doc.filename, "tachyon-transfer-code.txt");
        let code = String::from_utf8(transfer_doc.bytes.clone()).expect("utf8 transfer code");
        assert!(code.starts_with("tachyon://rs2/"));
        code
    } else {
        assert!(code_rep.text.contains("tachyon://rs2/"));
        let start = code_rep.text.find("tachyon://rs2/").expect("code start");
        let tail = &code_rep.text[start..];
        let end = tail.find('<').unwrap_or(tail.len());
        tail[..end].to_string()
    };

    // Round-trip import of the generated transfer code succeeds cleanly
    let import_rep = ops::try_handle_ops(
        "quick_import",
        &exported_code,
        admin_id,
        &env.state,
        &env.core,
    )
    .await
    .expect("quick_import reply");
    assert!(import_rep.text.contains("[OK]"));

    // Promote LKG & inspect /lkg
    let lkg_prom = ops::try_handle_ops("lkg_promote", "", admin_id, &env.state, &env.core)
        .await
        .expect("lkg_promote reply");
    assert!(lkg_prom.text.contains("[OK]"));
    assert!(env.state.lkg_path.exists());

    let lkg_view = ops::try_handle_ops("/lkg", "", admin_id, &env.state, &env.core)
        .await
        .expect("/lkg reply");
    assert!(lkg_view.text.contains("Last Known Good"));
    assert!(lkg_view.text.contains("Snapshot present"));

    // Delete snapshot cleans file from disk
    let del_rep = ops::try_handle_ops("snap_del", &doc.filename, admin_id, &env.state, &env.core)
        .await
        .expect("snap_del reply");
    assert!(del_rep.text.contains("[OK]"));
}

#[tokio::test]
async fn test_ops_support_bundle_redacts_secrets() {
    let admin_id: i64 = 444_555_666;
    let env = TempTestEnv::new("support", admin_id).await;
    let secret_token = "999999:SUPER_SECRET_BOT_TOKEN_DO_NOT_LEAK";
    let secret_webhook = "SUPER_SECRET_WEBHOOK_KEY_987";

    {
        let mut d = env.state.data.write().await;
        d.telegram.bot_token = secret_token.to_string();
        d.telegram.webhook_secret = secret_webhook.to_string();
    }

    let rep = ops::try_handle_ops("/support", "", admin_id, &env.state, &env.core)
        .await
        .expect("/support reply");
    let doc = rep.document.expect("support bundle document");
    assert_eq!(doc.filename, "tachyon-support-bundle.json");
    let payload = String::from_utf8(doc.bytes).expect("utf8 json bundle");
    assert!(!payload.contains(secret_token));
    assert!(!payload.contains(secret_webhook));
    assert!(!rep.text.contains(secret_token));
    assert!(payload.contains("[REDACTED]"));
}

#[tokio::test]
async fn test_ops_prompts_dispatch_and_cancel_clear() {
    let _guard = prompt_test_lock().lock().await;
    let admin_id: i64 = 555_666_777;
    let env = TempTestEnv::new("prompts", admin_id).await;

    // Callback trace_prompt sets PendingPromptKind::RouteTraceInput
    let ask_rep = handle_incoming_callback(admin_id, "trace_prompt", &env.state, &env.core)
        .await
        .expect("trace_prompt reply");
    assert!(!ask_rep.text.is_empty());
    assert_eq!(
        peek_chat_prompt(admin_id),
        Some(PendingPromptKind::RouteTraceInput)
    );

    // /cancel clears pending prompt and opens main menu
    let cancel_rep = handle_incoming_text(admin_id, "/cancel", &env.state, &env.core)
        .await
        .expect("/cancel reply");
    assert!(!cancel_rep.text.is_empty());
    assert!(peek_chat_prompt(admin_id).is_none());

    // dns_check without argument prompts DnsCheckInput, then plain text resolves it
    let dns_ask = handle_incoming_callback(admin_id, "dns_check", &env.state, &env.core)
        .await
        .expect("dns_check prompt reply");
    assert!(!dns_ask.text.is_empty());
    assert_eq!(
        peek_chat_prompt(admin_id),
        Some(PendingPromptKind::DnsCheckInput)
    );

    let dns_res = handle_incoming_text(admin_id, "example.com", &env.state, &env.core)
        .await
        .expect("dns_check input reply");
    assert!(dns_res.text.contains("example.com"));
    assert!(peek_chat_prompt(admin_id).is_none());

    clear_chat_prompt(admin_id);
}

#[test]
fn test_transport_split_long_html_and_outbox_sort_key() {
    assert!(parse_outbox_sort_key("1700000000_2.txt") < parse_outbox_sort_key("1700000000_10.txt"));
    assert!(parse_outbox_sort_key("1700000000_99.txt") < parse_outbox_sort_key("1700000001_1.txt"));

    let mut body = String::from("<b>Header</b>\n<pre>");
    for i in 0..220 {
        body.push_str(&format!("line {i:03}: route metric ok &amp; stable\n"));
    }
    body.push_str("</pre>");

    let chunks = transport::split_long_html_message(&body, 1000);
    assert!(chunks.len() >= 3);
    for chunk in &chunks {
        assert!(!chunk.is_empty());
        assert!(chunk.chars().count() <= 1050);
    }
    for chunk in &chunks[..chunks.len() - 1] {
        let opens = chunk.matches("<pre>").count();
        let closes = chunk.matches("</pre>").count();
        assert_eq!(opens, closes);
        assert_eq!(opens, 1);
    }
    let joined = chunks.join("\n");
    assert!(joined.contains("line 000:"));
    assert!(joined.contains("line 219:"));
}

#[tokio::test]
async fn test_poll_updates_proxy_getme_recovery_skips_direct_fallback() {
    use std::sync::{Arc, Mutex};

    let recorded: Arc<Mutex<Vec<transport::TransportCallSpec>>> = Arc::new(Mutex::new(Vec::new()));
    let req = transport::PollTransportRequest {
        token: "123456:test-secret".to_string(),
        offset: 10,
        timeout_secs: TG_POLL_TIMEOUT_SECS,
        proxy_url: Some("socks5://127.0.0.1:4534".to_string()),
        direct_fallback: true,
    };

    let res = transport::poll_updates_with(&req, |spec| {
        let recorded = Arc::clone(&recorded);
        async move {
            let is_probe = spec.url.ends_with("/getMe");
            recorded.lock().unwrap().push(spec);
            if is_probe {
                Ok(br#"{"ok":true,"result":{"id":123456,"is_bot":true}}"#.to_vec())
            } else {
                anyhow::bail!("simulated idle long-poll drop")
            }
        }
    })
    .await
    .expect("getMe recovery must return synthetic empty result");

    assert_eq!(res["ok"], serde_json::json!(true));
    assert_eq!(res["result"], serde_json::json!([]));

    let calls = recorded.lock().unwrap();
    assert_eq!(calls.len(), 2);
    assert!(calls[0].url.contains("/getUpdates?timeout=25&offset=10"));
    assert_eq!(calls[0].max_time_secs, 35);
    assert_eq!(calls[0].connect_timeout_secs, 8);
    assert_eq!(
        calls[0].proxy_url.as_deref(),
        Some("socks5://127.0.0.1:4534")
    );
    assert!(calls[1].url.ends_with("/getMe"));
    assert_eq!(calls[1].max_time_secs, 12);
    assert_eq!(calls[1].connect_timeout_secs, 5);
    assert_eq!(
        calls[1].proxy_url.as_deref(),
        Some("socks5://127.0.0.1:4534")
    );
    assert!(
        calls.iter().all(|c| c.proxy_url.is_some()),
        "must not fall back to direct when getMe through proxy succeeds"
    );
}

#[tokio::test]
async fn test_poll_updates_genuine_proxy_failure_caps_direct_fallback_timeout() {
    use std::sync::{Arc, Mutex};

    let recorded: Arc<Mutex<Vec<transport::TransportCallSpec>>> = Arc::new(Mutex::new(Vec::new()));
    let req = transport::PollTransportRequest {
        token: "123456:test-secret".to_string(),
        offset: 7,
        timeout_secs: TG_POLL_TIMEOUT_SECS,
        proxy_url: Some("socks5://127.0.0.1:4534".to_string()),
        direct_fallback: true,
    };

    let res = transport::poll_updates_with(&req, |spec| {
        let recorded = Arc::clone(&recorded);
        async move {
            let has_proxy = spec.proxy_url.is_some();
            recorded.lock().unwrap().push(spec);
            if has_proxy {
                anyhow::bail!("proxy unreachable")
            } else {
                Ok(br#"{"ok":true,"result":[]}"#.to_vec())
            }
        }
    })
    .await
    .expect("direct fallback should succeed");

    assert_eq!(res["ok"], serde_json::json!(true));
    {
        let calls = recorded.lock().unwrap();
        assert_eq!(calls.len(), 3);
        assert_eq!(calls[2].proxy_url, None);
        assert!(calls[2].url.contains("/getUpdates?timeout=5&offset=7"));
        assert_eq!(calls[2].max_time_secs, 15);
        assert_eq!(calls[2].connect_timeout_secs, 8);
    }

    let recorded_disabled: Arc<Mutex<Vec<transport::TransportCallSpec>>> =
        Arc::new(Mutex::new(Vec::new()));
    let req_disabled = transport::PollTransportRequest {
        direct_fallback: false,
        ..req
    };
    let err_res = transport::poll_updates_with(&req_disabled, |spec| {
        let recorded_disabled = Arc::clone(&recorded_disabled);
        async move {
            recorded_disabled.lock().unwrap().push(spec);
            anyhow::bail!("proxy unreachable")
        }
    })
    .await;
    assert!(err_res.is_err());
    let calls_disabled = recorded_disabled.lock().unwrap();
    assert_eq!(calls_disabled.len(), 2);
    assert!(calls_disabled.iter().all(|c| c.proxy_url.is_some()));
}

#[test]
fn test_route_alert_quiet_hours_cooldown_and_outbox_dedup() {
    let dir = std::env::temp_dir().join(format!(
        "tachyon_tg_resilience_{}_{}",
        std::process::id(),
        TEST_DIR_SEQ.fetch_add(1, Ordering::Relaxed)
    ));
    let _ = std::fs::remove_dir_all(&dir);
    let outbox_dir = dir.join("outbox");
    let stamp_path = dir.join("route-alert.stamp");
    let token = "123456:test-secret-token";
    let admins = [42_i64];

    let quiet_res = maybe_alert_route_failure_at(&RouteAlertParams {
        token,
        admins: &admins,
        header: "",
        ru: false,
        failures: 5,
        direct_fallback: true,
        quiet_enabled: true,
        quiet_start: "0",
        quiet_end: "23",
        now_utc_secs: 1_750_000_000,
        local_now_secs: 12 * 3600,
        outbox_dir: &outbox_dir,
        stamp_path: &stamp_path,
        cooldown_secs: TG_ROUTE_ALERT_COOLDOWN_SECS,
    });
    assert!(!quiet_res);
    assert!(!stamp_path.exists());
    assert!(list_outbox_entries(&outbox_dir).is_empty());

    let first_res = maybe_alert_route_failure_at(&RouteAlertParams {
        token,
        admins: &admins,
        header: "",
        ru: false,
        failures: 5,
        direct_fallback: true,
        quiet_enabled: false,
        quiet_start: "0",
        quiet_end: "23",
        now_utc_secs: 1_750_000_000,
        local_now_secs: 12 * 3600,
        outbox_dir: &outbox_dir,
        stamp_path: &stamp_path,
        cooldown_secs: TG_ROUTE_ALERT_COOLDOWN_SECS,
    });
    assert!(first_res);
    assert!(stamp_path.exists());
    let entries = list_outbox_entries(&outbox_dir);
    assert_eq!(entries.len(), 1);
    let raw_notice = std::fs::read_to_string(&entries[0].1).expect("read queued json notice");
    assert!(!raw_notice.contains("test-secret-token"));
    let parsed: OutboxJsonNotice = serde_json::from_str(&raw_notice).expect("parse json notice");
    assert_eq!(parsed.bot_id, "123456");
    assert_eq!(parsed.chat_id, 42);
    assert_eq!(parsed.dedup_key.as_deref(), Some("route_alert"));

    let _ = std::fs::remove_file(&entries[0].1);
    let cooldown_res = maybe_alert_route_failure_at(&RouteAlertParams {
        token,
        admins: &admins,
        header: "",
        ru: false,
        failures: 6,
        direct_fallback: true,
        quiet_enabled: false,
        quiet_start: "0",
        quiet_end: "23",
        now_utc_secs: 1_750_000_100,
        local_now_secs: 12 * 3600,
        outbox_dir: &outbox_dir,
        stamp_path: &stamp_path,
        cooldown_secs: TG_ROUTE_ALERT_COOLDOWN_SECS,
    });
    assert!(cooldown_res);
    assert!(list_outbox_entries(&outbox_dir).is_empty());

    submit_outbox_notice_in(&outbox_dir, token, 42, "alert-one", Some("route_alert"))
        .expect("initial deduped notice");
    for i in 1..TG_OUTBOX_MAX_FILES {
        submit_outbox_notice_in(&outbox_dir, token, 42, &format!("filler-{i}"), None)
            .expect("fill outbox to capacity");
    }
    assert_eq!(list_outbox_entries(&outbox_dir).len(), TG_OUTBOX_MAX_FILES);
    assert!(
        submit_outbox_notice_in(&outbox_dir, token, 42, "overflow", None).is_err(),
        "new non-deduped notice should be rejected at 50-file capacity"
    );

    let updated_path =
        submit_outbox_notice_in(&outbox_dir, token, 42, "alert-two", Some("route_alert"))
            .expect("deduped overwrite must bypass 50-file full rejection");
    assert_eq!(list_outbox_entries(&outbox_dir).len(), TG_OUTBOX_MAX_FILES);
    let updated: OutboxJsonNotice =
        serde_json::from_str(&std::fs::read_to_string(updated_path).unwrap()).unwrap();
    assert_eq!(updated.text, "alert-two");
    assert_eq!(updated.dedup_key.as_deref(), Some("route_alert"));

    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn test_sleep_with_heartbeat_writes_fresh_epoch_and_version() {
    let dir = std::env::temp_dir().join(format!(
        "tachyon_tg_hb_{}",
        TEST_DIR_SEQ.fetch_add(1, Ordering::Relaxed)
    ));
    let hb_path = dir.join("telegram.heartbeat");
    sleep_with_heartbeat_to(1, &hb_path).await;
    let raw = std::fs::read_to_string(&hb_path).expect("heartbeat file must exist");
    let v: serde_json::Value = serde_json::from_str(&raw).expect("valid heartbeat json");
    assert!(v["ts"].as_i64().unwrap_or(0) > 0);
    assert_eq!(v["version"], crate::store::TACHYON_VERSION);
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn test_ops_notifications_all_and_quick_toggles() {
    let admin_id: i64 = 444_555_666;
    let env = TempTestEnv::new("tg_toggles_notif", admin_id).await;

    let notif_menu = ops::try_handle_ops("/notifications", "", admin_id, &env.state, &env.core)
        .await
        .expect("/notifications reply");
    assert!(notif_menu.text.contains("Smart Detect"));
    assert!(notif_menu.text.contains("Failover"));

    // Toggle individual new notification flags
    let _ = ops::try_handle_ops(
        "bot_notify_tog",
        "route_alert",
        admin_id,
        &env.state,
        &env.core,
    )
    .await
    .expect("toggle route_alert");
    assert!(!env.state.data.read().await.telegram.notify_route_alert);

    // Disable all then enable all
    let _ = ops::try_handle_ops("bot_notify_all", "0", admin_id, &env.state, &env.core)
        .await
        .expect("disable all notifications");
    {
        let tg = &env.state.data.read().await.telegram;
        assert!(
            !tg.notify_smart_detect
                && !tg.notify_failover
                && !tg.notify_wan
                && !tg.notify_update_available
        );
    }
    let _ = ops::try_handle_ops("bot_notify_all", "1", admin_id, &env.state, &env.core)
        .await
        .expect("enable all notifications");
    {
        let tg = &env.state.data.read().await.telegram;
        assert!(
            tg.notify_smart_detect
                && tg.notify_failover
                && tg.notify_wan
                && tg.notify_update_available
                && tg.notify_route_alert
        );
    }

    // Quick toggles (/toggles + /features)
    let tog_menu = ops::try_handle_ops("/toggles", "net", admin_id, &env.state, &env.core)
        .await
        .expect("/toggles reply");
    assert!(tog_menu.text.contains("DNS"));

    let prev_bbr = env.state.data.read().await.settings.tcp_bbr;
    let _ = ops::try_handle_ops(
        "bot_feat_tog",
        "core tcp_bbr",
        admin_id,
        &env.state,
        &env.core,
    )
    .await
    .expect("toggle tcp_bbr");
    assert_eq!(env.state.data.read().await.settings.tcp_bbr, !prev_bbr);

    let prev_intercept = env.state.data.read().await.settings.dns_intercept_all;
    let _ = ops::try_handle_ops(
        "bot_feat_tog",
        "net dns_intercept_all",
        admin_id,
        &env.state,
        &env.core,
    )
    .await
    .expect("toggle dns_intercept_all");
    assert_eq!(
        env.state.data.read().await.settings.dns_intercept_all,
        !prev_intercept
    );
}

#[test]
fn test_node_switch_observer_no_ping_pong_and_no_duplicate() {
    let mut d = RouterStoreData::default();
    d.telegram.notify_server_switch = true;
    d.telegram.notify_failover = true;
    d.sections = vec![RoutingSection {
        id: "Main".to_string(),
        enabled: true,
        label: "Main".to_string(),
        connection_type: "proxy".to_string(),
        balancer_refs: vec!["bal_Main_SoftPortal".to_string()],
        active_selected_tag: "fsoft_old".to_string(),
        ..Default::default()
    }];

    let mut obs = BotEventObserver::default();
    // Simulate startup initialization of store active_selected_tag
    obs.section_active_nodes
        .insert("Main".to_string(), "fsoft_old".to_string());

    let px_json = json!({
        "sel-Main": { "now": "bal-Main-bal_Main_SoftPortal" },
        "bal-Main-bal_Main_SoftPortal": { "now": "Unlim EE" }
    });
    let px_map = px_json.as_object().unwrap();

    // 5 consecutive polling ticks with constant store tag & balancer target: 0 notifications (baseline on tick 1, silent on ticks 2..5)
    for _ in 0..5 {
        let (switched, store_notices) =
            collect_section_store_switch_notifications(&mut obs, &d, true);
        assert!(switched.is_empty());
        assert!(store_notices.is_empty());
        let clash_notices =
            collect_clash_node_switch_notifications(&mut obs, &d, px_map, &switched, true);
        assert!(
            clash_notices.is_empty(),
            "unexpected node switch ping-pong flood: {clash_notices:?}"
        );
    }

    // Actual balancer switch to Unlim DE: exactly 1 notification (not duplicated into both failover and server_switch)
    let px_switched = json!({
        "sel-Main": { "now": "bal-Main-bal_Main_SoftPortal" },
        "bal-Main-bal_Main_SoftPortal": { "now": "Unlim DE" }
    });
    let (switched, store_notices) = collect_section_store_switch_notifications(&mut obs, &d, true);
    assert!(store_notices.is_empty());
    let clash_notices = collect_clash_node_switch_notifications(
        &mut obs,
        &d,
        px_switched.as_object().unwrap(),
        &switched,
        true,
    );
    assert_eq!(clash_notices.len(), 1);
    assert_eq!(clash_notices[0].0, "server_switch");
    assert!(clash_notices[0].1.contains("Unlim DE"));

    // Subsequent poll with same Unlim DE produces 0 notifications
    let (switched2, store_notices2) =
        collect_section_store_switch_notifications(&mut obs, &d, true);
    assert!(store_notices2.is_empty());
    let clash_notices2 = collect_clash_node_switch_notifications(
        &mut obs,
        &d,
        px_switched.as_object().unwrap(),
        &switched2,
        true,
    );
    assert!(clash_notices2.is_empty());

    // Manual store change + matching Clash selector update on the same tick: only 1 notification
    d.sections[0].active_selected_tag = "node_manual".to_string();
    let px_manual = json!({
        "sel-Main": { "now": "node_manual" },
        "bal-Main-bal_Main_SoftPortal": { "now": "Unlim DE" }
    });
    let (switched3, store_notices3) =
        collect_section_store_switch_notifications(&mut obs, &d, true);
    assert_eq!(store_notices3.len(), 1);
    assert!(switched3.contains("Main"));
    let clash_notices3 = collect_clash_node_switch_notifications(
        &mut obs,
        &d,
        px_manual.as_object().unwrap(),
        &switched3,
        true,
    );
    assert!(
        clash_notices3.is_empty(),
        "manual store switch must suppress same-tick Clash duplicate"
    );

    // When notify_server_switch is disabled, balancer node switches stay silent even if notify_failover is enabled
    d.telegram.notify_server_switch = false;
    d.telegram.notify_failover = true;
    d.sections[0].active_selected_tag = String::new();
    let px_reverted = json!({
        "sel-Main": { "now": "bal-Main-bal_Main_SoftPortal" },
        "bal-Main-bal_Main_SoftPortal": { "now": "Unlim EE" }
    });
    let (switched4, store_notices4) =
        collect_section_store_switch_notifications(&mut obs, &d, true);
    assert!(store_notices4.is_empty());
    let clash_notices4 = collect_clash_node_switch_notifications(
        &mut obs,
        &d,
        px_reverted.as_object().unwrap(),
        &switched4,
        true,
    );
    assert!(
        clash_notices4.is_empty(),
        "node switch notification must respect notify_server_switch=false even when notify_failover=true: {clash_notices4:?}"
    );
}

#[test]
fn test_quiet_hours_suppresses_non_critical_keeps_critical() {
    let mut d = RouterStoreData::default();
    d.telegram.enabled = true;
    d.telegram.notify_server_switch = true;
    d.telegram.notify_failover = true;
    d.telegram.notify_auto_update = true;
    d.telegram.notify_restart = true;
    d.telegram.notify_crash = true;
    d.telegram.notify_dns_leak = true;
    d.telegram.notify_wan = true;
    d.telegram.quiet_hours_enabled = true;
    d.telegram.quiet_hours_start = "23:00".to_string();
    d.telegram.quiet_hours_end = "07".to_string();

    let night_secs = 3600; // 01:00
    assert!(!should_emit_notification_at(
        &d,
        "server_switch",
        "<b>Переключение узла:</b> Main -> Node",
        night_secs
    ));
    assert!(!should_emit_notification_at(
        &d,
        "failover",
        "<b>Failover:</b> backup",
        night_secs
    ));
    assert!(!should_emit_notification_at(
        &d,
        "auto_update",
        "[Tachyon] Tachyon успешно обновлён: 2.0.0-beta.9 -> 2.0.0-beta.10",
        night_secs
    ));
    assert!(!should_emit_notification_at(
        &d,
        "restart",
        "<b>Перезапуск ядра:</b> новый PID 123",
        night_secs
    ));
    assert!(!is_critical_notification(
        "restart",
        "<b>Перезапуск ядра:</b> Watchdog action executed: L2_config_drift_reload"
    ));
    assert!(!should_emit_notification_at(
        &d,
        "wan",
        "<b>WAN:</b> внешний канал восстановлен",
        night_secs
    ));

    // Critical alerts continue to pass during quiet hours
    assert!(should_emit_notification_at(
        &d,
        "crash",
        "<b>Сбой ядра:</b> stopped unexpectedly",
        night_secs
    ));
    assert!(should_emit_notification_at(
        &d,
        "dns_leak",
        "<b>DNS:</b> local resolver unreachable — DNS leak risk",
        night_secs
    ));
    assert!(should_emit_notification_at(
        &d,
        "wan",
        "<b>WAN:</b> потеря связи на внешнем канале",
        night_secs
    ));

    // Daytime restores non-critical alerts
    let day_secs = 12 * 3600;
    assert!(should_emit_notification_at(
        &d,
        "server_switch",
        "<b>Переключение узла:</b> Main -> Node",
        day_secs
    ));

    assert!(!is_critical_outbox_message(
        "<b>Переключение узла:</b> Main",
        None
    ));
    assert!(!is_critical_outbox_message(
        "Доступно обновление tachyon",
        Some("upd_tachyon_2.0.0-beta.10")
    ));
    assert!(is_critical_outbox_message(
        "<b>Сбой ядра:</b> process crashed",
        None
    ));
    assert!(is_critical_outbox_message(
        "<b>Honeypot:</b> probe from 1.2.3.4",
        None
    ));
}

struct AbortOnDropHandle(tokio::task::JoinHandle<()>);

impl Drop for AbortOnDropHandle {
    fn drop(&mut self) {
        self.0.abort();
    }
}

struct MockRouterState {
    expected_token: String,
    reject_status: Option<u16>,
    telemetry_status: u16,
    tachyon_version: String,
    tachyon_latest: String,
    core_version: String,
    core_latest: String,
    core_running: bool,
    use_ubus_update_fallback: bool,
    seen_auth_headers: Vec<String>,
    requests: Vec<(String, String, String)>,
}

impl MockRouterState {
    fn new(expected_token: &str) -> Self {
        Self {
            expected_token: expected_token.to_string(),
            reject_status: None,
            telemetry_status: 200,
            tachyon_version: "2.0.0-beta.13".to_string(),
            tachyon_latest: "2.0.0-beta.14".to_string(),
            core_version: "0.5.0".to_string(),
            core_latest: "0.5.1".to_string(),
            core_running: true,
            use_ubus_update_fallback: false,
            seen_auth_headers: Vec::new(),
            requests: Vec::new(),
        }
    }

    fn post_count(&self) -> usize {
        self.requests.iter().filter(|(m, _, _)| m == "POST").count()
    }
}

fn find_bytes_subslice(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack.windows(needle.len()).position(|w| w == needle)
}

async fn spawn_mock_router_server(
    state: Arc<std::sync::Mutex<MockRouterState>>,
) -> (String, AbortOnDropHandle) {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind mock router listener");
    let addr = listener.local_addr().expect("mock listener addr");
    let url = format!("http://127.0.0.1:{}", addr.port());

    let handle = tokio::spawn(async move {
        loop {
            let Ok((mut stream, _)) = listener.accept().await else {
                break;
            };
            let st = Arc::clone(&state);
            tokio::spawn(async move {
                let mut buf = Vec::with_capacity(4096);
                let mut tmp = [0u8; 2048];
                let header_end = loop {
                    if let Some(pos) = find_bytes_subslice(&buf, b"\r\n\r\n") {
                        break Some(pos);
                    }
                    match stream.read(&mut tmp).await {
                        Ok(0) | Err(_) => break None,
                        Ok(n) => {
                            buf.extend_from_slice(&tmp[..n]);
                            if buf.len() > 65_536 {
                                break None;
                            }
                        }
                    }
                };
                let Some(hdr_end) = header_end else {
                    return;
                };
                let hdr_text = String::from_utf8_lossy(&buf[..hdr_end]).to_string();
                let mut lines = hdr_text.split("\r\n");
                let req_line = lines.next().unwrap_or("");
                let mut parts = req_line.split_whitespace();
                let method = parts.next().unwrap_or("GET").to_string();
                let path = parts.next().unwrap_or("/").to_string();

                let mut auth_header = String::new();
                let mut content_len = 0usize;
                for line in lines {
                    if let Some((k, v)) = line.split_once(':') {
                        let kl = k.trim().to_ascii_lowercase();
                        if kl == "authorization" {
                            auth_header = v.trim().to_string();
                        } else if kl == "content-length" {
                            content_len = v.trim().parse::<usize>().unwrap_or(0);
                        }
                    }
                }

                let body_start = hdr_end + 4;
                while buf.len().saturating_sub(body_start) < content_len {
                    match stream.read(&mut tmp).await {
                        Ok(0) | Err(_) => break,
                        Ok(n) => buf.extend_from_slice(&tmp[..n]),
                    }
                }
                let body_bytes = &buf[body_start..buf.len().min(body_start + content_len)];
                let body_str = String::from_utf8_lossy(body_bytes).to_string();

                let (status_code, status_text, resp_body) = {
                    let mut guard = st.lock().expect("lock mock state");
                    guard.seen_auth_headers.push(auth_header.clone());
                    guard
                        .requests
                        .push((method.clone(), path.clone(), body_str.clone()));

                    let expected_hdr = format!("Bearer {}", guard.expected_token);
                    if let Some(code) = guard.reject_status {
                        let txt = if code == 403 {
                            "Forbidden"
                        } else {
                            "Unauthorized"
                        };
                        (code, txt, serde_json::json!({ "error": "auth rejected" }))
                    } else if auth_header != expected_hdr {
                        (
                            401,
                            "Unauthorized",
                            serde_json::json!({ "error": "invalid bearer token" }),
                        )
                    } else if method == "GET" && path == "/api/telemetry" {
                        if guard.telemetry_status != 200 {
                            (
                                guard.telemetry_status,
                                "Service Unavailable",
                                serde_json::json!({ "error": "telemetry unavailable" }),
                            )
                        } else {
                            (
                                200,
                                "OK",
                                serde_json::json!({
                                    "system": {
                                        "hostname": "branch-gw",
                                        "router_model": "GL-MT6000",
                                        "memory_used_mb": 120,
                                        "memory_total_mb": 1024,
                                        "host_uptime_secs": 3700
                                    },
                                    "live": {
                                        "core_running": guard.core_running,
                                        "core_version": guard.core_version,
                                        "wan_healthy": true,
                                        "dns_healthy": true,
                                        "active_connections": 17,
                                        "core_uptime_secs": 1850
                                    }
                                }),
                            )
                        }
                    } else if method == "GET" && path == "/api/updates/check" {
                        if guard.telemetry_status != 200 {
                            (
                                guard.telemetry_status,
                                "Service Unavailable",
                                serde_json::json!({ "error": "updates unavailable" }),
                            )
                        } else {
                            (
                                200,
                                "OK",
                                serde_json::json!({
                                    "orchestrator_version": guard.tachyon_version,
                                    "orchestrator_latest": guard.tachyon_latest,
                                    "core_installed": guard.core_version,
                                    "core_latest": guard.core_latest,
                                    "lists_installed_count": 5,
                                    "subscriptions_count": 2
                                }),
                            )
                        }
                    } else if method == "GET" && path == "/api/diagnostics/doctor" {
                        (
                            200,
                            "OK",
                            serde_json::json!({
                                "healthy": true,
                                "checks_passed": 12,
                                "checks_total": 12,
                                "summary": "All runtime checks OK",
                                "findings": []
                            }),
                        )
                    } else if method == "POST" && path == "/api/components/action" {
                        if guard.use_ubus_update_fallback {
                            (
                                200,
                                "OK",
                                serde_json::json!({
                                    "ok": false,
                                    "result": {
                                        "message": "требует запуска через updater"
                                    }
                                }),
                            )
                        } else {
                            guard.tachyon_version = guard.tachyon_latest.clone();
                            (
                                200,
                                "OK",
                                serde_json::json!({
                                    "ok": true,
                                    "result": {
                                        "message": "Tachyon updated"
                                    }
                                }),
                            )
                        }
                    } else if method == "POST" && path == "/ubus" {
                        let rpc: serde_json::Value =
                            serde_json::from_str(&body_str).unwrap_or(serde_json::Value::Null);
                        let subcmd = rpc
                            .pointer("/params/3/params/0")
                            .and_then(serde_json::Value::as_str)
                            .unwrap_or("");
                        let stdout_json = match subcmd {
                            "component_action_async" => serde_json::json!({
                                "ok": true,
                                "running": true,
                                "job_id": "job-442"
                            })
                            .to_string(),
                            "component_action_status" => {
                                guard.tachyon_version = guard.tachyon_latest.clone();
                                serde_json::json!({
                                    "ok": true,
                                    "running": false,
                                    "status": "done",
                                    "message": "Updater finished"
                                })
                                .to_string()
                            }
                            "component_list_releases" => serde_json::json!([
                                { "version": guard.tachyon_latest }
                            ])
                            .to_string(),
                            _ => serde_json::json!({ "ok": true }).to_string(),
                        };
                        (
                            200,
                            "OK",
                            serde_json::json!({
                                "jsonrpc": "2.0",
                                "id": 1,
                                "result": [0, { "stdout": stdout_json }]
                            }),
                        )
                    } else if method == "POST" && path == "/api/core/restart" {
                        guard.core_running = true;
                        (
                            200,
                            "OK",
                            serde_json::json!({
                                "ok": true,
                                "message": "Service restarted"
                            }),
                        )
                    } else {
                        (
                            404,
                            "Not Found",
                            serde_json::json!({ "error": "unknown endpoint" }),
                        )
                    }
                };

                let payload = resp_body.to_string();
                let raw_resp = format!(
                    "HTTP/1.1 {status_code} {status_text}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                    payload.len(),
                    payload
                );
                let _ = stream.write_all(raw_resp.as_bytes()).await;
                let _ = stream.shutdown().await;
            });
        }
    });

    (url, AbortOnDropHandle(handle))
}

fn collect_buttons(reply: &BotReply) -> Vec<(String, String)> {
    let mut out = Vec::new();
    let Some(kb) = reply.keyboard.as_ref() else {
        return out;
    };
    let Some(rows) = kb.get("inline_keyboard").and_then(|v| v.as_array()) else {
        return out;
    };
    for row in rows {
        let Some(btns) = row.as_array() else {
            continue;
        };
        for btn in btns {
            let text = btn
                .get("text")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();
            let raw_cb = btn
                .get("callback_data")
                .and_then(|v| v.as_str())
                .unwrap_or("");
            out.push((text, resolve_callback_data(raw_cb)));
        }
    }
    out
}

fn assert_no_token_leak(reply: &BotReply, token: &str) {
    assert!(
        !reply.text.contains(token),
        "raw API token leaked in reply text: {}",
        reply.text
    );
    if let Some(kb) = reply.keyboard.as_ref() {
        let kb_str = kb.to_string();
        assert!(
            !kb_str.contains(token),
            "raw API token leaked in keyboard JSON: {kb_str}"
        );
    }
    for (_, cb) in collect_buttons(reply) {
        assert!(
            !cb.contains(token),
            "raw API token leaked in callback_data: {cb}"
        );
    }
}

#[test]
fn test_tg_bot_config_backward_compat_without_managed_routers() {
    let legacy_tg_json = r#"{
        "enabled": true,
        "bot_token": "111:LEGACY",
        "admin_ids": [1001],
        "router_name": "LegacyNode",
        "language": "ru",
        "notify_on_crash": true
    }"#;
    let parsed_tg: crate::store::TgBotConfig =
        serde_json::from_str(legacy_tg_json).expect("legacy TgBotConfig without managed_routers");
    assert!(parsed_tg.managed_routers.is_empty());
    assert_eq!(parsed_tg.router_name, "LegacyNode");

    let mut legacy_store_val =
        serde_json::to_value(crate::store::RouterStoreData::default()).expect("serialize default");
    if let Some(tg_obj) = legacy_store_val
        .get_mut("telegram")
        .and_then(|v| v.as_object_mut())
    {
        tg_obj.remove("managed_routers");
        tg_obj.insert("bot_token".to_string(), serde_json::json!("111:LEGACY"));
        tg_obj.insert("admin_ids".to_string(), serde_json::json!([1001]));
    }
    let parsed_store: crate::store::RouterStoreData = serde_json::from_value(legacy_store_val)
        .expect("legacy RouterStoreData without managed_routers");
    assert!(parsed_store.telegram.managed_routers.is_empty());

    // ManagedRouter.enabled defaults to true when omitted
    let router_no_enabled_json = r#"{
        "id": "r_home",
        "name": "Home",
        "url": "http://192.168.1.1:8080",
        "api_token": "tok_default_enabled"
    }"#;
    let mr: crate::store::ManagedRouter =
        serde_json::from_str(router_no_enabled_json).expect("ManagedRouter without enabled field");
    assert!(mr.enabled);

    // LuCI JSON section import must preserve managed_routers and section export must omit them
    let mut store = crate::store::RouterStoreData::default();
    store.telegram.enabled = true;
    store
        .telegram
        .managed_routers
        .push(crate::store::ManagedRouter {
            id: "branch_1".to_string(),
            name: "Branch-1".to_string(),
            url: "http://10.0.0.2:8080".to_string(),
            api_token: "super_secret_sync_tok".to_string(),
            enabled: true,
        });

    let sections_val = crate::store::sync_store_to_json_sections(&store, None);
    let sections_str = sections_val.to_string();
    assert!(!sections_str.contains("managed_routers"));
    assert!(!sections_str.contains("super_secret_sync_tok"));

    let mut uci_sections = serde_json::Map::new();
    uci_sections.insert(
        "telegram".to_string(),
        serde_json::json!({
            ".type": "telegram",
            "enabled": true,
            "router_name": "UpdatedViaLuCI",
            "language": "en"
        }),
    );
    store.import_from_json_sections(&uci_sections);
    assert_eq!(store.telegram.router_name, "UpdatedViaLuCI");
    assert_eq!(store.telegram.managed_routers.len(), 1);
    assert_eq!(store.telegram.managed_routers[0].id, "branch_1");

    // Snapshot redaction redacts api_token fields
    let serialized = serde_json::to_value(&store).expect("serialize store");
    let redacted = crate::crypto_gen::redact_json_value(&serialized);
    let redacted_str = redacted.to_string();
    assert!(!redacted_str.contains("super_secret_sync_tok"));
}

#[test]
fn test_fleet_url_validation_http_parser_and_token_redaction() {
    let ok_http = fleet::normalize_and_validate_router_url("http://192.168.1.2:8080/")
        .expect("valid http url");
    assert_eq!(ok_http.scheme, "http");
    assert_eq!(ok_http.connect_host, "192.168.1.2");
    assert_eq!(ok_http.host_header, "192.168.1.2:8080");
    assert_eq!(ok_http.port, 8080);
    assert_eq!(ok_http.base_path, "");
    assert_eq!(ok_http.normalized_url, "http://192.168.1.2:8080");

    let ok_https = fleet::normalize_and_validate_router_url("HTTPS://gw.example.com/tachyon-api/")
        .expect("valid https url");
    assert_eq!(ok_https.scheme, "https");
    assert_eq!(ok_https.port, 443);
    assert_eq!(ok_https.base_path, "/tachyon-api");
    assert_eq!(
        ok_https.normalized_url,
        "https://gw.example.com/tachyon-api"
    );

    let ok_v6 =
        fleet::normalize_and_validate_router_url("http://[::1]:9000").expect("valid ipv6 url");
    assert_eq!(ok_v6.connect_host, "::1");
    assert_eq!(ok_v6.host_header, "[::1]:9000");
    assert_eq!(ok_v6.port, 9000);

    assert!(fleet::normalize_and_validate_router_url("").is_err());
    assert!(fleet::normalize_and_validate_router_url("ftp://192.168.1.2").is_err());
    assert!(fleet::normalize_and_validate_router_url("http://user:pass@192.168.1.2").is_err());
    assert!(fleet::normalize_and_validate_router_url("http://192.168.1.2/a?x=1").is_err());
    assert!(fleet::normalize_and_validate_router_url("http://192.168.1.2/bad space").is_err());

    let plain_resp = fleet::parse_http_response(
        b"HTTP/1.1 200 OK\r\nContent-Length: 11\r\n\r\n{\"ok\":true}",
        true,
    )
    .expect("parse plain http");
    assert_eq!(plain_resp.status, 200);
    assert_eq!(plain_resp.body, br#"{"ok":true}"#);

    let continue_resp = fleet::parse_http_response(
        b"HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}",
        true,
    )
    .expect("parse 100 continue");
    assert_eq!(continue_resp.status, 200);
    assert_eq!(continue_resp.body, b"{}");

    let chunked_resp = fleet::parse_http_response(
        b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\n{\"a\":\r\n2\r\n1}\r\n0\r\n\r\n",
        true,
    )
    .expect("parse chunked http");
    assert_eq!(chunked_resp.status, 200);
    assert_eq!(chunked_resp.body, br#"{"a":1}"#);

    let h2_resp = fleet::parse_http_response(
        b"HTTP/2 200\r\ntransfer-encoding: chunked\r\n\r\n{\"ok\":true}",
        false,
    )
    .expect("parse pre-unchunked curl http/2");
    assert_eq!(h2_resp.status, 200);
    assert_eq!(h2_resp.body, br#"{"ok":true}"#);

    let cfg = fleet::build_curl_stdin_config("https://gw.example.com/api", "tok_secret_123")
        .expect("curl stdin config");
    assert!(cfg.contains("url = \"https://gw.example.com/api\""));
    assert!(cfg.contains("Authorization: Bearer tok_secret_123"));
    assert!(fleet::build_curl_stdin_config("https://gw.example.com", "bad\ntok").is_err());

    let dirty = "failed Authorization: Bearer tok_secret_123 tok_secret_123";
    let clean = fleet::sanitize_fleet_error(dirty, "tok_secret_123");
    assert!(!clean.contains("tok_secret_123"));
    assert!(clean.contains("[REDACTED]"));

    let clean_url = fleet::sanitize_display_url("http://adm:pw@10.0.0.1:8080/path?token=abc");
    assert!(!clean_url.contains("adm:pw"));
    assert!(!clean_url.contains("token=abc"));
    assert!(clean_url.contains("[REDACTED]@10.0.0.1:8080/path"));
}

#[tokio::test]
async fn test_fleet_overview_and_single_router_inspection_mock_http() {
    let admin_id = 710_001i64;
    let env = TempTestEnv::new("fleet_overview", admin_id).await;

    let token = "secret_branch_tok_987654";
    let mock_state = Arc::new(std::sync::Mutex::new(MockRouterState::new(token)));
    let (online_url, _server_guard) = spawn_mock_router_server(Arc::clone(&mock_state)).await;

    // Bind and drop an ephemeral listener so we get a guaranteed closed port
    let dead_listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind temp port for offline router");
    let dead_port = dead_listener.local_addr().expect("dead port").port();
    drop(dead_listener);
    let offline_url = format!("http://127.0.0.1:{dead_port}");

    // /start main menu includes Routers button (EN + RU)
    let start_en = handle_incoming_text(admin_id, "/start", &env.state, &env.core)
        .await
        .expect("en /start");
    let btns_en = collect_buttons(&start_en);
    assert!(
        btns_en
            .iter()
            .any(|(label, cb)| label == "Routers" && cb == "/routers"),
        "missing Routers button in EN /start: {btns_en:?}"
    );

    {
        let mut d = env.state.data.write().await;
        d.telegram.language = "ru".to_string();
        d.telegram.managed_routers = vec![
            crate::store::ManagedRouter {
                id: "branch_office".to_string(),
                name: "Branch-Office".to_string(),
                url: online_url.clone(),
                api_token: token.to_string(),
                enabled: true,
            },
            crate::store::ManagedRouter {
                id: "warehouse_off".to_string(),
                name: "Warehouse-Offline".to_string(),
                url: offline_url,
                api_token: "offline_tok_000".to_string(),
                enabled: true,
            },
        ];
    }

    let start_ru = handle_incoming_text(admin_id, "/start", &env.state, &env.core)
        .await
        .expect("ru /start");
    let btns_ru = collect_buttons(&start_ru);
    assert!(
        btns_ru
            .iter()
            .any(|(label, cb)| label == "Роутеры" && cb == "/routers"),
        "missing Роутеры button in RU /start: {btns_ru:?}"
    );

    // /routers -> fleet overview showing online + offline sites
    let overview = handle_incoming_text(admin_id, "/routers", &env.state, &env.core)
        .await
        .expect("/routers overview");
    assert!(overview.text.contains("Branch-Office"), "{}", overview.text);
    assert!(overview.text.contains("online"), "{}", overview.text);
    assert!(overview.text.contains("2.0.0-beta.13"), "{}", overview.text);
    assert!(overview.text.contains("0.5.0"), "{}", overview.text);
    assert!(
        overview.text.contains("Warehouse-Offline"),
        "{}",
        overview.text
    );
    assert!(overview.text.contains("offline"), "{}", overview.text);
    assert_no_token_leak(&overview, token);
    assert_no_token_leak(&overview, "offline_tok_000");

    {
        let st = mock_state.lock().expect("lock mock");
        assert!(
            st.seen_auth_headers
                .iter()
                .any(|h| h == &format!("Bearer {token}")),
            "expected Bearer token header, saw {:?}",
            st.seen_auth_headers
        );
    }

    // Single-router detail inspection with doctor summary
    let detail =
        handle_incoming_callback(admin_id, "flt_view branch_office", &env.state, &env.core)
            .await
            .expect("flt_view reply");
    assert!(detail.text.contains("Branch-Office"), "{}", detail.text);
    assert!(detail.text.contains("running [ON]"), "{}", detail.text);
    assert!(detail.text.contains("120/1024 MB"), "{}", detail.text);
    assert!(detail.text.contains("12/12"), "{}", detail.text);
    assert!(
        detail.text.contains("All runtime checks OK"),
        "{}",
        detail.text
    );
    assert_no_token_leak(&detail, token);

    let detail_btns = collect_buttons(&detail);
    for expected_prefix in [
        "flt_upd_chk branch_office",
        "flt_upd_ask branch_office",
        "flt_rst_ask branch_office",
        "flt_del_ask branch_office",
    ] {
        assert!(
            detail_btns.iter().any(|(_, cb)| cb == expected_prefix),
            "missing action button {expected_prefix} in {detail_btns:?}"
        );
    }
    {
        let st = mock_state.lock().expect("lock mock");
        assert!(
            st.requests
                .iter()
                .any(|(m, p, _)| m == "GET" && p == "/api/diagnostics/doctor"),
            "expected GET /api/diagnostics/doctor"
        );
    }
}

#[tokio::test]
async fn test_fleet_monitor_hysteresis_cooldown_outage_recovery_no_spam() {
    let env = TempTestEnv::new("fleet_monitor", 710_002).await;
    let cache_path = env.dir.join("fleet-health.json");
    let token = "secret_dc_tok_444";
    let mock_state = Arc::new(std::sync::Mutex::new(MockRouterState::new(token)));
    let (url, _server_guard) = spawn_mock_router_server(Arc::clone(&mock_state)).await;

    let routers = vec![crate::store::ManagedRouter {
        id: "remote_dc".to_string(),
        name: "Remote-DC".to_string(),
        url: url.clone(),
        api_token: token.to_string(),
        enabled: true,
    }];

    let mut mon = fleet::FleetMonitor::new_with_config(60, 2, 2, 300, cache_path.clone());

    // Initial healthy poll -> no alert
    assert!(mon.poll_tick_if_due(&routers, 1000).await.is_empty());

    // Flip remote to 503 outage
    mock_state.lock().expect("lock mock").telemetry_status = 503;

    // Before poll_interval (60s) elapses -> skipped, no alerts
    assert!(mon.poll_tick_if_due(&routers, 1030).await.is_empty());

    // 1st consecutive failure -> silent (failure_threshold = 2)
    assert!(mon.poll_tick_if_due(&routers, 1060).await.is_empty());

    // 2nd consecutive failure -> emits 1 Outage alert naming site without token
    let alerts_out = mon.poll_tick_if_due(&routers, 1120).await;
    assert_eq!(alerts_out.len(), 1);
    assert_eq!(alerts_out[0].kind, fleet::FleetAlertKind::Outage);
    assert_eq!(alerts_out[0].router_name, "Remote-DC");
    let out_html = fleet::format_fleet_alert_html(&alerts_out[0], true);
    assert!(out_html.contains("Remote-DC"));
    assert!(!out_html.contains(token));

    // Repeated failures while offline -> 0 alerts (no spam)
    assert!(mon.poll_tick_if_due(&routers, 1180).await.is_empty());
    assert!(mon.poll_tick_if_due(&routers, 1240).await.is_empty());

    // Remote recovers to 200 OK
    mock_state.lock().expect("lock mock").telemetry_status = 200;

    // 1st consecutive success -> silent (recovery_threshold = 2)
    assert!(mon.poll_tick_if_due(&routers, 1300).await.is_empty());

    // 2nd consecutive success -> emits 1 Recovery alert naming site
    let alerts_rec = mon.poll_tick_if_due(&routers, 1360).await;
    assert_eq!(alerts_rec.len(), 1);
    assert_eq!(alerts_rec[0].kind, fleet::FleetAlertKind::Recovery);
    assert_eq!(alerts_rec[0].router_name, "Remote-DC");
    let rec_html = fleet::format_fleet_alert_html(&alerts_rec[0], false);
    assert!(rec_html.contains("Remote-DC"));
    assert!(!rec_html.contains(token));

    // Tmpfs cache persisted on demand and contains no raw API token
    let cache_text = std::fs::read_to_string(&cache_path).expect("read fleet-health cache");
    assert!(cache_text.contains("Remote-DC"));
    assert!(!cache_text.contains(token));

    // Cooldown suppression: rapid flap within 300s suppresses duplicate outage alert, then allows after cooldown
    let ok_sample = || {
        vec![fleet::FleetProbeSample {
            router_id: "r_cool".to_string(),
            router_name: "CoolSite".to_string(),
            url: "http://127.0.0.1:9999".to_string(),
            reachable: true,
            core_running: Some(true),
            tachyon_version: "2.0.0".to_string(),
            core_version: "0.5.0".to_string(),
            auth_error: None,
            error: None,
        }]
    };
    let err_sample = || {
        vec![fleet::FleetProbeSample {
            router_id: "r_cool".to_string(),
            router_name: "CoolSite".to_string(),
            url: "http://127.0.0.1:9999".to_string(),
            reachable: false,
            core_running: None,
            tachyon_version: String::new(),
            core_version: String::new(),
            auth_error: None,
            error: Some("timeout".to_string()),
        }]
    };

    let mut cool_mon =
        fleet::FleetMonitor::new_with_config(10, 2, 2, 300, env.dir.join("cool-health.json"));
    assert!(cool_mon.apply_probe_samples(&ok_sample(), 100).is_empty());
    assert!(cool_mon.apply_probe_samples(&err_sample(), 190).is_empty());
    assert_eq!(cool_mon.apply_probe_samples(&err_sample(), 200).len(), 1); // outage at T=200
    assert!(cool_mon.apply_probe_samples(&ok_sample(), 210).is_empty());
    assert_eq!(cool_mon.apply_probe_samples(&ok_sample(), 220).len(), 1); // recovery at T=220

    // Flap outage at T=240..250 (50s since T=200 < 300s cooldown) -> suppressed
    assert!(cool_mon.apply_probe_samples(&err_sample(), 240).is_empty());
    assert!(cool_mon.apply_probe_samples(&err_sample(), 250).is_empty());

    // Recover outside cooldown (T=550 >= 220+300) — note outage_notified was false so recovery stays silent, then new outage at T=600 (> 200+300) triggers again
    assert!(cool_mon.apply_probe_samples(&ok_sample(), 540).is_empty());
    assert!(cool_mon.apply_probe_samples(&ok_sample(), 550).is_empty());
    assert!(cool_mon.apply_probe_samples(&err_sample(), 590).is_empty());
    let after_cooldown = cool_mon.apply_probe_samples(&err_sample(), 600);
    assert_eq!(after_cooldown.len(), 1);
    assert_eq!(after_cooldown[0].kind, fleet::FleetAlertKind::Outage);
}

#[tokio::test]
async fn test_fleet_check_updates_confirmation_and_post_verification() {
    let admin_id = 710_003i64;
    let env = TempTestEnv::new("fleet_updates", admin_id).await;
    let token = "secret_upd_tok_555";
    let mock_state = Arc::new(std::sync::Mutex::new(MockRouterState::new(token)));
    mock_state.lock().expect("lock mock").core_running = false;
    let (url, _server_guard) = spawn_mock_router_server(Arc::clone(&mock_state)).await;

    {
        let mut d = env.state.data.write().await;
        d.telegram.managed_routers = vec![crate::store::ManagedRouter {
            id: "r1".to_string(),
            name: "Edge-1".to_string(),
            url,
            api_token: token.to_string(),
            enabled: true,
        }];
    }

    // Check updates
    let upd = handle_incoming_callback(admin_id, "flt_upd_chk r1", &env.state, &env.core)
        .await
        .expect("flt_upd_chk");
    assert!(upd.text.contains("2.0.0-beta.13"), "{}", upd.text);
    assert!(upd.text.contains("2.0.0-beta.14"), "{}", upd.text);
    assert!(upd.text.contains("0.5.0"), "{}", upd.text);
    assert!(upd.text.contains("0.5.1"), "{}", upd.text);
    assert_no_token_leak(&upd, token);

    // Update ask requires explicit confirmation, zero POST requests yet
    let upd_ask = handle_incoming_callback(admin_id, "flt_upd_ask r1", &env.state, &env.core)
        .await
        .expect("flt_upd_ask");
    let ask_btns = collect_buttons(&upd_ask);
    assert!(ask_btns.iter().any(|(_, cb)| cb == "flt_upd_ok r1"));
    assert!(ask_btns.iter().any(|(_, cb)| cb == "flt_view r1"));
    assert_eq!(mock_state.lock().expect("lock mock").post_count(), 0);

    // Cancel returns to router detail without sending POST
    let _cancel = handle_incoming_callback(admin_id, "flt_view r1", &env.state, &env.core)
        .await
        .expect("cancel flt_view");
    assert_eq!(mock_state.lock().expect("lock mock").post_count(), 0);

    // Restart ask also requires confirmation without sending POST
    let rst_ask = handle_incoming_callback(admin_id, "flt_rst_ask r1", &env.state, &env.core)
        .await
        .expect("flt_rst_ask");
    let rst_btns = collect_buttons(&rst_ask);
    assert!(rst_btns.iter().any(|(_, cb)| cb == "flt_rst_ok r1"));
    assert!(rst_btns.iter().any(|(_, cb)| cb == "flt_view r1"));
    assert_eq!(mock_state.lock().expect("lock mock").post_count(), 0);

    // Confirm Update -> sends POST /api/components/action + runs post-action verification observing 2.0.0-beta.14
    let upd_ok = handle_incoming_callback(admin_id, "flt_upd_ok r1", &env.state, &env.core)
        .await
        .expect("flt_upd_ok");
    assert!(upd_ok.text.contains("[OK]"), "{}", upd_ok.text);
    assert!(upd_ok.text.contains("2.0.0-beta.14"), "{}", upd_ok.text);
    assert_no_token_leak(&upd_ok, token);
    {
        let st = mock_state.lock().expect("lock mock");
        assert!(st.requests.iter().any(|(m, p, b)| {
            m == "POST"
                && p == "/api/components/action"
                && b.contains("tachyon")
                && b.contains("update")
        }));
    }

    // Verify ubus updater fallback path when /api/components/action declines direct self-update
    {
        let mut st = mock_state.lock().expect("lock mock");
        st.use_ubus_update_fallback = true;
        st.tachyon_version = "2.0.0-beta.13".to_string();
        st.requests.clear();
    }
    let ubus_ok = handle_incoming_callback(admin_id, "flt_upd_ok r1", &env.state, &env.core)
        .await
        .expect("flt_upd_ok ubus fallback");
    assert!(ubus_ok.text.contains("[OK]"), "{}", ubus_ok.text);
    assert!(ubus_ok.text.contains("2.0.0-beta.14"), "{}", ubus_ok.text);
    assert_no_token_leak(&ubus_ok, token);
    {
        let st = mock_state.lock().expect("lock mock");
        assert!(
            st.requests
                .iter()
                .any(|(m, p, _)| m == "POST" && p == "/ubus")
        );
    }

    // Confirm Restart -> sends POST /api/core/restart + runs post-action health/version verification
    let rst_ok = handle_incoming_callback(admin_id, "flt_rst_ok r1", &env.state, &env.core)
        .await
        .expect("flt_rst_ok");
    assert!(rst_ok.text.contains("[OK]"), "{}", rst_ok.text);
    assert!(rst_ok.text.contains("2.0.0-beta.14"), "{}", rst_ok.text);
    assert!(
        rst_ok.text.contains("Core: <code>running</code>"),
        "{}",
        rst_ok.text
    );
    assert_no_token_leak(&rst_ok, token);
    {
        let st = mock_state.lock().expect("lock mock");
        assert!(
            st.requests
                .iter()
                .any(|(m, p, _)| m == "POST" && p == "/api/core/restart")
        );
    }
}

#[tokio::test]
async fn test_fleet_add_remove_router_persistence_and_auth_rejection() {
    let _prompt_guard = prompt_test_lock().lock().await;
    let admin_id = 710_004i64;
    clear_chat_prompt(admin_id);

    let env = TempTestEnv::new("fleet_add_remove", admin_id).await;
    let valid_token = "super_secret_fleet_tok_XYZ_777";
    let mock_state = Arc::new(std::sync::Mutex::new(MockRouterState::new(valid_token)));
    let (url, _server_guard) = spawn_mock_router_server(Arc::clone(&mock_state)).await;

    // Step 1: start Add Router prompt -> name -> URL
    let step1 = handle_incoming_callback(admin_id, "flt_add", &env.state, &env.core)
        .await
        .expect("flt_add");
    assert!(!step1.text.is_empty());

    let step2 = handle_incoming_text(admin_id, "Branch-A", &env.state, &env.core)
        .await
        .expect("router name step");
    assert!(step2.text.contains("Branch-A"), "{}", step2.text);

    let step3 = handle_incoming_text(admin_id, &url, &env.state, &env.core)
        .await
        .expect("router url step");
    assert!(step3.text.contains(&url), "{}", step3.text);

    // Reject 401 on wrong token without saving or leaking token
    let wrong_tok = "wrong_tok_401_XYZ";
    let rej_401 = handle_incoming_text(admin_id, wrong_tok, &env.state, &env.core)
        .await
        .expect("401 rejection");
    assert!(rej_401.text.contains("[ERR]"), "{}", rej_401.text);
    assert!(rej_401.text.contains("401"), "{}", rej_401.text);
    assert_no_token_leak(&rej_401, wrong_tok);
    assert!(
        env.state
            .data
            .read()
            .await
            .telegram
            .managed_routers
            .is_empty()
    );

    // Reject 403 on forbidden token without saving or leaking token
    mock_state.lock().expect("lock mock").reject_status = Some(403);
    let tok_403 = "forbidden_tok_403_XYZ";
    let rej_403 = handle_incoming_text(admin_id, tok_403, &env.state, &env.core)
        .await
        .expect("403 rejection");
    assert!(rej_403.text.contains("[ERR]"), "{}", rej_403.text);
    assert!(rej_403.text.contains("403"), "{}", rej_403.text);
    assert_no_token_leak(&rej_403, tok_403);
    assert!(
        env.state
            .data
            .read()
            .await
            .telegram
            .managed_routers
            .is_empty()
    );

    // Allow valid token -> persists to AppState and tachyon-state.json without echoing token
    mock_state.lock().expect("lock mock").reject_status = None;
    let added = handle_incoming_text(admin_id, valid_token, &env.state, &env.core)
        .await
        .expect("valid token accepted");
    assert!(added.text.contains("[OK]"), "{}", added.text);
    assert!(added.text.contains("Branch-A"), "{}", added.text);
    assert!(added.text.contains("configured"), "{}", added.text);
    assert_no_token_leak(&added, valid_token);

    let router_id = {
        let d = env.state.data.read().await;
        assert_eq!(d.telegram.managed_routers.len(), 1);
        assert_eq!(d.telegram.managed_routers[0].name, "Branch-A");
        assert_eq!(d.telegram.managed_routers[0].url, url);
        assert_eq!(d.telegram.managed_routers[0].api_token, valid_token);
        d.telegram.managed_routers[0].id.clone()
    };

    // Reload from disk to verify persistence across restarts
    let reloaded =
        AppState::load_or_create(env.dir.join("tachyon-state.json")).expect("reload state");
    {
        let d = reloaded.data.read().await;
        assert_eq!(d.telegram.managed_routers.len(), 1);
        assert_eq!(d.telegram.managed_routers[0].id, router_id);
        assert_eq!(d.telegram.managed_routers[0].api_token, valid_token);
    }

    // Remote auth rejection (401 and 403) on saved router never leaks token
    for status in [401u16, 403u16] {
        mock_state.lock().expect("lock mock").reject_status = Some(status);
        let view_err = handle_incoming_callback(
            admin_id,
            &format!("flt_view {router_id}"),
            &env.state,
            &env.core,
        )
        .await
        .expect("view auth error");
        assert!(
            view_err.text.contains(&status.to_string()),
            "{}",
            view_err.text
        );
        assert_no_token_leak(&view_err, valid_token);

        let upd_err = handle_incoming_callback(
            admin_id,
            &format!("flt_upd_chk {router_id}"),
            &env.state,
            &env.core,
        )
        .await
        .expect("update check auth error");
        assert!(
            upd_err.text.contains(&status.to_string()),
            "{}",
            upd_err.text
        );
        assert_no_token_leak(&upd_err, valid_token);
    }
    mock_state.lock().expect("lock mock").reject_status = None;

    // Remove router with explicit confirmation
    let del_ask = handle_incoming_callback(
        admin_id,
        &format!("flt_del_ask {router_id}"),
        &env.state,
        &env.core,
    )
    .await
    .expect("flt_del_ask");
    let del_btns = collect_buttons(&del_ask);
    assert!(
        del_btns
            .iter()
            .any(|(_, cb)| cb == &format!("flt_del_ok {router_id}"))
    );
    assert_eq!(
        env.state.data.read().await.telegram.managed_routers.len(),
        1
    );

    let del_ok = handle_incoming_callback(
        admin_id,
        &format!("flt_del_ok {router_id}"),
        &env.state,
        &env.core,
    )
    .await
    .expect("flt_del_ok");
    assert!(del_ok.text.contains("[OK]"), "{}", del_ok.text);
    assert!(
        env.state
            .data
            .read()
            .await
            .telegram
            .managed_routers
            .is_empty()
    );

    let reloaded_after_del =
        AppState::load_or_create(env.dir.join("tachyon-state.json")).expect("reload after del");
    assert!(
        reloaded_after_del
            .data
            .read()
            .await
            .telegram
            .managed_routers
            .is_empty()
    );

    clear_chat_prompt(admin_id);
}

#[test]
fn blackbox_events_do_not_trigger_crash_alerts() {
    let mut obs = BotEventObserver::default();
    let res = classify_event_notification(
        &mut obs,
        "blackbox",
        "Captured tmpfs blackbox bb-1795299147-core_crash_lkg_rollback-539a3b (reason: core_crash_lkg_rollback)",
        1_700_000_000,
        true,
    );
    assert!(res.is_none());
}

#[test]
fn crash_alerts_are_deduplicated_within_300s_window() {
    let mut obs = BotEventObserver::default();
    let msg = "LKG rollback failed; suppressing repeats until config/LKG changes or core recovers: exit 1";
    let first = classify_event_notification(&mut obs, "watchdog", msg, 1_700_000_000, true);
    assert_eq!(first.as_ref().map(|(k, _)| *k), Some("crash"));

    let dup = classify_event_notification(&mut obs, "watchdog", msg, 1_700_000_120, true);
    assert!(dup.is_none());

    let after_window = classify_event_notification(&mut obs, "watchdog", msg, 1_700_000_301, true);
    assert_eq!(after_window.as_ref().map(|(k, _)| *k), Some("crash"));
}

#[test]
fn outbox_notice_skips_duplicate_pending_content() {
    let seq = TEST_DIR_SEQ.fetch_add(1, Ordering::Relaxed);
    let dir = std::env::temp_dir().join(format!(
        "tachyon_tg_outbox_dedup_{}_{}_{seq}",
        std::process::id(),
        crate::store::unix_now_secs()
    ));
    let _ = std::fs::remove_dir_all(&dir);

    assert!(queue_plain_outbox_notice_in(
        &dir,
        "<b>Сбой ядра:</b> rollback failed"
    ));
    assert!(!queue_plain_outbox_notice_in(
        &dir,
        "  <b>Сбой ядра:</b> rollback failed  "
    ));
    assert!(queue_plain_outbox_notice_in(
        &dir,
        "<b>Сбой ядра:</b> another failure"
    ));

    let txt_count = std::fs::read_dir(&dir)
        .expect("read outbox")
        .flatten()
        .filter(|e| e.path().extension().and_then(|s| s.to_str()) == Some("txt"))
        .count();
    assert_eq!(txt_count, 2);

    let _ = std::fs::remove_dir_all(&dir);
}

fn sample_fptn_payload_json() -> Value {
    json!({
        "version": 2,
        "service_name": "DemoNet",
        "username": "alice",
        "password": "secret",
        "servers": [
            { "name": "DE-1", "host": "198.51.100.10", "port": 443 },
            { "name": "NL-1", "host": "198.51.100.11", "port": 8443 }
        ],
        "censorship_zone_servers": [
            { "name": "FI-1", "ip": "198.51.100.12", "port": 443 }
        ]
    })
}

#[test]
fn looks_like_proxy_uri_accepts_fptn_variants_and_json() {
    use base64::Engine as _;
    let raw_json = serde_json::to_string(&sample_fptn_payload_json()).unwrap();
    let b64 = base64::engine::general_purpose::STANDARD.encode(raw_json.as_bytes());
    assert!(looks_like_proxy_uri(&format!("fptn://{b64}")));
    assert!(looks_like_proxy_uri(&format!("fptn:{b64}")));
    assert!(looks_like_proxy_uri("fptnb:YWJjZGVm"));
    assert!(looks_like_proxy_uri("fptnb://YWJjZGVm"));
    assert!(looks_like_proxy_uri(&raw_json));
    assert!(!looks_like_proxy_uri("{\"not_fptn\": true}"));
}

#[tokio::test]
async fn import_fptn_variants_create_fptn_source_not_proxy_links() {
    use base64::Engine as _;
    let _guard = prompt_test_lock().lock().await;
    let admin_id = 91001;
    let env = TempTestEnv::new("fptn_import", admin_id).await;

    let raw_json = serde_json::to_string(&sample_fptn_payload_json()).unwrap();
    let b64 = base64::engine::general_purpose::STANDARD.encode(raw_json.as_bytes());

    let uri = format!("fptn://{b64}");
    let rep1 = Box::pin(dispatch_text_message(admin_id, &uri, &env.state, &env.core)).await;
    assert!(rep1.text.contains("[OK]"), "{}", rep1.text);
    assert!(rep1.text.contains("3 servers"), "{}", rep1.text);

    let multiline = format!("FPTN://{}\n  {}#label", &b64[..20], &b64[20..]);
    set_chat_prompt(admin_id, PendingPromptKind::AddSubscriptionOrUri);
    let rep2 = Box::pin(dispatch_text_message(
        admin_id, &multiline, &env.state, &env.core,
    ))
    .await;
    assert!(rep2.text.contains("[OK]"), "{}", rep2.text);

    let rep3 = Box::pin(dispatch_text_message(
        admin_id, &raw_json, &env.state, &env.core,
    ))
    .await;
    assert!(rep3.text.contains("[OK]"), "{}", rep3.text);

    let d = env.state.data.read().await;
    let fptn_sources: Vec<_> = d
        .outbound_sources
        .iter()
        .filter(|s| s.source_type == "fptn")
        .collect();
    assert_eq!(fptn_sources.len(), 3);
    assert!(
        !d.outbound_sources
            .iter()
            .any(|s| s.source_type == "proxy_links"),
        "FPTN tokens must not be stored as proxy_links"
    );
    for s in fptn_sources {
        assert_eq!(s.name, "FPTN (DemoNet)");
        assert!(s.fptn_access_token.starts_with("fptn:"));
        assert!(!s.fptn_access_token.contains('\n'));
        assert!(!s.fptn_access_token.contains('#'));
    }
}

#[tokio::test]
async fn update_fptn_prompts_normalize_token_and_count_all_servers() {
    use base64::Engine as _;
    let _guard = prompt_test_lock().lock().await;
    let admin_id = 91002;
    let env = TempTestEnv::new("fptn_prompts", admin_id).await;
    {
        let mut d = env.state.data.write().await;
        d.sections.push(RoutingSection {
            id: "sec_fptn".to_string(),
            enabled: true,
            label: "FPTN Sec".to_string(),
            connection_type: "fptn".to_string(),
            action: "fptn".to_string(),
            ..Default::default()
        });
        d.outbound_sources.push(crate::store::OutboundSource {
            id: "src_fptn_1".to_string(),
            enabled: true,
            name: "FPTN Src".to_string(),
            source_type: "fptn".to_string(),
            ..Default::default()
        });
    }

    let raw_json = serde_json::to_string(&sample_fptn_payload_json()).unwrap();
    let b64 = base64::engine::general_purpose::STANDARD.encode(raw_json.as_bytes());
    let fptn_uri = format!("fptn://{b64}");

    set_chat_prompt(
        admin_id,
        PendingPromptKind::UpdateFptnToken {
            sec_id: "sec_fptn".to_string(),
        },
    );
    let sec_rep = Box::pin(dispatch_text_message(
        admin_id, &fptn_uri, &env.state, &env.core,
    ))
    .await;
    assert!(sec_rep.text.contains("[OK]"), "{}", sec_rep.text);
    assert!(sec_rep.text.contains("3"), "{}", sec_rep.text);

    set_chat_prompt(
        admin_id,
        PendingPromptKind::UpdateSourceFptnToken {
            src_id: "src_fptn_1".to_string(),
        },
    );
    let src_rep = Box::pin(dispatch_text_message(
        admin_id, &raw_json, &env.state, &env.core,
    ))
    .await;
    assert!(src_rep.text.contains("[OK]"), "{}", src_rep.text);
    assert!(src_rep.text.contains("3"), "{}", src_rep.text);

    let d = env.state.data.read().await;
    let sec = d.sections.iter().find(|s| s.id == "sec_fptn").unwrap();
    assert_eq!(sec.fptn_access_token, format!("fptn:{b64}"));
    let src = d
        .outbound_sources
        .iter()
        .find(|s| s.id == "src_fptn_1")
        .unwrap();
    assert!(src.fptn_access_token.starts_with("fptn:"));
}
