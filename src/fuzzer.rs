//! Native `tachyon-core` Desync Strategy Fuzzer & Isolated Sandbox Benchmark Runner.
//!
//! Spawns ephemeral `tachyon-core` instances bound to `127.0.0.1:<port>` with
//! `routing_mark = 0x08000000` (`134217728`) so probes traverse the real WAN path
//! without mutating `nftables` or interrupting active LAN sessions.

use std::collections::{HashMap, HashSet};
use std::net::{IpAddr, Ipv4Addr, SocketAddr, SocketAddrV4, TcpListener, TcpStream};
use std::path::Path;
use std::process::Stdio;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

use rand::RngCore;
use serde_json::{Map, Value, json};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpStream as TokioTcpStream, UdpSocket as TokioUdpSocket};
use tokio::process::Command;

use crate::crypto_gen;
use crate::store::unix_now_secs;

const SANDBOX_ROUTING_MARK: u32 = 0x0800_0000; // 134_217_728 — bypasses active TPROXY rules
const STATE_FILE: &str = "/var/run/tachyon/fuzzer-state.json";
const PATTERNS_FILE: &str = "/var/run/tachyon/ui-state/fuzzer-patterns.json";
const HISTORY_FILE: &str = "/var/run/tachyon/ui-state/fuzzer-history.json";
const AI_STRATEGIES_FILE: &str = "/var/run/tachyon/fuzzer_ai_strategies.json";
const MAX_FUZZER_STATE_BYTES: usize = 48_000;
const MAX_FUZZER_ENDPOINTS: usize = 12;
const USER_AGENT: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

static FUZZER_STATE: OnceLock<Mutex<Value>> = OnceLock::new();
static FUZZER_ABORT: AtomicBool = AtomicBool::new(false);
static FUZZER_ACTIVE_PID: AtomicU32 = AtomicU32::new(0);
static FUZZER_JOB_SEQ: AtomicU64 = AtomicU64::new(1);

#[derive(Clone, Debug)]
pub struct StrategySpec {
    pub id: String,
    pub name: String,
    pub args: String,
    pub description: String,
    pub source: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct ProbeEndpoint {
    url: String,
    target_name: String,
    probe_kind: String,
    allow_api_status: bool,
}

#[derive(Clone, Debug)]
struct SingleProbeMetrics {
    target_name: String,
    url: String,
    success: bool,
    http_code: u16,
    handshake_ms: u32,
    ttfb_ms: u32,
    speed_kbps: u32,
    data_bytes: u64,
    data_verified: bool,
    dpi_verdict: &'static str,
    exit_code: i32,
    error: String,
}

fn idle_state_json() -> Value {
    json!({
        "success": true,
        "running": false,
        "completed": false,
        "aborted": false,
        "engine": "desync",
        "target": "youtube_suite",
        "url": "",
        "mode": "presets",
        "phase": "idle",
        "stage": 0,
        "started_at": 0,
        "finished_at": 0,
        "total_strategies": 0,
        "current_index": 0,
        "current_strategy": null,
        "progress_pct": 0,
        "best_strategy": null,
        "dpi_detection": null,
        "results": []
    })
}

fn state_lock() -> &'static Mutex<Value> {
    FUZZER_STATE.get_or_init(|| {
        if let Ok(raw) = std::fs::read_to_string(STATE_FILE)
            && let Ok(mut parsed) = serde_json::from_str::<Value>(&raw)
            && parsed.is_object()
        {
            if parsed.get("running").and_then(Value::as_bool) == Some(true)
                && let Some(obj) = parsed.as_object_mut()
            {
                obj.insert("running".into(), json!(false));
                obj.insert("aborted".into(), json!(true));
            }
            return Mutex::new(parsed);
        }
        Mutex::new(idle_state_json())
    })
}

fn slim_sub_probes_compact(item: &mut Value) {
    let Some(obj) = item.as_object_mut() else {
        return;
    };
    let Some(arr) = obj.get("sub_probes").and_then(Value::as_array) else {
        return;
    };
    let compact: Vec<Value> = arr
        .iter()
        .take(MAX_FUZZER_ENDPOINTS)
        .map(|sp| {
            let name: String = sp
                .get("target_name")
                .and_then(Value::as_str)
                .unwrap_or("")
                .chars()
                .take(32)
                .collect();
            json!({
                "target_name": name,
                "success": sp.get("success").and_then(Value::as_bool).unwrap_or(false),
                "http_code": sp.get("http_code").and_then(Value::as_u64).unwrap_or(0),
                "ttfb_ms": sp.get("ttfb_ms").and_then(Value::as_u64).unwrap_or(0)
            })
        })
        .collect();
    obj.insert("sub_probes".into(), Value::Array(compact));
}

fn strip_sub_probes_minimal(item: &mut Value) {
    let Some(obj) = item.as_object_mut() else {
        return;
    };
    if let Some(arr) = obj.get("sub_probes").and_then(Value::as_array) {
        let minimal: Vec<Value> = arr
            .iter()
            .map(|sp| {
                json!({
                    "success": sp.get("success").and_then(Value::as_bool).unwrap_or(false)
                })
            })
            .collect();
        obj.insert("sub_probes".into(), Value::Array(minimal));
    }
    obj.remove("endpoints");
}

pub fn cap_state_json_under_limit(val: &Value, max_bytes: usize) -> Value {
    if serde_json::to_string(val)
        .map(|s| s.len() <= max_bytes)
        .unwrap_or(true)
    {
        return val.clone();
    }

    let mut out = val.clone();
    if let Some(results) = out.get_mut("results").and_then(Value::as_array_mut) {
        for r in results.iter_mut() {
            slim_sub_probes_compact(r);
        }
    }
    if let Some(best) = out.get_mut("best_strategy")
        && best.is_object()
    {
        slim_sub_probes_compact(best);
    }
    if serde_json::to_string(&out)
        .map(|s| s.len() <= max_bytes)
        .unwrap_or(true)
    {
        return out;
    }

    if let Some(results) = out.get_mut("results").and_then(Value::as_array_mut) {
        for r in results.iter_mut() {
            strip_sub_probes_minimal(r);
        }
    }
    if let Some(best) = out.get_mut("best_strategy")
        && best.is_object()
    {
        strip_sub_probes_minimal(best);
    }

    loop {
        let len = serde_json::to_string(&out).map(|s| s.len()).unwrap_or(0);
        if len <= max_bytes {
            break;
        }
        let Some(results) = out.get_mut("results").and_then(Value::as_array_mut) else {
            break;
        };
        if results.is_empty() {
            break;
        }
        let cut = (results.len() * 3 / 4).min(results.len() - 1);
        results.truncate(cut);
    }
    out
}

fn save_state(val: &Value) {
    let capped = cap_state_json_under_limit(val, MAX_FUZZER_STATE_BYTES);
    if let Ok(mut guard) = state_lock().lock() {
        *guard = capped.clone();
    }
    if cfg!(target_os = "linux") {
        let _ = std::fs::create_dir_all("/var/run/tachyon");
        if let Ok(raw) = serde_json::to_string(&capped) {
            let _ = std::fs::write(STATE_FILE, raw.as_bytes());
        }
    }
}

pub fn get_status() -> Value {
    state_lock()
        .lock()
        .map(|g| g.clone())
        .unwrap_or_else(|_| idle_state_json())
}

pub fn default_patterns_config() -> Value {
    json!({
        "zapret2": {
            "splits": ["1", "2", "midsld", "sniext+4"],
            "foolings": ["tcp_md5", "badsum"],
            "ttls": [4, 5, 6],
            "seqovls": ["1", "2"],
            "wsizes": ["1"],
            "payloads": ["tls_client_hello"]
        },
        "zapret": {
            "splits": ["1", "midsld"],
            "foolings": ["badseq", "md5sig"],
            "ttls": [4, 6],
            "split_modes": ["fake,split2"]
        },
        "byedpi": {
            "splits": ["1", "midsld"],
            "disorders": ["1"],
            "ttls": [4, 6],
            "oobs": ["1"],
            "autos": ["t,r,a,s"],
            "tlsrecs": ["1+sniext"],
            "ipfrags": ["24"]
        },
        "desync": {
            "modes": ["fake_disorder", "fake_split", "tlsrec", "disorder", "split", "oob"],
            "split_poses": ["sni", "midsld", "1,sni", "sni,endhost-1", 1, 2],
            "fake_ttls": [4, 5, 6, 8],
            "fake_snis": ["www.google.com", "ozon.ru", "rzd.ru", "ya.ru", "dl.google.com"],
            "repeats": [1, 2, 3, 4],
            "split_delays": [1, 2, 3],
            "udp_fakes": [true, false]
        },
        "custom_strategies": []
    })
}

pub fn get_patterns() -> Value {
    if let Ok(raw) = std::fs::read_to_string(PATTERNS_FILE)
        && let Ok(val) = serde_json::from_str::<Value>(&raw)
        && val.get("patterns").and_then(|p| p.get("desync")).is_some()
    {
        return val;
    }
    json!({
        "success": true,
        "patterns": default_patterns_config()
    })
}

pub fn save_patterns(raw_arg: &str) -> Value {
    let parsed =
        serde_json::from_str::<Value>(raw_arg).unwrap_or_else(|_| default_patterns_config());
    let patterns = if parsed.get("desync").is_some() {
        parsed
    } else if let Some(inner) = parsed.get("patterns").cloned() {
        inner
    } else {
        default_patterns_config()
    };
    let payload = json!({
        "success": true,
        "message": "Паттерны матрицы сохранены",
        "patterns": patterns
    });
    if cfg!(target_os = "linux") {
        let _ = std::fs::create_dir_all("/var/run/tachyon/ui-state");
        if let Ok(s) = serde_json::to_string(&payload) {
            let _ = crypto_gen::write_file_if_changed(Path::new(PATTERNS_FILE), s.as_bytes());
        }
    }
    payload
}

pub fn reset_patterns() -> Value {
    let _ = std::fs::remove_file(PATTERNS_FILE);
    json!({
        "success": true,
        "message": "Паттерны сброшены к заводским значениям",
        "patterns": default_patterns_config()
    })
}

