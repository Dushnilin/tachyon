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