pub fn builtin_desync_strategies() -> Vec<StrategySpec> {
    let items: &[(&str, &str, &str, &str)] = &[
        (
            "ds_preset_auto",
            "Adaptive Auto-Tune (tachyon-core)",
            "preset=auto",
            "Автоматический адаптивный выбор параметров сегментации и TTL на лету",
        ),
        (
            "ds_preset_fake_disorder",
            "Preset: Fake + Disorder @ SNI",
            "preset=fake_disorder",
            "Отправка ложного пакета с AutoTTL и обратным порядком сегментов TLS",
        ),
        (
            "ds_preset_fake_split",
            "Preset: Fake + Split @ SNI",
            "preset=fake_split",
            "Ложный ClientHello с AutoTTL и разделением записи по полю SNI",
        ),
        (
            "ds_preset_multi_disorder",
            "Preset: Multi-Disorder (SNI + EndHost)",
            "preset=multi_disorder",
            "Многоточечная перестановка сегментов TLS вокруг SNI и конца имени хоста",
        ),
        (
            "ds_preset_multi_split",
            "Preset: Multi-Split (1 + SNI)",
            "preset=multi_split",
            "Двухточечная сегментация первого байта и расширения SNI",
        ),
        (
            "ds_preset_tlsrec",
            "Preset: TLS Record Fragmentation",
            "preset=tlsrec",
            "Дробление TLS ClientHello на уровне записей протокола без модификации TTL",
        ),
        (
            "ds_hostfakesplit_md5_badack",
            "HostFakeSplit + Disorder (MD5+BadACK, seqovl=4)",
            "mode=fake_disorder split_pos=sni,endhost-1 fooling=md5_badack fake_sni=rzd.ru seqovl=4 repeats=2",
            "Двухточечный разрез SNI с перекрытием seqovl=4 и комбинированным MD5+BadACK",
        ),
        (
            "ds_7point_multidisorder",
            "7-Point Multi-Disorder (ozon.ru, seqovl=6)",
            "mode=fake_disorder split_pos=1,3,host,sni,midsld,endhost-1,sniext+4 fooling=md5_badack fake_sni=ozon.ru seqovl=6 repeats=3",
            "Семиточечная перестановка сегментов TCP с перекрытием последовательности",
        ),
        (
            "ds_fakesplit_midsld_autottl",
            "Fake + Split @ MidSLD (AutoTTL, google.com)",
            "mode=fake_split split_pos=midsld fooling=autottl fake_sni=www.google.com repeats=2 split_delay_ms=2",
            "Разрез посередине домена второго уровня с автоматическим расчётом TTL",
        ),
        (
            "ds_fakedisorder_midsld_autottl",
            "Fake + Disorder @ MidSLD (AutoTTL, ya.ru)",
            "mode=fake_disorder split_pos=midsld fooling=autottl fake_sni=ya.ru repeats=2 split_delay_ms=2",
            "Обратный порядок сегментов на середине домена с маскировкой под ya.ru",
        ),
        (
            "ds_fakesplit_badseq_ttl5",
            "Fake + Split @ SNI (BadSeq, TTL=5)",
            "mode=fake_split split_pos=sni fooling=badseq fake_ttl=5 fake_sni=ozon.ru repeats=2 split_delay_ms=2",
            "Смещение номера последовательности TCP с фиксированным TTL=5",
        ),
        (
            "ds_fakesplit_md5sig_ttl6",
            "Fake + Split @ SNI (TCP MD5Sig, TTL=6)",
            "mode=fake_split split_pos=sni fooling=md5sig fake_ttl=6 fake_sni=www.google.com repeats=2 split_delay_ms=2",
            "Опция заголовка TCP MD5 (RFC 2385) с разделением на границе SNI",
        ),
        (
            "ds_fakedisorder_1_sni_badack_ttl4",
            "Multi Fake + Disorder 1+SNI (BadACK, TTL=4)",
            "mode=fake_disorder split_pos=1,sni fooling=badack fake_ttl=4 fake_sni=vk.com repeats=2",
            "Двойной разрез 1+SNI с модификацией подтверждения TCP ACK и малым TTL",
        ),
        (
            "ds_tlsrec_midsld_first",
            "TLS Record Split @ MidSLD (tlsrec_first)",
            "mode=tlsrec split_pos=midsld tlsrec_first=true split_delay_ms=1",
            "Разделение первой TLS-записи посередине SLD без инжекции ложных пакетов",
        ),
        (
            "ds_disorder_wsize2",
            "Window Clamp wsize=2 + Disorder @ 1,MidSLD",
            "mode=disorder split_pos=1,midsld split_delay_ms=2 wsize=2",
            "Ограничение TCP-окна при рукопожатии и обратный порядок отправки сегментов",
        ),
        (
            "ds_syndata_fakesplit",
            "TCP SYN-Data + Fake Split @ SNI",
            "mode=fake_split split_pos=sni fooling=autottl fake_sni=dl.google.com repeats=2 syndata=true",
            "Раннее вложение полезных данных и сегментация на границе SNI",
        ),
        (
            "ds_youtube_quic_hybrid",
            "Hybrid TCP + QUIC UDP Burst (YouTube / H3)",
            "mode=fake_disorder split_pos=sni fooling=autottl fake_sni=www.google.com repeats=3 udp_fake=true udp_repeats=4 udp_fake_ttl=5",
            "Комбинированный профиль для потокового видео TCP 443 и инициализации QUIC UDP 443",
        ),
        (
            "ds_discord_voice_hybrid",
            "Discord Gateway + Voice UDP (udplen=64, 6x)",
            "mode=fake_split split_pos=midsld fooling=autottl fake_sni=cloudflare.com repeats=2 udp_fake=true udp_repeats=6 udp_fake_ttl=6 udplen=64",
            "Сегментация шлюза TLS и серия стартовых UDP-пакетов для голосовых каналов",
        ),
        (
            "ds_gaming_cs2_faceit",
            "Gaming & Matchmaking TCP+UDP (CS2 / Faceit)",
            "mode=fake_split split_pos=sni fooling=autottl fake_sni=ozon.ru repeats=2 udp_fake=true udp_repeats=6 udp_fake_ttl=5",
            "Низколатентный профиль без задержек сегментации для игровых API и UDP",
        ),
        (
            "ds_preset_disorder",
            "Pure TCP Disorder @ SNI",
            "preset=disorder",
            "Перестановка сегментов TCP без отправки ложных пакетов (нулевой риск HTTP 400)",
        ),
        (
            "ds_preset_split",
            "Pure TCP Split @ SNI",
            "preset=split",
            "Базовое разделение TCP-сегмента по смещению поля SNI",
        ),
        (
            "ds_oob_midsld",
            "TCP OOB Urgent Pointer @ MidSLD",
            "mode=oob split_pos=midsld split_delay_ms=1",
            "Внеполосный байт TCP Urgent Pointer на границе имени домена",
        ),
    ];

    items
        .iter()
        .map(|(id, name, args, desc)| StrategySpec {
            id: (*id).to_string(),
            name: (*name).to_string(),
            args: (*args).to_string(),
            description: (*desc).to_string(),
            source: "tachyon-core".to_string(),
        })
        .collect()
}

fn generate_combinatorial_strategies(patterns: &Value, cap: usize) -> Vec<StrategySpec> {
    let ds = patterns.get("desync");
    let modes: Vec<String> = ds
        .and_then(|d| d.get("modes"))
        .and_then(Value::as_array)
        .map(|a| {
            a.iter()
                .filter_map(|v| v.as_str().map(String::from))
                .collect()
        })
        .filter(|v: &Vec<String>| !v.is_empty())
        .unwrap_or_else(|| vec!["fake_disorder".into(), "fake_split".into(), "tlsrec".into()]);

    let split_poses: Vec<String> = ds
        .and_then(|d| d.get("split_poses"))
        .and_then(Value::as_array)
        .map(|a| {
            a.iter()
                .filter_map(|v| {
                    v.as_str()
                        .map(String::from)
                        .or_else(|| v.as_i64().map(|n| n.to_string()))
                })
                .collect()
        })
        .filter(|v: &Vec<String>| !v.is_empty())
        .unwrap_or_else(|| vec!["sni".into(), "midsld".into(), "1,sni".into()]);

    let ttls: Vec<u8> = ds
        .and_then(|d| d.get("fake_ttls"))
        .and_then(Value::as_array)
        .map(|a| {
            a.iter()
                .filter_map(|v| v.as_u64().map(|n| n as u8))
                .collect()
        })
        .filter(|v: &Vec<u8>| !v.is_empty())
        .unwrap_or_else(|| vec![4, 5, 6]);

    let snis: Vec<String> = ds
        .and_then(|d| d.get("fake_snis"))
        .and_then(Value::as_array)
        .map(|a| {
            a.iter()
                .filter_map(|v| v.as_str().map(String::from))
                .collect()
        })
        .filter(|v: &Vec<String>| !v.is_empty())
        .unwrap_or_else(|| vec!["www.google.com".into(), "ozon.ru".into()]);

    let repeats: Vec<u8> = ds
        .and_then(|d| d.get("repeats"))
        .and_then(Value::as_array)
        .map(|a| {
            a.iter()
                .filter_map(|v| v.as_u64().map(|n| n as u8))
                .collect()
        })
        .filter(|v: &Vec<u8>| !v.is_empty())
        .unwrap_or_else(|| vec![2, 3]);

    let mut out = Vec::new();
    let mut seq = 1usize;
    'outer: for mode in &modes {
        for sp in &split_poses {
            if mode == "tlsrec" || mode == "split" || mode == "disorder" || mode == "oob" {
                let args = format!("mode={mode} split_pos={sp} split_delay_ms=1");
                out.push(StrategySpec {
                    id: format!("ds_matrix_{seq}"),
                    name: format!("Matrix #{seq}: {mode} @ {sp}"),
                    args,
                    description: format!("Комбинаторный профиль {mode} со смещением {sp}"),
                    source: "matrix".to_string(),
                });
                seq += 1;
                if out.len() >= cap {
                    break 'outer;
                }
            } else {
                for &ttl in ttls.iter().take(2) {
                    let sni = &snis[(seq - 1) % snis.len()];
                    let rep = repeats[(seq - 1) % repeats.len()];
                    let args = format!(
                        "mode={mode} split_pos={sp} fooling=badseq fake_ttl={ttl} fake_sni={sni} repeats={rep}"
                    );
                    out.push(StrategySpec {
                        id: format!("ds_matrix_{seq}"),
                        name: format!("Matrix #{seq}: {mode} @ {sp} TTL={ttl}"),
                        args,
                        description: format!(
                            "Комбинаторный профиль {mode} ({sp}, TTL={ttl}, SNI={sni})"
                        ),
                        source: "matrix".to_string(),
                    });
                    seq += 1;
                    if out.len() >= cap {
                        break 'outer;
                    }
                }
            }
        }
    }
    out
}

fn load_custom_strategies(patterns: &Value) -> Vec<StrategySpec> {
    let mut out = Vec::new();
    if let Some(arr) = patterns.get("custom_strategies").and_then(Value::as_array) {
        for (i, item) in arr.iter().enumerate() {
            let eng = item
                .get("engine")
                .and_then(Value::as_str)
                .unwrap_or("desync");
            if eng != "desync" {
                continue;
            }
            let Some(args) = item.get("args").and_then(Value::as_str) else {
                continue;
            };
            if args.trim().is_empty() {
                continue;
            }
            let name = item
                .get("name")
                .and_then(Value::as_str)
                .filter(|s| !s.trim().is_empty())
                .unwrap_or("Пользовательская стратегия");
            out.push(StrategySpec {
                id: item
                    .get("id")
                    .and_then(Value::as_str)
                    .map(String::from)
                    .unwrap_or_else(|| format!("custom_ds_{}", i + 1)),
                name: name.to_string(),
                args: args.trim().to_string(),
                description: item
                    .get("description")
                    .and_then(Value::as_str)
                    .unwrap_or("Пользовательский профиль tachyon-core desync")
                    .to_string(),
                source: "custom".to_string(),
            });
        }
    }
    out
}

pub fn is_desync_engine_installed(bin_path: &str) -> bool {
    let trimmed = bin_path.trim();
    if trimmed.is_empty() {
        return false;
    }
    let p = Path::new(trimmed);
    if p.components().count() > 1 || trimmed.contains('/') || trimmed.contains('\\') {
        return p.is_file();
    }
    if Path::new("/usr/bin").join(trimmed).is_file() {
        return true;
    }
    if let Some(paths) = std::env::var_os("PATH") {
        for dir in std::env::split_paths(&paths) {
            if dir.join(trimmed).is_file() {
                return true;
            }
        }
    }
    false
}

pub fn validate_engine_request(engine: &str, bin_path: &str) -> Result<&'static str, String> {
    let norm = engine.trim().to_ascii_lowercase();
    match norm.as_str() {
        "desync" => {
            if is_desync_engine_installed(bin_path) {
                Ok("desync")
            } else {
                Err("Бинарный файл tachyon-core не установлен на маршрутизаторе".to_string())
            }
        }
        "all" => Err("Режим 'all' отключён; выберите установленный движок (desync)".to_string()),
        "zapret2" | "zapret" | "byedpi" => Err(format!(
            "Движок '{norm}' не установлен в pure-Rust сборке tachyon"
        )),
        "" => Err("Не указан движок проверки стратегий".to_string()),
        other => Err(format!("Неподдерживаемый движок: '{other}'")),
    }
}

pub fn is_pure_udp_strategy(spec: &StrategySpec) -> bool {
    let a = spec.args.to_ascii_lowercase();
    if a.contains("--filter-udp") && !a.contains("--filter-tcp") {
        return true;
    }
    a.contains("udp_fake=true") && !a.contains("mode=") && !a.contains("preset=")
}

pub fn target_includes_udp(target: &str, custom_url: &str) -> bool {
    let t = target.to_ascii_lowercase();
    let cu = custom_url.to_ascii_lowercase();
    t.contains("quic_http3")
        || t.contains("gaming_udp")
        || t.contains("discord")
        || t.contains("cs2")
        || t.contains("faceit")
        || t.contains("udp://")
        || cu.contains("udp://")
}

pub fn filter_strategies_for_target(
    list: Vec<StrategySpec>,
    target: &str,
    custom_url: &str,
) -> Vec<StrategySpec> {
    if (target.trim().is_empty() && custom_url.trim().is_empty())
        || target_includes_udp(target, custom_url)
    {
        return list;
    }
    list.into_iter()
        .filter(|s| !is_pure_udp_strategy(s))
        .collect()
}

#[cfg(test)]
pub fn get_strategies_catalog(mode: &str, engine_filter: &str, bin_path: &str) -> Value {
    get_strategies_catalog_for_target(mode, engine_filter, "", bin_path)
}

pub fn get_strategies_catalog_for_target(
    mode: &str,
    engine_filter: &str,
    target: &str,
    bin_path: &str,
) -> Value {
    let desync_installed = is_desync_engine_installed(bin_path);
    let available_engines = json!({
        "zapret2": false,
        "zapret": false,
        "byedpi": false,
        "desync": desync_installed
    });

    let ef = engine_filter.trim();
    if !ef.is_empty()
        && let Err(err) = validate_engine_request(ef, bin_path)
    {
        return json!({
            "success": false,
            "error": err,
            "available_engines": available_engines,
            "zapret2": [],
            "zapret": [],
            "byedpi": [],
            "desync": [],
            "strategies": []
        });
    }

    if !desync_installed {
        return json!({
            "success": true,
            "available_engines": available_engines,
            "zapret2": [],
            "zapret": [],
            "byedpi": [],
            "desync": [],
            "strategies": []
        });
    }

    let patterns = get_patterns()
        .get("patterns")
        .cloned()
        .unwrap_or_else(default_patterns_config);
    let mut list = builtin_desync_strategies();
    list.extend(load_custom_strategies(&patterns));
    if mode == "deep" || mode == "combinatorial" {
        list.extend(generate_combinatorial_strategies(&patterns, 24));
    }
    let filtered = filter_strategies_for_target(list, target, "");

    let desync_json: Vec<Value> = filtered
        .iter()
        .map(|s| {
            json!({
                "id": s.id,
                "name": s.name,
                "description": s.description,
                "engine": "desync",
                "args": s.args,
                "source": s.source,
            })
        })
        .collect();

    json!({
        "success": true,
        "available_engines": available_engines,
        "zapret2": [],
        "zapret": [],
        "byedpi": [],
        "desync": desync_json,
        "strategies": desync_json
    })
}

fn parse_split_pos_value(raw: &str) -> Value {
    let trimmed = raw.trim();
    if trimmed.contains(',') {
        let parts: Vec<Value> = trimmed
            .split(',')
            .map(str::trim)
            .filter(|p| !p.is_empty())
            .map(|p| {
                if let Ok(n) = p.parse::<i64>() {
                    json!(n)
                } else {
                    json!(p)
                }
            })
            .collect();
        Value::Array(parts)
    } else if let Ok(n) = trimmed.parse::<i64>() {
        json!(n)
    } else {
        json!(trimmed)
    }
}

/// Convert a `desync` strategy argument string (`mode=fake_disorder split_pos=sni,endhost-1 ...`)
/// into a validated `tachyon-core` `"type": "desync"` outbound JSON object.
pub fn parse_desync_args_to_outbound(args_str: &str, tag: &str, sandbox_mark: bool) -> Value {
    let mut obj = Map::new();
    obj.insert("type".into(), json!("desync"));
    obj.insert("tag".into(), json!(tag));

    let mut has_preset_or_mode = false;
    let mut is_hostfakesplit = false;
    let mut explicit_host_fake = false;

    for tok in args_str.split_whitespace() {
        let Some((k, v)) = tok.split_once('=') else {
            continue;
        };
        let key = k.trim();
        let val = v.trim();
        if key.is_empty() || val.is_empty() {
            continue;
        }
        match key {
            "preset" => {
                let p = if val == "adaptive" { "auto" } else { val };
                obj.insert("preset".into(), json!(p));
                has_preset_or_mode = true;
            }
            "mode" => {
                if val == "hostfakesplit" {
                    is_hostfakesplit = true;
                }
                obj.insert("mode".into(), json!(val));
                has_preset_or_mode = true;
            }
            "split_pos" => {
                obj.insert("split_pos".into(), parse_split_pos_value(val));
            }
            "fooling" => {
                obj.insert("fooling".into(), json!(val));
            }
            "fake_ttl" | "ttl" => {
                if let Ok(n) = val.parse::<u8>() {
                    obj.insert("fake_ttl".into(), json!(n.clamp(1, 128)));
                }
            }
            "fake_sni" => {
                obj.insert("fake_sni".into(), json!(val));
            }
            "repeats" => {
                if let Ok(n) = val.parse::<u8>() {
                    obj.insert("repeats".into(), json!(n.clamp(1, 16)));
                }
            }
            "split_delay_ms" => {
                if let Ok(n) = val.parse::<u32>() {
                    obj.insert("split_delay_ms".into(), json!(n.min(500)));
                }
            }
            "udp_fake" | "quic_fake" => {
                obj.insert("udp_fake".into(), json!(val == "true" || val == "1"));
            }
            "udp_repeats" => {
                if let Ok(n) = val.parse::<u8>() {
                    obj.insert("udp_repeats".into(), json!(n.clamp(1, 16)));
                }
            }
            "udp_fake_ttl" => {
                if let Ok(n) = val.parse::<u8>() {
                    obj.insert("udp_fake_ttl".into(), json!(n.clamp(1, 128)));
                }
            }
            "seqovl" => {
                if let Ok(n) = val.parse::<u16>() {
                    obj.insert("seqovl".into(), json!(n));
                }
            }
            "syndata" => {
                obj.insert("syndata".into(), json!(val == "true" || val == "1"));
            }
            "wsize" => {
                if let Ok(n) = val.parse::<u32>() {
                    obj.insert("wsize".into(), json!(n));
                }
            }
            "wscale" | "scale" => {
                if let Ok(n) = val.parse::<u8>() {
                    obj.insert("wscale".into(), json!(n.clamp(0, 14)));
                }
            }
            "ipfrag" => {
                obj.insert("ipfrag".into(), json!(val == "true" || val == "1"));
            }
            "udplen" => {
                if let Ok(n) = val.parse::<u16>() {
                    obj.insert("udplen".into(), json!(n));
                }
            }
            "tlsrec_first" => {
                obj.insert("tlsrec_first".into(), json!(val == "true" || val == "1"));
            }
            "auto_tune" => {
                obj.insert("auto_tune".into(), json!(val == "true" || val == "1"));
            }
            "host_fake" => {
                explicit_host_fake = true;
                obj.insert("host_fake".into(), json!(val == "true" || val == "1"));
            }
            "sni_pool" => {
                let pool: Vec<Value> = val
                    .split(',')
                    .map(str::trim)
                    .filter(|s| !s.is_empty())
                    .map(|s| json!(s))
                    .collect();
                if !pool.is_empty() {
                    obj.insert("sni_pool".into(), Value::Array(pool));
                }
            }
            "fake_payload" => {
                obj.insert("fake_payload".into(), json!(val));
            }
            "fake_tls" => {
                obj.insert("fake_tls".into(), json!(val));
            }
            _ => {}
        }
    }

    if is_hostfakesplit && !explicit_host_fake {
        obj.insert("host_fake".into(), json!(true));
    }
    if !has_preset_or_mode {
        obj.insert("preset".into(), json!("auto"));
    }
    if sandbox_mark {
        obj.insert("routing_mark".into(), json!(SANDBOX_ROUTING_MARK));
    }

    Value::Object(obj)
}

/// Apply parsed `desync` strategy fields onto a UCI/JSON section object (`outbound_source` or `section`).
pub fn apply_desync_args_to_section_map(sec_obj: &mut Map<String, Value>, args_str: &str) {
    let stale_keys = [
        "desync_preset",
        "desync_mode",
        "desync_split_pos",
        "desync_fooling",
        "desync_fake_ttl",
        "desync_ttl",
        "desync_fake_sni",
        "desync_repeats",
        "desync_split_delay_ms",
        "desync_tlsrec_first",
        "desync_seqovl",
        "desync_syndata",
        "desync_wsize",
        "desync_wscale",
        "desync_ipfrag",
        "desync_udp_fake",
        "desync_quic_fake",
        "desync_udp_repeats",
        "desync_udp_fake_ttl",
        "desync_udplen",
        "desync_auto_tune",
        "desync_host_fake",
        "desync_sni_pool",
        "desync_fake_payload",
        "desync_fake_tls",
    ];
    for k in stale_keys {
        sec_obj.remove(k);
    }
    sec_obj.insert("desync_opts".into(), json!(args_str.trim()));

    let mut explicit_preset = false;
    let mut is_hostfakesplit = false;
    let mut explicit_host_fake = false;
    for tok in args_str.split_whitespace() {
        let Some((k, v)) = tok.split_once('=') else {
            continue;
        };
        let key = k.trim();
        let val = v.trim();
        match key {
            "preset" => {
                sec_obj.insert("desync_preset".into(), json!(val));
                explicit_preset = true;
            }
            "mode" => {
                if val == "hostfakesplit" {
                    is_hostfakesplit = true;
                }
                sec_obj.insert("desync_mode".into(), json!(val));
            }
            "split_pos" => {
                sec_obj.insert("desync_split_pos".into(), json!(val));
            }
            "fooling" => {
                sec_obj.insert("desync_fooling".into(), json!(val));
            }
            "fake_ttl" | "ttl" => {
                if let Ok(n) = val.parse::<u8>() {
                    let clamped = n.clamp(1, 128).to_string();
                    sec_obj.insert("desync_fake_ttl".into(), json!(clamped));
                    sec_obj.insert("desync_ttl".into(), json!(clamped));
                }
            }
            "fake_sni" => {
                sec_obj.insert("desync_fake_sni".into(), json!(val));
            }
            "repeats" => {
                sec_obj.insert("desync_repeats".into(), json!(val));
            }
            "split_delay_ms" => {
                sec_obj.insert("desync_split_delay_ms".into(), json!(val));
            }
            "tlsrec_first" => {
                let b = if val == "true" || val == "1" {
                    "1"
                } else {
                    "0"
                };
                sec_obj.insert("desync_tlsrec_first".into(), json!(b));
            }
            "seqovl" => {
                sec_obj.insert("desync_seqovl".into(), json!(val));
            }
            "syndata" => {
                let b = if val == "true" || val == "1" {
                    "1"
                } else {
                    "0"
                };
                sec_obj.insert("desync_syndata".into(), json!(b));
            }
            "wsize" => {
                sec_obj.insert("desync_wsize".into(), json!(val));
            }
            "wscale" | "scale" => {
                if let Ok(n) = val.parse::<u8>() {
                    sec_obj.insert("desync_wscale".into(), json!(n.clamp(0, 14).to_string()));
                }
            }
            "ipfrag" => {
                let b = if val == "true" || val == "1" {
                    "1"
                } else {
                    "0"
                };
                sec_obj.insert("desync_ipfrag".into(), json!(b));
            }
            "udp_fake" | "quic_fake" => {
                let b = if val == "true" || val == "1" {
                    "1"
                } else {
                    "0"
                };
                sec_obj.insert("desync_udp_fake".into(), json!(b));
                sec_obj.insert("desync_quic_fake".into(), json!(b));
            }
            "udp_repeats" => {
                sec_obj.insert("desync_udp_repeats".into(), json!(val));
            }
            "udp_fake_ttl" => {
                if let Ok(n) = val.parse::<u8>() {
                    sec_obj.insert(
                        "desync_udp_fake_ttl".into(),
                        json!(n.clamp(1, 128).to_string()),
                    );
                }
            }
            "udplen" => {
                sec_obj.insert("desync_udplen".into(), json!(val));
            }
            "auto_tune" => {
                let b = if val == "true" || val == "1" {
                    "1"
                } else {
                    "0"
                };
                sec_obj.insert("desync_auto_tune".into(), json!(b));
            }
            "host_fake" => {
                explicit_host_fake = true;
                let b = if val == "true" || val == "1" {
                    "1"
                } else {
                    "0"
                };
                sec_obj.insert("desync_host_fake".into(), json!(b));
            }
            "sni_pool" => {
                let cleaned: Vec<&str> = val
                    .split(',')
                    .map(str::trim)
                    .filter(|s| !s.is_empty())
                    .collect();
                if !cleaned.is_empty() {
                    sec_obj.insert("desync_sni_pool".into(), json!(cleaned.join(",")));
                }
            }
            "fake_payload" => {
                sec_obj.insert("desync_fake_payload".into(), json!(val));
            }
            "fake_tls" => {
                sec_obj.insert("desync_fake_tls".into(), json!(val));
            }
            _ => {}
        }
    }
    if is_hostfakesplit && !explicit_host_fake {
        sec_obj.insert("desync_host_fake".into(), json!("1"));
    }
    if !explicit_preset {
        sec_obj.insert("desync_preset".into(), json!("custom"));
    }
}

pub fn is_valid_hostname(host: &str) -> bool {
    let host = host.trim();
    if host.is_empty() || host.len() > 253 {
        return false;
    }
    if host.parse::<Ipv4Addr>().is_ok() {
        return true;
    }
    let mut has_label = false;
    for label in host.split('.') {
        if label.is_empty() || label.len() > 63 {
            return false;
        }
        let bytes = label.as_bytes();
        if !bytes[0].is_ascii_alphanumeric() || !bytes[bytes.len() - 1].is_ascii_alphanumeric() {
            return false;
        }
        if !bytes
            .iter()
            .all(|b| b.is_ascii_alphanumeric() || *b == b'-')
        {
            return false;
        }
        has_label = true;
    }
    has_label
}

pub fn normalize_target_url(raw: &str) -> Option<String> {
    let trimmed = raw.trim().trim_matches(|c| c == ',' || c == ';').trim();
    if trimmed.is_empty() || trimmed.len() > 1024 {
        return None;
    }
    if trimmed.chars().any(|c| {
        c.is_ascii_whitespace()
            || matches!(
                c,
                ';' | '|'
                    | '&'
                    | '$'
                    | '`'
                    | '<'
                    | '>'
                    | '\\'
                    | '\''
                    | '"'
                    | '{'
                    | '}'
                    | '('
                    | ')'
                    | '['
                    | ']'
            )
    }) {
        return None;
    }

    let (scheme, rest, had_scheme) = if let Some(idx) = trimmed.find("://") {
        let sch = trimmed[..idx].to_ascii_lowercase();
        if !matches!(sch.as_str(), "http" | "https" | "udp") {
            return None;
        }
        (sch, &trimmed[idx + 3..], true)
    } else {
        ("https".to_string(), trimmed, false)
    };

    let (authority, path_part) = match rest.find('/') {
        Some(idx) => (&rest[..idx], &rest[idx..]),
        None => (rest, ""),
    };
    if authority.is_empty() {
        return None;
    }

    let (host, port_part) = match authority.split_once(':') {
        Some((h, p)) => (h, Some(p)),
        None => (authority, None),
    };

    if !had_scheme && !host.contains('.') {
        return None;
    }
    if !is_valid_hostname(host) {
        return None;
    }
    if let Some(p_str) = port_part {
        if p_str.is_empty() || p_str.len() > 5 {
            return None;
        }
        let Ok(port_num) = p_str.parse::<u16>() else {
            return None;
        };
        if port_num == 0 {
            return None;
        }
    }

    if path_part.contains('?') && path_part.contains('#') {
        return None;
    }

    Some(format!(
        "{scheme}://{host}{}{path_part}",
        port_part.map(|p| format!(":{p}")).unwrap_or_default()
    ))
}

pub fn validate_custom_targets_input(raw: &str) -> Result<Vec<String>, String> {
    let text = raw.trim();
    if text.is_empty() {
        return Err("Не указаны целевые домены или URL".to_string());
    }
    let mut seen = HashSet::new();
    let mut urls = Vec::new();
    for tok in text.split(|c: char| c.is_ascii_whitespace() || c == ',' || c == ';') {
        let tok = tok.trim();
        if tok.is_empty() {
            continue;
        }
        let Some(norm) = normalize_target_url(tok) else {
            return Err(format!("Некорректный домен или URL цели: '{tok}'"));
        };
        if seen.insert(norm.clone()) {
            urls.push(norm);
        }
    }
    if urls.is_empty() {
        return Err("Не указаны целевые домены или URL".to_string());
    }
    Ok(urls)
}

fn display_target_name(url: &str) -> String {
    let no_scheme = url.find("://").map(|i| &url[i + 3..]).unwrap_or(url);
    no_scheme
        .split('/')
        .next()
        .filter(|s| !s.is_empty())
        .unwrap_or(url)
        .to_string()
}

fn push_unique_endpoint(
    endpoints: &mut Vec<ProbeEndpoint>,
    url: &str,
    target_name: Option<&str>,
    probe_kind: Option<&str>,
    allow_api: bool,
) {
    if !endpoints.iter().any(|e| e.url == url) {
        let kind = probe_kind
            .unwrap_or_else(|| {
                if url.starts_with("udp://") {
                    "udp_stun"
                } else {
                    "tls_http"
                }
            })
            .to_string();
        let name = target_name
            .map(String::from)
            .unwrap_or_else(|| display_target_name(url));
        endpoints.push(ProbeEndpoint {
            url: url.to_string(),
            target_name: name,
            probe_kind: kind,
            allow_api_status: allow_api,
        });
    }
}

fn resolve_suite_endpoints(target: &str, custom_url: &str) -> Vec<ProbeEndpoint> {
    let mut endpoints: Vec<ProbeEndpoint> = Vec::new();
    let custom_trimmed = custom_url.trim();
    let target_trimmed = target.trim();

    if !custom_trimmed.is_empty()
        && (target_trimmed.is_empty()
            || target_trimmed
                .split(',')
                .any(|p| p.trim().eq_ignore_ascii_case("custom")))
        && let Ok(custom_list) = validate_custom_targets_input(custom_trimmed)
    {
        for u in custom_list {
            let kind = if u.starts_with("udp://") {
                "udp_stun"
            } else {
                "tls_http"
            };
            push_unique_endpoint(&mut endpoints, &u, None, Some(kind), true);
        }
    }

    for part in target_trimmed
        .split(',')
        .map(str::trim)
        .filter(|s| !s.is_empty())
    {
        match part {
            "youtube" | "youtube_suite" => {
                push_unique_endpoint(
                    &mut endpoints,
                    "https://www.youtube.com",
                    Some("www.youtube.com"),
                    Some("tls_http"),
                    false,
                );
                push_unique_endpoint(
                    &mut endpoints,
                    "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg",
                    Some("i.ytimg.com"),
                    Some("tls_http"),
                    false,
                );
            }
            "discord" | "discord_suite" => {
                push_unique_endpoint(
                    &mut endpoints,
                    "https://discord.com/api/v9/experiments",
                    Some("discord.com"),
                    Some("tls_http"),
                    true,
                );
                push_unique_endpoint(
                    &mut endpoints,
                    "https://gateway.discord.gg",
                    Some("gateway.discord.gg"),
                    Some("tls_http"),
                    true,
                );
            }
            "cs2_faceit_suite" | "gaming_udp_suite" => {
                push_unique_endpoint(
                    &mut endpoints,
                    "https://www.faceit.com",
                    Some("www.faceit.com"),
                    Some("tls_http"),
                    true,
                );
                push_unique_endpoint(
                    &mut endpoints,
                    "https://api.steampowered.com/ISteamWebAPIUtil/GetServerInfo/v1/",
                    Some("api.steampowered.com"),
                    Some("tls_http"),
                    true,
                );
            }
            "twitch" | "twitch_suite" => {
                push_unique_endpoint(
                    &mut endpoints,
                    "https://www.twitch.tv",
                    Some("www.twitch.tv"),
                    Some("tls_http"),
                    false,
                );
            }
            "twitter" | "twitter_suite" => {
                push_unique_endpoint(
                    &mut endpoints,
                    "https://x.com",
                    Some("x.com"),
                    Some("tls_http"),
                    true,
                );
            }
            "chatgpt" | "chatgpt_suite" => {
                push_unique_endpoint(
                    &mut endpoints,
                    "https://chatgpt.com",
                    Some("chatgpt.com"),
                    Some("tls_http"),
                    true,
                );
                push_unique_endpoint(
                    &mut endpoints,
                    "https://api.openai.com/v1/models",
                    Some("api.openai.com"),
                    Some("tls_http"),
                    true,
                );
            }
            "instagram" | "instagram_suite" => {
                push_unique_endpoint(
                    &mut endpoints,
                    "https://www.instagram.com",
                    Some("www.instagram.com"),
                    Some("tls_http"),
                    true,
                );
            }
            "telegram" | "telegram_suite" => {
                push_unique_endpoint(
                    &mut endpoints,
                    "https://web.telegram.org",
                    Some("web.telegram.org"),
                    Some("tls_http"),
                    false,
                );
                push_unique_endpoint(
                    &mut endpoints,
                    "https://api.telegram.org",
                    Some("api.telegram.org"),
                    Some("tls_http"),
                    true,
                );
            }
            "rutracker" | "rutracker_suite" => {
                push_unique_endpoint(
                    &mut endpoints,
                    "https://rutracker.org",
                    Some("rutracker.org"),
                    Some("tls_http"),
                    true,
                );
            }
            "quic_http3" => {
                push_unique_endpoint(
                    &mut endpoints,
                    "https://www.youtube.com",
                    Some("www.youtube.com"),
                    Some("tls_http"),
                    false,
                );
                push_unique_endpoint(
                    &mut endpoints,
                    "https://cloudflare-quic.com",
                    Some("cloudflare-quic.com"),
                    Some("tls_http"),
                    false,
                );
            }
            "custom" => {
                if let Ok(custom_list) = validate_custom_targets_input(custom_trimmed) {
                    for u in custom_list {
                        let kind = if u.starts_with("udp://") {
                            "udp_stun"
                        } else {
                            "tls_http"
                        };
                        push_unique_endpoint(&mut endpoints, &u, None, Some(kind), true);
                    }
                }
            }
            other => {
                if let Some(norm) = normalize_target_url(other) {
                    push_unique_endpoint(&mut endpoints, &norm, None, None, true);
                }
            }
        }
    }

    if endpoints.is_empty() && custom_trimmed.is_empty() {
        push_unique_endpoint(
            &mut endpoints,
            "https://www.youtube.com",
            Some("www.youtube.com"),
            Some("tls_http"),
            false,
        );
    }
    endpoints.truncate(MAX_FUZZER_ENDPOINTS);
    endpoints
}

fn pick_sandbox_port() -> u16 {
    for port in 11090..11160 {
        let addr = SocketAddrV4::new(Ipv4Addr::LOCALHOST, port);
        if TcpListener::bind(addr).is_ok() {
            return port;
        }
    }
    11090
}

async fn wait_local_port_ready(port: u16, max_wait_ms: u64) -> bool {
    let deadline = Instant::now() + Duration::from_millis(max_wait_ms);
    let addr = SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::LOCALHOST, port));
    while Instant::now() < deadline {
        if FUZZER_ABORT.load(Ordering::Relaxed) {
            return false;
        }
        if TcpStream::connect_timeout(&addr, Duration::from_millis(25)).is_ok() {
            return true;
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    false
}

fn extract_host_port(url: &str) -> Option<(String, u16)> {
    let (scheme, rest) = url.split_once("://")?;
    let default_port: u16 = match scheme.to_ascii_lowercase().as_str() {
        "http" => 80,
        "https" => 443,
        "udp" => 19302,
        _ => return None,
    };
    let authority = rest.split('/').next().unwrap_or(rest);
    if authority.is_empty() {
        return None;
    }
    let host = crate::config_gen::extract_host_only(authority);
    if host.is_empty() {
        return None;
    }
    let port = crate::config_gen::extract_host_port(authority, default_port);
    Some((host, port))
}

async fn prewarm_dns_cache(endpoints: &[ProbeEndpoint]) -> HashMap<(String, u16), IpAddr> {
    let mut cache = HashMap::new();
    let mut seen = HashSet::new();
    for ep in endpoints {
        let Some((host, port)) = extract_host_port(&ep.url) else {
            continue;
        };
        if host.parse::<IpAddr>().is_ok() || !seen.insert((host.clone(), port)) {
            continue;
        }
        let chosen: Option<IpAddr> = {
            let lookup = tokio::time::timeout(
                Duration::from_secs(2),
                tokio::net::lookup_host((host.as_str(), port)),
            )
            .await;
            if let Ok(Ok(addrs)) = lookup {
                let mut picked: Option<IpAddr> = None;
                for sa in addrs {
                    let ip = sa.ip();
                    if ip.is_ipv4() {
                        picked = Some(ip);
                        break;
                    }
                    if picked.is_none() {
                        picked = Some(ip);
                    }
                }
                picked
            } else {
                None
            }
        };
        if let Some(ip) = chosen {
            cache.insert((host, port), ip);
        }
    }
    cache
}

async fn run_udp_stun_via_socks(
    socks_port: u16,
    ep: &ProbeEndpoint,
    dns_cache: &HashMap<(String, u16), IpAddr>,
) -> SingleProbeMetrics {
    let fail = |verdict: &'static str, code: i32, msg: String| SingleProbeMetrics {
        target_name: ep.target_name.clone(),
        url: ep.url.clone(),
        success: false,
        http_code: 0,
        handshake_ms: 0,
        ttfb_ms: 0,
        speed_kbps: 0,
        data_bytes: 0,
        data_verified: false,
        dpi_verdict: verdict,
        exit_code: code,
        error: msg,
    };

    let Some((host, dst_port)) = extract_host_port(&ep.url) else {
        return fail("drop", 1, "Некорректный UDP-адрес цели".to_string());
    };
    let dst_ip: Option<IpAddr> = host
        .parse::<IpAddr>()
        .ok()
        .or_else(|| dns_cache.get(&(host.clone(), dst_port)).copied());

    let started = Instant::now();
    let tcp_addr = SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::LOCALHOST, socks_port));
    let Ok(Ok(mut tcp)) =
        tokio::time::timeout(Duration::from_secs(2), TokioTcpStream::connect(tcp_addr)).await
    else {
        return fail(
            "conn_refused",
            7,
            "Нет подключения к SOCKS5 песочницы".to_string(),
        );
    };

    if tcp.write_all(&[0x05, 0x01, 0x00]).await.is_err() {
        return fail("drop", 1, "Ошибка рукопожатия SOCKS5".to_string());
    }
    let mut greeting = [0u8; 2];
    if tcp.read_exact(&mut greeting).await.is_err() || greeting != [0x05, 0x00] {
        return fail("drop", 1, "SOCKS5 отклонил метод авторизации".to_string());
    }

    // UDP ASSOCIATE 0.0.0.0:0
    let req = [0x05, 0x03, 0x00, 0x01, 0, 0, 0, 0, 0, 0];
    if tcp.write_all(&req).await.is_err() {
        return fail("drop", 1, "Ошибка SOCKS5 UDP ASSOCIATE".to_string());
    }
    let mut hdr = [0u8; 4];
    if tcp.read_exact(&mut hdr).await.is_err() || hdr[1] != 0x00 {
        return fail(
            "drop",
            1,
            "SOCKS5 песочницы не поддерживает UDP".to_string(),
        );
    }
    let relay_addr: SocketAddr = match hdr[3] {
        0x01 => {
            let mut b = [0u8; 6];
            if tcp.read_exact(&mut b).await.is_err() {
                return fail("drop", 1, "Некорректный UDP relay ответ".to_string());
            }
            let ip = Ipv4Addr::new(b[0], b[1], b[2], b[3]);
            let relay_ip = if ip.is_unspecified() {
                Ipv4Addr::LOCALHOST
            } else {
                ip
            };
            SocketAddr::V4(SocketAddrV4::new(
                relay_ip,
                u16::from_be_bytes([b[4], b[5]]),
            ))
        }
        0x04 => {
            let mut b = [0u8; 18];
            if tcp.read_exact(&mut b).await.is_err() {
                return fail("drop", 1, "Некорректный UDP relay v6 ответ".to_string());
            }
            SocketAddr::V4(SocketAddrV4::new(
                Ipv4Addr::LOCALHOST,
                u16::from_be_bytes([b[16], b[17]]),
            ))
        }
        _ => {
            return fail(
                "drop",
                1,
                "Неподдерживаемый тип адреса UDP relay".to_string(),
            );
        }
    };

    let Ok(udp) = TokioUdpSocket::bind("127.0.0.1:0").await else {
        return fail(
            "drop",
            1,
            "Не удалось создать локальный UDP-сокет".to_string(),
        );
    };

    // Build SOCKS5 UDP packet + RFC 5389 STUN Binding Request
    let mut pkt = Vec::with_capacity(64);
    pkt.extend_from_slice(&[0x00, 0x00, 0x00]); // RSV=0, FRAG=0
    match dst_ip {
        Some(IpAddr::V4(v4)) => {
            pkt.push(0x01);
            pkt.extend_from_slice(&v4.octets());
        }
        Some(IpAddr::V6(v6)) => {
            pkt.push(0x04);
            pkt.extend_from_slice(&v6.octets());
        }
        None => {
            let hb = host.as_bytes();
            if hb.len() > 255 {
                return fail("dns_error", 6, "Слишком длинное имя UDP-узла".to_string());
            }
            pkt.push(0x03);
            pkt.push(hb.len() as u8);
            pkt.extend_from_slice(hb);
        }
    }
    pkt.extend_from_slice(&dst_port.to_be_bytes());

    let mut txid = [0u8; 12];
    rand::thread_rng().fill_bytes(&mut txid);
    pkt.extend_from_slice(&[0x00, 0x01, 0x00, 0x00, 0x21, 0x12, 0xa4, 0x42]);
    pkt.extend_from_slice(&txid);

    if udp.send_to(&pkt, relay_addr).await.is_err() {
        return fail(
            "drop",
            1,
            "Не удалось отправить UDP STUN запрос".to_string(),
        );
    }

    let mut buf = [0u8; 1024];
    match tokio::time::timeout(Duration::from_secs(3), udp.recv_from(&mut buf)).await {
        Ok(Ok((n, _))) if n >= 24 => {
            let rtt_ms = started.elapsed().as_millis().max(1) as u32;
            SingleProbeMetrics {
                target_name: ep.target_name.clone(),
                url: ep.url.clone(),
                success: true,
                http_code: 200,
                handshake_ms: rtt_ms,
                ttfb_ms: rtt_ms,
                speed_kbps: 0,
                data_bytes: n as u64,
                data_verified: false,
                dpi_verdict: "ok",
                exit_code: 0,
                error: String::new(),
            }
        }
        Ok(Ok(_)) => fail("drop", 1, "Неполный ответ UDP STUN".to_string()),
        Ok(Err(_)) | Err(_) => fail("timeout", 28, "Таймаут UDP STUN ответа (3с)".to_string()),
    }
}

async fn run_curl_cmd(
    ep: &ProbeEndpoint,
    proxy_url: &str,
    resolve_entry: Option<&str>,
    connect_timeout_secs: u64,
    max_time_secs: u64,
) -> SingleProbeMetrics {
    let cto_str = connect_timeout_secs.to_string();
    let mto_str = max_time_secs.to_string();
    let mut args: Vec<&str> = vec!["-s", "-L", "-k", "--http1.1", "-x", proxy_url];
    if let Some(res) = resolve_entry {
        args.push("--resolve");
        args.push(res);
    }
    args.extend_from_slice(&[
        "--connect-timeout",
        &cto_str,
        "--max-time",
        &mto_str,
        "-r",
        "0-65535",
        "-A",
        USER_AGENT,
        "-o",
        "/dev/null",
        "-w",
        "%{http_code}|%{time_connect}|%{time_appconnect}|%{time_starttransfer}|%{time_total}|%{speed_download}|%{size_download}",
        &ep.url,
    ]);

    let out = tokio::time::timeout(
        Duration::from_secs(max_time_secs + 2),
        Command::new("curl")
            .args(&args)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .output(),
    )
    .await;

    let Ok(Ok(res)) = out else {
        return SingleProbeMetrics {
            target_name: ep.target_name.clone(),
            url: ep.url.clone(),
            success: false,
            http_code: 0,
            handshake_ms: 0,
            ttfb_ms: 0,
            speed_kbps: 0,
            data_bytes: 0,
            data_verified: false,
            dpi_verdict: "timeout",
            exit_code: 28,
            error: format!("Таймаут соединения ({max_time_secs}с)"),
        };
    };

    let exit_code = res.status.code().unwrap_or(1);
    let stdout = String::from_utf8_lossy(&res.stdout);
    let parts: Vec<&str> = stdout.trim().split('|').collect();
    let parse_f64 = |idx: usize| -> f64 {
        parts
            .get(idx)
            .map(|s| s.replace(',', "."))
            .and_then(|s| s.parse::<f64>().ok())
            .unwrap_or(0.0)
    };

    let http_code: u16 = parts
        .first()
        .and_then(|s| s.trim().parse::<u16>().ok())
        .unwrap_or(0);
    let t_conn_ms = (parse_f64(1) * 1000.0).round() as u32;
    let t_tls_ms = (parse_f64(2) * 1000.0).round() as u32;
    let t_ttfb_ms = (parse_f64(3) * 1000.0).round() as u32;
    let t_total_ms = (parse_f64(4) * 1000.0).round() as u32;
    let speed_bps = parse_f64(5);
    let size_bytes = parse_f64(6).max(0.0) as u64;

    let handshake_ms = if t_tls_ms > 0 { t_tls_ms } else { t_conn_ms };
    let ttfb_ms = if t_ttfb_ms > 0 {
        t_ttfb_ms
    } else {
        handshake_ms.max(1)
    };
    let speed_kbps =
        ((speed_bps / 1024.0).round() as u32).max(if size_bytes > 0 && t_total_ms > 0 {
            ((size_bytes as f64 * 1000.0 / t_total_ms as f64) / 1024.0).round() as u32
        } else {
            0
        });

    if http_code == 400 {
        return SingleProbeMetrics {
            target_name: ep.target_name.clone(),
            url: ep.url.clone(),
            success: false,
            http_code,
            handshake_ms,
            ttfb_ms,
            speed_kbps,
            data_bytes: size_bytes,
            data_verified: false,
            dpi_verdict: "server_fakes",
            exit_code,
            error: "HTTP 400: маскировочный пакет достиг целевого сервера (уменьшите TTL)"
                .to_string(),
        };
    }

    let code_ok = (200..400).contains(&http_code)
        || (ep.allow_api_status && matches!(http_code, 401 | 403 | 404 | 405 | 429));

    // Exit code 18 = partial file (normal when range / stream closes early after >32KB)
    let transfer_ok = exit_code == 0 || (exit_code == 18 && size_bytes >= 16_384);
    let throttled_16k =
        code_ok && !ep.allow_api_status && exit_code == 28 && (8_192..24_576).contains(&size_bytes);

    let success = code_ok && transfer_ok && !throttled_16k;
    let data_verified = success && size_bytes >= 32_768;

    let (dpi_verdict, error) = if success {
        ("ok", String::new())
    } else if throttled_16k {
        (
            "throttled_16k",
            "Обрыв потока после ~16 КБ (ограничение окна передачи)".to_string(),
        )
    } else {
        match exit_code {
            6 => (
                "dns_error",
                "Ошибка разрешения DNS через песочницу".to_string(),
            ),
            7 => ("conn_refused", "Отказ TCP-соединения".to_string()),
            28 => (
                "timeout",
                if t_conn_ms == 0 {
                    "Таймаут TCP SYN (нет ответа от узла)".to_string()
                } else {
                    "Таймаут TLS ClientHello / чтения ответа".to_string()
                },
            ),
            35 | 56 => (
                "rst",
                "Сброс сессии (TCP RST / обрыв TLS-рукопожатия)".to_string(),
            ),
            _ => (
                "drop",
                if http_code > 0 {
                    format!("HTTP {http_code} (код выхода curl {exit_code})")
                } else {
                    format!("Сессия прервана (код curl {exit_code})")
                },
            ),
        }
    };

    SingleProbeMetrics {
        target_name: ep.target_name.clone(),
        url: ep.url.clone(),
        success,
        http_code,
        handshake_ms,
        ttfb_ms,
        speed_kbps,
        data_bytes: size_bytes,
        data_verified,
        dpi_verdict,
        exit_code,
        error,
    }
}

async fn run_curl_via_socks(
    port: u16,
    ep: &ProbeEndpoint,
    dns_cache: &HashMap<(String, u16), IpAddr>,
    total_endpoints: usize,
) -> SingleProbeMetrics {
    if ep.probe_kind == "udp_stun" {
        return run_udp_stun_via_socks(port, ep, dns_cache).await;
    }

    let (cto, mto) = if total_endpoints >= 3 { (3, 4) } else { (3, 5) };
    let socks_local = format!("socks5://127.0.0.1:{port}");
    let socks_remote = format!("socks5h://127.0.0.1:{port}");

    if let Some((host, dst_port)) = extract_host_port(&ep.url)
        && host.parse::<IpAddr>().is_err()
        && let Some(ip) = dns_cache.get(&(host.clone(), dst_port))
    {
        let resolve_entry = format!("{host}:{dst_port}:{ip}");
        let primary = run_curl_cmd(ep, &socks_local, Some(&resolve_entry), cto, mto).await;
        if primary.success || !matches!(primary.exit_code, 6 | 7 | 28) {
            return primary;
        }
    }

    run_curl_cmd(ep, &socks_remote, None, cto, mto).await
}

async fn probe_outbound_in_sandbox(
    bin_path: &str,
    outbound_obj: Value,
    endpoints: &[ProbeEndpoint],
    dns_cache: &HashMap<(String, u16), IpAddr>,
    is_custom: bool,
) -> Vec<SingleProbeMetrics> {
    let port = pick_sandbox_port();
    let cfg_path = format!("/var/run/tachyon/fuzzer_sandbox_{port}.json");
    let sandbox_cfg = json!({
        "log": { "level": "error" },
        "dns": {
            "servers": [
                {
                    "tag": "dns-direct",
                    "address": "https://1.1.1.1/dns-query",
                    "detour": "direct-wan"
                },
                {
                    "tag": "dns-fallback",
                    "address": "8.8.8.8",
                    "detour": "direct-wan"
                }
            ],
            "final": "dns-direct"
        },
        "inbounds": [
            {
                "type": "mixed",
                "tag": "fuzzer-in",
                "listen": "127.0.0.1",
                "listen_port": port
            }
        ],
        "outbounds": [
            outbound_obj,
            {
                "type": "direct",
                "tag": "direct-wan",
                "routing_mark": SANDBOX_ROUTING_MARK
            }
        ],
        "route": {
            "final": "fuzzer-out"
        }
    });

    let _ = std::fs::create_dir_all("/var/run/tachyon");
    if let Ok(raw) = serde_json::to_string(&sandbox_cfg) {
        let _ = std::fs::write(&cfg_path, raw.as_bytes());
    }

    let child_res = Command::new(bin_path)
        .args(["run", "-c", &cfg_path])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .spawn();

    let Ok(mut child) = child_res else {
        let _ = std::fs::remove_file(&cfg_path);
        return endpoints
            .iter()
            .map(|ep| SingleProbeMetrics {
                target_name: ep.target_name.clone(),
                url: ep.url.clone(),
                success: false,
                http_code: 0,
                handshake_ms: 0,
                ttfb_ms: 0,
                speed_kbps: 0,
                data_bytes: 0,
                data_verified: false,
                dpi_verdict: "spawn_error",
                exit_code: 127,
                error: format!("Не удалось запустить песочницу {bin_path}"),
            })
            .collect();
    };

    let pid = child.id().unwrap_or(0);
    FUZZER_ACTIVE_PID.store(pid, Ordering::Relaxed);

    let mut metrics = Vec::with_capacity(endpoints.len());
    if wait_local_port_ready(port, 750).await {
        let mut passed_so_far = 0usize;
        for ep in endpoints {
            if FUZZER_ABORT.load(Ordering::Relaxed) {
                break;
            }
            let m = run_curl_via_socks(port, ep, dns_cache, endpoints.len()).await;
            if m.success {
                passed_so_far += 1;
            }
            let failed = !m.success;
            metrics.push(m);
            if !is_custom && failed && passed_so_far == 0 && endpoints.len() > 6 {
                break;
            }
        }
    } else {
        for ep in endpoints {
            metrics.push(SingleProbeMetrics {
                target_name: ep.target_name.clone(),
                url: ep.url.clone(),
                success: false,
                http_code: 0,
                handshake_ms: 0,
                ttfb_ms: 0,
                speed_kbps: 0,
                data_bytes: 0,
                data_verified: false,
                dpi_verdict: "sandbox_timeout",
                exit_code: 1,
                error: "Песочница tachyon-core не открыла локальный порт вовремя".to_string(),
            });
        }
    }

    FUZZER_ACTIVE_PID.store(0, Ordering::Relaxed);
    let _ = child.kill().await;
    let _ = child.wait().await;
    let _ = std::fs::remove_file(&cfg_path);
    metrics
}

pub async fn detect_wan_filtering(bin_path: &str, target: &str, custom_url: &str) -> Value {
    let t_lc = target.trim().to_ascii_lowercase();
    if matches!(t_lc.as_str(), "all" | "global" | "default") {
        return json!({
            "success": false,
            "error": "Цели 'all'/'global'/'default' отключены; выберите конкретный сервис или список доменов"
        });
    }
    if (!custom_url.trim().is_empty() || t_lc == "custom")
        && let Err(err) = validate_custom_targets_input(custom_url)
    {
        return json!({ "success": false, "error": err });
    }
    if !is_desync_engine_installed(bin_path) {
        return json!({
            "success": false,
            "error": "Бинарный файл tachyon-core не установлен на маршрутизаторе"
        });
    }

    let endpoints = resolve_suite_endpoints(target, custom_url);
    let dns_cache = prewarm_dns_cache(&endpoints).await;
    detect_wan_filtering_with_cache(bin_path, target, &endpoints, &dns_cache).await
}

async fn detect_wan_filtering_with_cache(
    bin_path: &str,
    target: &str,
    endpoints: &[ProbeEndpoint],
    dns_cache: &HashMap<(String, u16), IpAddr>,
) -> Value {
    let primary = endpoints.first().cloned().unwrap_or(ProbeEndpoint {
        url: "https://www.youtube.com".to_string(),
        target_name: "www.youtube.com".to_string(),
        probe_kind: "tls_http".to_string(),
        allow_api_status: false,
    });
    let direct_outbound = json!({
        "type": "direct",
        "tag": "fuzzer-out",
        "routing_mark": SANDBOX_ROUTING_MARK
    });
    let probes = probe_outbound_in_sandbox(
        bin_path,
        direct_outbound,
        std::slice::from_ref(&primary),
        dns_cache,
        false,
    )
    .await;
    let p = probes.first();

    let (dtype, conf, details) = match p {
        Some(m) if m.success => (
            "none",
            92,
            "Прямое WAN-соединение проходит штатно без десинхронизации.",
        ),
        Some(m) if m.dpi_verdict == "rst" => (
            "rst",
            90,
            "Обнаружен активный сброс TCP RST при отправке TLS ClientHello на прямом канале.",
        ),
        Some(m) if m.dpi_verdict == "throttled_16k" => (
            "throttle",
            88,
            "Обнаружено ограничение потока данных после передачи первых ~16 КБ.",
        ),
        Some(m) if m.exit_code == 28 && m.handshake_ms == 0 => (
            "ip_block",
            82,
            "Отсутствует ответ на TCP SYN на прямом маршруте — вероятна фильтрация по IP-адресу.",
        ),
        Some(m) if m.exit_code == 6 => ("dns_block", 85, "Не удалось разрешить доменное имя цели."),
        _ => (
            "throttle",
            78,
            "Таймаут TLS-рукопожатия на прямом WAN-маршруте; требуется сегментация пакетов.",
        ),
    };

    json!({
        "success": true,
        "target": target,
        "url": primary.url,
        "type": dtype,
        "dpi_type": dtype,
        "confidence": conf,
        "details": details,
        "description": details,
        "recommended_engines": ["desync"],
        "recommended_modes": ["presets", "deep"]
    })
}

fn score_strategy_metrics(
    sub: &[SingleProbeMetrics],
    total_endpoints: usize,
) -> (
    bool,
    u16,
    u32,
    u32,
    u32,
    u64,
    bool,
    &'static str,
    i32,
    String,
) {
    if sub.is_empty() {
        return (
            false,
            0,
            0,
            0,
            0,
            0,
            false,
            "drop",
            1,
            "Нет данных проверки".into(),
        );
    }
    let passed = sub.iter().filter(|m| m.success).count();
    let all_ok = passed == total_endpoints && passed > 0;
    let first = &sub[0];
    if !all_ok {
        let failed = sub.iter().find(|m| !m.success).unwrap_or(first);
        return (
            false,
            failed.http_code,
            failed.handshake_ms,
            failed.ttfb_ms,
            failed.speed_kbps,
            failed.data_bytes,
            false,
            failed.dpi_verdict,
            failed.exit_code,
            failed.error.clone(),
        );
    }

    let avg_hs = (sub.iter().map(|m| m.handshake_ms as u64).sum::<u64>() / passed as u64) as u32;
    let avg_ttfb = (sub.iter().map(|m| m.ttfb_ms as u64).sum::<u64>() / passed as u64) as u32;
    let avg_spd = (sub.iter().map(|m| m.speed_kbps as u64).sum::<u64>() / passed as u64) as u32;
    let total_bytes = sub.iter().map(|m| m.data_bytes).sum::<u64>();
    let verified_32k = sub.iter().any(|m| m.data_verified);

    // Engineering composite score: rewards fast TTFB, verified >=32KB payload transfer, and throughput
    let latency_pts = 500i64 - (avg_ttfb as i64 / 3).min(380);
    let speed_pts = (avg_spd as i64 / 20).min(350);
    let stream_bonus = if verified_32k { 150 } else { 40 };
    let suite_bonus = (passed as i64 - 1) * 60;
    let total_score = (latency_pts + speed_pts + stream_bonus + suite_bonus).max(50) as i32;

    (
        true,
        first.http_code,
        avg_hs,
        avg_ttfb,
        avg_spd,
        total_bytes,
        verified_32k,
        "ok",
        total_score,
        String::new(),
    )
}

fn rank_and_badge_results(results: &mut [Value]) -> Option<Value> {
    results.sort_by(|a, b| {
        let sa = a.get("success").and_then(Value::as_bool).unwrap_or(false);
        let sb = b.get("success").and_then(Value::as_bool).unwrap_or(false);
        let sca = a.get("score").and_then(Value::as_i64).unwrap_or(0);
        let scb = b.get("score").and_then(Value::as_i64).unwrap_or(0);
        sb.cmp(&sa).then_with(|| scb.cmp(&sca))
    });

    let mut best: Option<Value> = None;
    for (idx, item) in results.iter_mut().enumerate() {
        let ok = item
            .get("success")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        if let Some(obj) = item.as_object_mut() {
            if ok && idx == 0 {
                obj.insert("badge".into(), json!("Лучшее совпадение"));
                best = Some(Value::Object(obj.clone()));
            } else if ok && idx == 1 {
                obj.insert("badge".into(), json!("Резерв #2"));
            } else {
                obj.remove("badge");
            }
        }
    }
    best
}

fn append_history_entry(entry: Value) {
    let mut entries: Vec<Value> = std::fs::read_to_string(HISTORY_FILE)
        .ok()
        .and_then(|raw| serde_json::from_str::<Value>(&raw).ok())
        .and_then(|v| v.get("entries").and_then(Value::as_array).cloned())
        .unwrap_or_default();
    entries.insert(0, entry);
    entries.truncate(30);

    let mut best_by_key = Map::new();
    for e in &entries {
        let eng = e.get("engine").and_then(Value::as_str).unwrap_or("desync");
        let tgt = e
            .get("target")
            .and_then(Value::as_str)
            .unwrap_or("youtube_suite");
        let key = format!("{eng}:{tgt}");
        if !best_by_key.contains_key(&key) && e.get("best_strategy").is_some_and(|b| !b.is_null()) {
            best_by_key.insert(key, e.clone());
        }
    }

    let payload = json!({
        "success": true,
        "entries": entries,
        "best_by_key": best_by_key
    });
    if cfg!(target_os = "linux") {
        let _ = std::fs::create_dir_all("/var/run/tachyon/ui-state");
        if let Ok(raw) = serde_json::to_string(&payload) {
            let _ = crypto_gen::write_file_if_changed(Path::new(HISTORY_FILE), raw.as_bytes());
        }
    }
}

pub fn get_history() -> Value {
    if let Ok(raw) = std::fs::read_to_string(HISTORY_FILE)
        && let Ok(val) = serde_json::from_str::<Value>(&raw)
        && val.get("entries").is_some()
    {
        return val;
    }
    json!({
        "success": true,
        "entries": [],
        "best_by_key": {}
    })
}

pub fn clear_history() -> Value {
    let _ = std::fs::remove_file(HISTORY_FILE);
    json!({ "success": true })
}

pub fn stop() -> Value {
    FUZZER_ABORT.store(true, Ordering::SeqCst);
    let pid = FUZZER_ACTIVE_PID.swap(0, Ordering::SeqCst);
    if pid > 1 && cfg!(target_os = "linux") {
        let _ = std::process::Command::new("kill")
            .args(["-9", &pid.to_string()])
            .status();
    }
    let mut cur = get_status();
    if let Some(obj) = cur.as_object_mut() {
        obj.insert("running".into(), json!(false));
        obj.insert("aborted".into(), json!(true));
        obj.insert("finished_at".into(), json!(unix_now_secs()));
        obj.insert("error".into(), json!("Остановлено пользователем"));
    }
    save_state(&cur);
    json!({ "success": true, "running": false })
}

pub fn synthesize_ai_strategies(target: &str, user_prompt: &str) -> Value {
    let prompt_lc = user_prompt.to_lowercase();
    let want_udp = target.contains("discord")
        || target.contains("cs2")
        || target.contains("gaming")
        || target.contains("quic")
        || prompt_lc.contains("udp")
        || prompt_lc.contains("голос")
        || prompt_lc.contains("discord");

    let mut strategies = vec![
        json!({
            "id": "ai_ds_hostfakesplit",
            "name": "AI HostFakeSplit + MD5/BadACK (seqovl=4)",
            "engine": "desync",
            "args": "mode=fake_disorder split_pos=sni,endhost-1 fooling=md5_badack fake_sni=rzd.ru seqovl=4 repeats=2",
            "description": "Двухточечная сегментация границ SNI с перекрытием последовательности"
        }),
        json!({
            "id": "ai_ds_midsld_autottl",
            "name": "AI AutoTTL Disorder @ MidSLD",
            "engine": "desync",
            "args": "mode=fake_disorder split_pos=midsld fooling=autottl fake_sni=ozon.ru repeats=3 split_delay_ms=2",
            "description": "Адаптивный расчёт дистанции хопов с разрезом посередине SLD"
        }),
        json!({
            "id": "ai_ds_tlsrec_wsize",
            "name": "AI TLS Record Split + Window Clamp",
            "engine": "desync",
            "args": "mode=tlsrec split_pos=sni tlsrec_first=true split_delay_ms=1",
            "description": "Чистая фрагментация TLS-записей без инжекции ложных сегментов"
        }),
    ];

    if want_udp {
        strategies.insert(
            0,
            json!({
                "id": "ai_ds_hybrid_udp",
                "name": "AI Hybrid TLS + UDP Burst (Voice/Gaming)",
                "engine": "desync",
                "args": "mode=fake_split split_pos=midsld fooling=autottl fake_sni=cloudflare.com repeats=2 udp_fake=true udp_repeats=6 udp_fake_ttl=6 udplen=64",
                "description": "Комбинированная десинхронизация TLS и стартовых UDP-пакетов"
            }),
        );
    }

    if cfg!(target_os = "linux") {
        let _ = std::fs::create_dir_all("/var/run/tachyon");
        if let Ok(raw) = serde_json::to_string(&strategies) {
            let _ = std::fs::write(AI_STRATEGIES_FILE, raw.as_bytes());
        }
    }

    json!({
        "success": true,
        "async": false,
        "running": false,
        "engine": "desync",
        "target": target,
        "count": strategies.len(),
        "custom_file": AI_STRATEGIES_FILE,
        "analysis": "Синтезирован набор профилей нативного движка десинхронизации tachyon-core с учётом целевых протоколов (TLS SNI / MidSLD + UDP).",
        "strategies": strategies
    })
}

#[allow(clippy::too_many_arguments)]
pub fn start_benchmark(
    bin_path: String,
    requested_engine: &str,
    target: &str,
    custom_url: &str,
    rule_section: &str,
    custom_file: &str,
    mode: &str,
    timeout_secs: u64,
) -> Value {
    if let Err(err) = validate_engine_request(requested_engine, &bin_path) {
        return json!({
            "success": false,
            "error": err
        });
    }

    let target_trimmed = target.trim();
    let target_lc = target_trimmed.to_ascii_lowercase();
    if matches!(target_lc.as_str(), "all" | "global" | "default") {
        return json!({
            "success": false,
            "error": "Цели 'all'/'global'/'default' отключены; выберите конкретный сервис или список доменов"
        });
    }

    let rule_trimmed = rule_section.trim();
    if matches!(
        rule_trimmed.to_ascii_lowercase().as_str(),
        "global" | "default"
    ) {
        return json!({
            "success": false,
            "error": "Целевые правила 'global'/'default' отключены; выберите конкретную секцию или источник"
        });
    }

    let is_custom = !custom_url.trim().is_empty() || target_lc == "custom";
    let custom_url_owned = if is_custom {
        match validate_custom_targets_input(custom_url) {
            Ok(urls) => urls.join("\n"),
            Err(err) => {
                return json!({
                    "success": false,
                    "error": err
                });
            }
        }
    } else {
        String::new()
    };

    // Stop any previous run first
    FUZZER_ABORT.store(true, Ordering::SeqCst);
    let prev_pid = FUZZER_ACTIVE_PID.swap(0, Ordering::SeqCst);
    if prev_pid > 1 && cfg!(target_os = "linux") {
        let _ = std::process::Command::new("kill")
            .args(["-9", &prev_pid.to_string()])
            .status();
    }

    let patterns = get_patterns()
        .get("patterns")
        .cloned()
        .unwrap_or_else(default_patterns_config);

    let mode_norm = if mode.trim().is_empty() {
        "presets"
    } else {
        mode.trim()
    };

    let mut candidates: Vec<StrategySpec> = match mode_norm {
        "ai_custom" if !custom_file.trim().is_empty() => {
            std::fs::read_to_string(custom_file.trim())
                .ok()
                .and_then(|raw| serde_json::from_str::<Vec<Value>>(&raw).ok())
                .map(|arr| {
                    arr.iter()
                        .enumerate()
                        .filter_map(|(i, v)| {
                            let args = v.get("args").and_then(Value::as_str)?;
                            Some(StrategySpec {
                                id: v
                                    .get("id")
                                    .and_then(Value::as_str)
                                    .map(String::from)
                                    .unwrap_or_else(|| format!("ai_ds_{}", i + 1)),
                                name: v
                                    .get("name")
                                    .and_then(Value::as_str)
                                    .unwrap_or("AI Desync Profile")
                                    .to_string(),
                                args: args.to_string(),
                                description: v
                                    .get("description")
                                    .and_then(Value::as_str)
                                    .unwrap_or("")
                                    .to_string(),
                                source: "ai".to_string(),
                            })
                        })
                        .collect()
                })
                .unwrap_or_else(builtin_desync_strategies)
        }
        "custom_only" => {
            let c = load_custom_strategies(&patterns);
            if c.is_empty() {
                builtin_desync_strategies()
            } else {
                c
            }
        }
        "deep" | "combinatorial" => {
            let mut list = builtin_desync_strategies();
            list.extend(load_custom_strategies(&patterns));
            list.extend(generate_combinatorial_strategies(&patterns, 28));
            list
        }
        _ => {
            let mut list = builtin_desync_strategies();
            list.extend(load_custom_strategies(&patterns));
            list
        }
    };

    if candidates.is_empty() {
        candidates = builtin_desync_strategies();
    }

    let target_owned = if target_trimmed.is_empty() {
        if is_custom {
            "custom".to_string()
        } else {
            "youtube_suite".to_string()
        }
    } else {
        target_trimmed.to_string()
    };

    candidates = filter_strategies_for_target(candidates, &target_owned, &custom_url_owned);
    if candidates.is_empty() {
        candidates = filter_strategies_for_target(
            builtin_desync_strategies(),
            &target_owned,
            &custom_url_owned,
        );
    }

    let endpoints = resolve_suite_endpoints(&target_owned, &custom_url_owned);
    if endpoints.is_empty() {
        return json!({
            "success": false,
            "error": "Не найдено ни одного корректного адреса для проверки"
        });
    }
    let endpoint_labels: Vec<Value> = endpoints
        .iter()
        .map(|e| {
            json!({
                "target_name": e.target_name,
                "url": e.url,
                "probe_kind": e.probe_kind
            })
        })
        .collect();

    let now = unix_now_secs();
    let seq = FUZZER_JOB_SEQ.fetch_add(1, Ordering::Relaxed);
    let job_id = format!("fuzzer-{now}-{seq}");
    let total = candidates.len();
    let rule_owned = rule_trimmed.to_string();
    let mode_owned = mode_norm.to_string();
    let max_duration = Duration::from_secs(timeout_secs.clamp(30, 7200));

    FUZZER_ABORT.store(false, Ordering::SeqCst);

    let initial_state = json!({
        "success": true,
        "job_id": job_id,
        "running": true,
        "completed": false,
        "aborted": false,
        "engine": "desync",
        "target": target_owned,
        "url": endpoints.first().map(|e| e.url.as_str()).unwrap_or("https://www.youtube.com"),
        "endpoints": endpoint_labels,
        "rule_section": rule_owned,
        "mode": mode_owned,
        "phase": "detecting_dpi",
        "stage": 1,
        "started_at": now,
        "finished_at": 0,
        "total_strategies": total,
        "current_index": 0,
        "current_strategy": null,
        "progress_pct": 2,
        "best_strategy": null,
        "dpi_detection": null,
        "results": []
    });
    save_state(&initial_state);

    let job_id_ret = job_id.clone();
    let target_ret = target_owned.clone();
    let total_endpoints_ret = endpoints.len();
    let endpoint_names_ret: Vec<String> = endpoints.iter().map(|e| e.target_name.clone()).collect();
    tokio::spawn(async move {
        let started_instant = Instant::now();
        let dns_cache = prewarm_dns_cache(&endpoints).await;
        let dpi_det =
            detect_wan_filtering_with_cache(&bin_path, &target_owned, &endpoints, &dns_cache).await;

        let mut results: Vec<Value> = Vec::with_capacity(total);
        let mut best: Option<Value> = None;

        for (idx, strat) in candidates.iter().enumerate() {
            if FUZZER_ABORT.load(Ordering::Relaxed) || started_instant.elapsed() >= max_duration {
                break;
            }

            let pct = 5 + ((idx * 80) / total.max(1));
            let in_progress = json!({
                "success": true,
                "job_id": job_id,
                "running": true,
                "completed": false,
                "aborted": false,
                "engine": "desync",
                "target": target_owned,
                "url": endpoints.first().map(|e| e.url.as_str()).unwrap_or("https://www.youtube.com"),
                "endpoints": endpoint_labels,
                "rule_section": rule_owned,
                "mode": mode_owned,
                "phase": "exploration",
                "stage": 1,
                "started_at": now,
                "finished_at": 0,
                "total_strategies": total,
                "current_index": idx + 1,
                "current_strategy": {
                    "id": strat.id,
                    "name": strat.name,
                    "engine": "desync",
                    "args": strat.args,
                    "description": strat.description
                },
                "progress_pct": pct,
                "best_strategy": best,
                "dpi_detection": dpi_det,
                "results": results
            });
            save_state(&in_progress);

            let outbound = parse_desync_args_to_outbound(&strat.args, "fuzzer-out", true);
            let sub =
                probe_outbound_in_sandbox(&bin_path, outbound, &endpoints, &dns_cache, is_custom)
                    .await;
            if FUZZER_ABORT.load(Ordering::Relaxed) {
                break;
            }

            let (
                ok,
                http_code,
                handshake_ms,
                ttfb_ms,
                speed_kbps,
                data_bytes,
                data_verified,
                verdict,
                score,
                err_msg,
            ) = score_strategy_metrics(&sub, endpoints.len());

            let passed_endpoints = sub.iter().filter(|m| m.success).count();
            let sub_json: Vec<Value> = sub
                .iter()
                .map(|m| {
                    json!({
                        "target_name": m.target_name,
                        "url": m.url,
                        "success": m.success,
                        "http_code": m.http_code,
                        "handshake_ms": m.handshake_ms,
                        "ttfb_ms": m.ttfb_ms,
                        "speed_kbps": m.speed_kbps,
                        "data_bytes": m.data_bytes,
                        "error": m.error
                    })
                })
                .collect();

            results.push(json!({
                "id": strat.id,
                "index": idx + 1,
                "name": strat.name,
                "engine": "desync",
                "args": strat.args,
                "description": strat.description,
                "source": strat.source,
                "success": ok,
                "http_code": http_code,
                "time_ms": ttfb_ms,
                "handshake_ms": handshake_ms,
                "ttfb_ms": ttfb_ms,
                "speed_kbps": speed_kbps,
                "data_bytes": data_bytes,
                "data_verified": data_verified,
                "dpi_verdict": verdict,
                "score": if ok { score } else { 0 },
                "error": err_msg,
                "passed_endpoints": passed_endpoints,
                "total_endpoints": endpoints.len(),
                "endpoints": endpoints.iter().map(|e| e.target_name.as_str()).collect::<Vec<_>>(),
                "sub_probes": sub_json
            }));

            best = rank_and_badge_results(&mut results);
        }

        // Stage 2: Stability verification on top 3 working candidates
        let top_ids: Vec<(String, String)> = results
            .iter()
            .filter(|r| r.get("success").and_then(Value::as_bool) == Some(true))
            .take(3)
            .filter_map(|r| {
                Some((
                    r.get("id")?.as_str()?.to_string(),
                    r.get("args")?.as_str()?.to_string(),
                ))
            })
            .collect();

        if !top_ids.is_empty() && !FUZZER_ABORT.load(Ordering::Relaxed) {
            for (v_idx, (sid, sargs)) in top_ids.iter().enumerate() {
                if FUZZER_ABORT.load(Ordering::Relaxed) || started_instant.elapsed() >= max_duration
                {
                    break;
                }
                let v_pct = 88 + (((v_idx + 1) * 10) / top_ids.len().max(1));
                let verifying_state = json!({
                    "success": true,
                    "job_id": job_id,
                    "running": true,
                    "completed": false,
                    "aborted": false,
                    "engine": "desync",
                    "target": target_owned,
                    "url": endpoints.first().map(|e| e.url.as_str()).unwrap_or("https://www.youtube.com"),
                    "endpoints": endpoint_labels,
                    "rule_section": rule_owned,
                    "mode": mode_owned,
                    "phase": "verification",
                    "stage": 2,
                    "started_at": now,
                    "finished_at": 0,
                    "total_strategies": total,
                    "current_index": total,
                    "current_strategy": null,
                    "progress_pct": v_pct.min(98),
                    "best_strategy": best,
                    "dpi_detection": dpi_det,
                    "results": results
                });
                save_state(&verifying_state);

                let primary_slice = &endpoints[..1];
                let mut ok_runs = 1u32; // Stage 1 already succeeded
                let mut ttfbs = Vec::with_capacity(3);
                if let Some(orig) = results
                    .iter()
                    .find(|r| r.get("id").and_then(Value::as_str) == Some(sid))
                    && let Some(t) = orig.get("ttfb_ms").and_then(Value::as_u64)
                {
                    ttfbs.push(t as u32);
                }

                for _ in 0..2 {
                    if FUZZER_ABORT.load(Ordering::Relaxed) {
                        break;
                    }
                    let outb = parse_desync_args_to_outbound(sargs, "fuzzer-out", true);
                    let m = probe_outbound_in_sandbox(
                        &bin_path,
                        outb,
                        primary_slice,
                        &dns_cache,
                        false,
                    )
                    .await;
                    if let Some(first_m) = m.first()
                        && first_m.success
                    {
                        ok_runs += 1;
                        ttfbs.push(first_m.ttfb_ms);
                    }
                }

                let stability_pct = ((ok_runs * 100) / 3).min(100);
                let jitter_ms = if ttfbs.len() >= 2 {
                    let min_t = *ttfbs.iter().min().unwrap_or(&0);
                    let max_t = *ttfbs.iter().max().unwrap_or(&0);
                    (max_t - min_t) / 2
                } else {
                    0
                };
                let confidence = if stability_pct == 100 {
                    "high"
                } else if stability_pct >= 66 {
                    "medium"
                } else {
                    "low"
                };

                if let Some(entry) = results
                    .iter_mut()
                    .find(|r| r.get("id").and_then(Value::as_str) == Some(sid))
                    && let Some(obj) = entry.as_object_mut()
                {
                    let base_score = obj.get("score").and_then(Value::as_i64).unwrap_or(100);
                    let bonus = if stability_pct == 100 {
                        80
                    } else if stability_pct >= 66 {
                        20
                    } else {
                        -80
                    };
                    obj.insert("verified".into(), json!(true));
                    obj.insert("stability_pct".into(), json!(stability_pct));
                    obj.insert("jitter_ms".into(), json!(jitter_ms));
                    obj.insert("confidence".into(), json!(confidence));
                    obj.insert("score".into(), json!((base_score + bonus).max(10)));
                }
                best = rank_and_badge_results(&mut results);
            }
        }

        let aborted = FUZZER_ABORT.load(Ordering::Relaxed);
        let finished_at = unix_now_secs();
        let working_count = results
            .iter()
            .filter(|r| r.get("success").and_then(Value::as_bool) == Some(true))
            .count();

        let final_state = json!({
            "success": true,
            "job_id": job_id,
            "running": false,
            "completed": !aborted,
            "aborted": aborted,
            "engine": "desync",
            "target": target_owned,
            "url": endpoints.first().map(|e| e.url.as_str()).unwrap_or("https://www.youtube.com"),
            "endpoints": endpoint_labels,
            "rule_section": rule_owned,
            "mode": mode_owned,
            "phase": "completed",
            "stage": 2,
            "started_at": now,
            "finished_at": finished_at,
            "total_strategies": total,
            "current_index": results.len(),
            "current_strategy": null,
            "progress_pct": if aborted { 99 } else { 100 },
            "best_strategy": best,
            "dpi_detection": dpi_det,
            "error": if aborted { Value::String("Остановлено пользователем".into()) } else { Value::Null },
            "results": results
        });
        save_state(&final_state);

        append_history_entry(json!({
            "timestamp": finished_at,
            "engine": "desync",
            "target": target_owned,
            "url": endpoints.first().map(|e| e.url.as_str()).unwrap_or("https://www.youtube.com"),
            "mode": mode_owned,
            "total_tested": results.len(),
            "working_count": working_count,
            "best_strategy": best
        }));
    });

    json!({
        "success": true,
        "running": true,
        "job_id": job_id_ret,
        "engine": "desync",
        "target": target_ret,
        "total_strategies": total,
        "total_endpoints": total_endpoints_ret,
        "endpoints": endpoint_names_ret,
        "message": "Песочница подбора стратегий tachyon-core запущена"
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn create_temp_bin(name: &str) -> std::path::PathBuf {
        let p = std::env::temp_dir().join(format!("tachyon_test_{name}_{}", std::process::id()));
        let _ = std::fs::write(&p, b"#!/bin/sh\nexit 0\n");
        p
    }

    #[test]
    fn parses_desync_args_to_tachyon_core_outbound() {
        let out = parse_desync_args_to_outbound(
            "mode=hostfakesplit split_pos=sni,endhost-1 fooling=md5_badack fake_ttl=96 fake_sni=rzd.ru sni_pool=www.google.com,ozon.ru fake_payload=tls fake_tls=max wscale=4 seqovl=4 repeats=2 auto_tune=true udp_fake=true udp_repeats=6",
            "desync-test",
            true,
        );
        assert_eq!(out["type"], "desync");
        assert_eq!(out["tag"], "desync-test");
        assert_eq!(out["mode"], "hostfakesplit");
        assert_eq!(out["host_fake"], true);
        assert_eq!(out["split_pos"], json!(["sni", "endhost-1"]));
        assert_eq!(out["fooling"], "md5_badack");
        assert_eq!(out["fake_ttl"], 96);
        assert_eq!(out["fake_sni"], "rzd.ru");
        assert_eq!(out["sni_pool"], json!(["www.google.com", "ozon.ru"]));
        assert_eq!(out["fake_payload"], "tls");
        assert_eq!(out["fake_tls"], "max");
        assert_eq!(out["wscale"], 4);
        assert_eq!(out["seqovl"], 4);
        assert_eq!(out["repeats"], 2);
        assert_eq!(out["auto_tune"], true);
        assert_eq!(out["udp_fake"], true);
        assert_eq!(out["udp_repeats"], 6);
        assert_eq!(out["routing_mark"], SANDBOX_ROUTING_MARK);
    }

    #[test]
    fn applies_desync_args_to_uci_section_map() {
        let mut sec = Map::new();
        apply_desync_args_to_section_map(
            &mut sec,
            "mode=hostfakesplit split_pos=midsld fooling=autottl fake_ttl=90 fake_sni=ozon.ru sni_pool=ya.ru,rzd.ru fake_payload=http fake_tls=google scale=6 repeats=3 auto_tune=1",
        );
        assert_eq!(sec["desync_preset"], "custom");
        assert_eq!(sec["desync_mode"], "hostfakesplit");
        assert_eq!(sec["desync_host_fake"], "1");
        assert_eq!(sec["desync_split_pos"], "midsld");
        assert_eq!(sec["desync_fooling"], "autottl");
        assert_eq!(sec["desync_fake_ttl"], "90");
        assert_eq!(sec["desync_fake_sni"], "ozon.ru");
        assert_eq!(sec["desync_sni_pool"], "ya.ru,rzd.ru");
        assert_eq!(sec["desync_fake_payload"], "http");
        assert_eq!(sec["desync_fake_tls"], "google");
        assert_eq!(sec["desync_wscale"], "6");
        assert_eq!(sec["desync_repeats"], "3");
        assert_eq!(sec["desync_auto_tune"], "1");
    }

    #[test]
    fn normalizes_and_validates_custom_multi_domain_targets() {
        assert_eq!(
            normalize_target_url("youtube.com"),
            Some("https://youtube.com".to_string())
        );
        assert_eq!(
            normalize_target_url("example.org:8443/probe"),
            Some("https://example.org:8443/probe".to_string())
        );
        assert_eq!(
            normalize_target_url("udp://stun.l.google.com:19302"),
            Some("udp://stun.l.google.com:19302".to_string())
        );
        assert_eq!(normalize_target_url("evil.com;id"), None);

        let list = validate_custom_targets_input(
            "youtube.com, discord.com\nexample.org:8443/path; youtube.com udp://stun.l.google.com:19302",
        )
        .expect("valid custom list");
        assert_eq!(
            list,
            vec![
                "https://youtube.com",
                "https://discord.com",
                "https://example.org:8443/path",
                "udp://stun.l.google.com:19302",
            ]
        );
        assert!(validate_custom_targets_input("youtube.com\nevil.com;id").is_err());

        let many = (1..=8)
            .map(|i| format!("host{i}.example.com"))
            .collect::<Vec<_>>()
            .join("\n");
        let resolved = resolve_suite_endpoints("custom", &many);
        assert_eq!(resolved.len(), 8);
        assert_eq!(resolved[0].target_name, "host1.example.com");
    }

    #[test]
    fn rejects_all_and_uninstalled_engines_and_caps_state() {
        let bin = create_temp_bin("fuzzer_bin");
        let bin_str = bin.to_string_lossy().to_string();

        let bad_all = get_strategies_catalog("presets", "all", &bin_str);
        assert_eq!(bad_all["success"], false);

        let bad_z2 = get_strategies_catalog("presets", "zapret2", &bin_str);
        assert_eq!(bad_z2["success"], false);

        let missing_bin = get_strategies_catalog("presets", "desync", "/nonexistent/tachyon-core");
        assert_eq!(missing_bin["success"], false);
        assert_eq!(missing_bin["available_engines"]["desync"], false);

        let ok_ds = get_strategies_catalog("presets", "desync", &bin_str);
        assert_eq!(ok_ds["success"], true);
        assert_eq!(ok_ds["available_engines"]["desync"], true);
        assert!(!ok_ds["desync"].as_array().unwrap().is_empty());

        let start_all = start_benchmark(
            bin_str.clone(),
            "all",
            "youtube_suite",
            "",
            "",
            "",
            "presets",
            60,
        );
        assert_eq!(start_all["success"], false);

        let start_global_target = start_benchmark(
            bin_str.clone(),
            "desync",
            "global",
            "",
            "",
            "",
            "presets",
            60,
        );
        assert_eq!(start_global_target["success"], false);

        let start_default_sec = start_benchmark(
            bin_str,
            "desync",
            "youtube_suite",
            "",
            "default",
            "",
            "presets",
            60,
        );
        assert_eq!(start_default_sec["success"], false);

        let huge_results: Vec<Value> = (0..120)
            .map(|i| {
                json!({
                    "id": format!("s_{i}"),
                    "name": format!("Strategy #{i} {}", "x".repeat(200)),
                    "args": "mode=fake_split split_pos=sni",
                    "success": false,
                    "sub_probes": [
                        { "target_name": "youtube.com", "url": "https://youtube.com", "success": false, "error": "timeout ".repeat(20) },
                        { "target_name": "discord.com", "url": "https://discord.com", "success": true, "ttfb_ms": 42, "http_code": 200 }
                    ]
                })
            })
            .collect();
        let capped = cap_state_json_under_limit(
            &json!({ "success": true, "results": huge_results }),
            MAX_FUZZER_STATE_BYTES,
        );
        let serialized = serde_json::to_string(&capped).unwrap();
        assert!(serialized.len() <= MAX_FUZZER_STATE_BYTES);

        let _ = std::fs::remove_file(bin);
    }

    #[test]
    fn filters_pure_udp_strategies_for_tcp_targets() {
        let tcp_spec = StrategySpec {
            id: "t1".into(),
            name: "TCP".into(),
            args: "mode=fake_split split_pos=sni udp_fake=true".into(),
            description: String::new(),
            source: "test".into(),
        };
        let udp_only = StrategySpec {
            id: "u1".into(),
            name: "UDP only".into(),
            args: "udp_fake=true udp_repeats=6 udp_fake_ttl=6".into(),
            description: String::new(),
            source: "test".into(),
        };
        let tcp_out = filter_strategies_for_target(
            vec![tcp_spec.clone(), udp_only.clone()],
            "youtube_suite",
            "",
        );
        assert_eq!(tcp_out.len(), 1);
        assert_eq!(tcp_out[0].id, "t1");

        let udp_out = filter_strategies_for_target(
            vec![tcp_spec, udp_only],
            "custom",
            "udp://stun.l.google.com:19302",
        );
        assert_eq!(udp_out.len(), 2);
    }
}
