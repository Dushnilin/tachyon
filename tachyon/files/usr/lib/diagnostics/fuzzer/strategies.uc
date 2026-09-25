#!/usr/bin/env ucode
//
// Fuzzer strategy catalogue, presets and generators.
//
// Extracted from diagnostics/fuzzer.uc (branch 6 god-module split). Holds the
// built-in strategy matrices, preset loading/merging, combinatorial and
// adaptive generators, and the public "strategies" surface the CLI exposes.
//

let fs = require("fs");
let common = require("core.common");
let uci_core = require("core.uci");
let fuzzer_runner = require("diagnostics.fuzzer_runner");
let binaries = require("diagnostics.fuzzer.binaries");
let history = require("diagnostics.fuzzer.history");

let as_string = common.as_string;
let read_json_file = common.read_json_file;
let write_json_file = common.write_json_file;
let command_from_args = common.command_from_args;
let command_output = common.command_output;
let command_status = common.command_status;
let command_success = common.command_success;
let command_success_from_args = common.command_success_from_args;
let shell_quote = common.shell_quote;
let object_or_empty = common.object_or_empty;
let array_or_empty = common.array_or_empty;

const CONFIG_NAME = getenv("TACHYON_CONFIG_NAME") || "tachyon";
const LIB_DIR = getenv("TACHYON_LIB") || "/usr/lib/tachyon";
const STATE_DIR = getenv("TACHYON_FUZZER_STATE_DIR") || "/var/run/tachyon";

const PATTERNS_FILE = "/etc/tachyon/fuzzer_patterns.json";
const BUILTIN_PRESETS_FILE = getenv("TACHYON_PRESETS_FILE") || "/usr/share/tachyon/dpi-presets.json";
const USER_PRESETS_FILE = "/etc/tachyon/dpi-presets-user.json";

const DEFAULT_PATTERNS = {
    zapret2: {
        splits: [ "1", "2", "3", "midsld", "sniext+2", "sniext+4", "1,midsld", "1,sniext+2" ],
        foolings: [ "badseq", "md5sig", "badack", "datanoack", "fakeddrop" ],
        ttls: [ 2, 3, 4, 5, 6, 8 ],
        seqovls: [ "1", "2" ],
        wsizes: [ "1" ],
        blobs: [ "tls_max", "tls_google", "tls_gosuslugi", "tls_sber", "tls_iana" ],
        syndata: true,
        repeats: [ 6, 8 ],
        payloads: [ "tls_client_hello", "http_req", "quic_initial" ]
    },
    zapret: {
        splits: [ "1", "2", "midsld", "sniext+4", "1,midsld" ],
        foolings: [ "badseq", "md5sig", "badack", "datanoack" ],
        ttls: [ 2, 3, 4, 6, 8 ],
        split_modes: [ "split2", "disorder2", "fake,split2", "fake,disorder2" ]
    },
    byedpi: {
        splits: [ "1", "2", "1+sniext", "midsld" ],
        disorders: [ "1", "2" ],
        ttls: [ 2, 3, 4, 6, 8 ],
        oobs: [ "1", "2" ],
        autos: [ "t,r,a,s", "r,s", "t,a" ],
        tlsrecs: [ "1+sniext" ],
        ipfrags: [ "24" ]
    },
    custom_strategies: []
};

let _builtin_presets_cache = null;
let _preset_autoid = 0;

const STRATEGIES_ZAPRET2 = [
    // ── 1. REAL-WORLD PRODUCTION CHAMPIONS (From Active Router Config) ─────────
    {
        id: "z2_paws_max_multisplit",
        name: "PAWS Spoofing (Max.ru, tcp_ts) + Multisplit",
        engine: "zapret2",
        args: "--lua-desync=fake:blob=tls_max:repeats=8:tcp_ts=-600000:tcp_ts_up --lua-desync=multisplit:pos=1:seqovl=664:seqovl_pattern=tls_max",
        description: "PAWS TCP timestamp evasion with authentic Max.ru ClientHello pattern overlap. Top-tier TSPU bypass."
    },
    {
        id: "z2_paws_google_multisplit",
        name: "PAWS Spoofing (Google, tcp_ts) + Multisplit",
        engine: "zapret2",
        args: "--lua-desync=fake:blob=tls_google:repeats=8:tcp_ts=-600000:tcp_ts_up --lua-desync=multisplit:pos=1:seqovl=681:seqovl_pattern=tls_google",
        description: "PAWS spoofing using authentic Google ClientHello blob and exact 681-byte sequence overlap."
    },
    {
        id: "z2_paws_gosuslugi_multisplit",
        name: "PAWS Spoofing (Gosuslugi Whitelist) + Multisplit",
        engine: "zapret2",
        args: "--lua-desync=fake:blob=tls_gosuslugi:repeats=6:tcp_ts=-600000:tcp_ts_up --lua-desync=multisplit:pos=1,midsld:seqovl=517:seqovl_pattern=tls_gosuslugi",
        description: "Mimics official Russian Government Gosuslugi portal ClientHello with PAWS RFC 7323 drop."
    },
    {
        id: "z2_paws_sber_multisplit",
        name: "PAWS Spoofing (Sberbank Whitelist) + Multisplit",
        engine: "zapret2",
        args: "--lua-desync=fake:blob=tls_sber:repeats=6:tcp_ts=-600000:tcp_ts_up --lua-desync=multisplit:pos=1,midsld:seqovl=517:seqovl_pattern=tls_sber",
        description: "Mimics Sberbank TLS ClientHello with ancient TCP timestamp."
    },
    {
        id: "z2_paws_iana_multisplit",
        name: "PAWS Spoofing (IANA Root) + Multisplit",
        engine: "zapret2",
        args: "--lua-desync=fake:blob=tls_iana:repeats=6:tcp_ts=-600000:tcp_ts_up --lua-desync=multisplit:pos=1,midsld:seqovl=517:seqovl_pattern=tls_iana",
        description: "Authentic IANA ClientHello with PAWS timestamp spoofing."
    },

    // ── 2. TCP SYN DATA SUITE ──────────────────────────────────────────────────
    {
        id: "z2_syndata_multidisorder",
        name: "TCP SYN Data + Multidisorder (pos=1,midsld)",
        engine: "zapret2",
        args: "--lua-desync=syndata --lua-desync=multidisorder:pos=1,midsld",
        description: "Injects payload into TCP SYN packet and disorders following segments. Bypasses stateful DPI."
    },
    {
        id: "z2_syndata_multisplit",
        name: "TCP SYN Data + Multisplit (pos=1,midsld)",
        engine: "zapret2",
        args: "--lua-desync=syndata --lua-desync=multisplit:pos=1,midsld:seqovl=1:fooling=badseq",
        description: "Combines SYN data injection with segmented SNI payload and badseq fooling."
    },
    {
        id: "z2_syndata_wsize",
        name: "TCP SYN Data + Window Clamp (wsize=1)",
        engine: "zapret2",
        args: "--lua-desync=syndata --lua-desync=multisplit:pos=1,midsld:wsize=1",
        description: "SYN data payload followed by 1-byte TCP window segments."
    },

    // ── 3. DUAL-STAGE & COMPOSITE DESYNC SUITE ────────────────────────────────
    {
        id: "z2_dual_fake_max",
        name: "Dual Fake (STUN + Max.ru, tcp_ts) + Multisplit",
        engine: "zapret2",
        args: "--lua-desync=fake:blob=stun_fake:repeats=6:tcp_ts=-600000:tcp_ts_up --lua-desync=fake:blob=tls_max:repeats=6:tcp_ts=-600000:tcp_ts_up --lua-desync=multisplit:pos=1:seqovl=664:seqovl_pattern=tls_max",
        description: "Consecutive fake STUN and TLS packets with PAWS timestamps before overlapped multisplit."
    },
    {
        id: "z2_fake_repeats8_multisplit",
        name: "Burst Fake (repeats=8, tcp_ts) + Multisplit",
        engine: "zapret2",
        args: "--lua-desync=fake:blob=tls_google:repeats=8:tcp_ts=-600000:tcp_ts_up --lua-desync=multisplit:pos=1,midsld:seqovl=2:fooling=badseq",
        description: "High-intensity 8-packet fake burst with PAWS timestamp before segmented payload."
    },

    // ── 4. YOUTUBE 4K & GOOGLEVIDEO STREAM CDN SUITE ───────────────────────────
    {
        id: "z2_yt_multisplit_midsld",
        name: "YouTube 4K Multisplit + MidSLD",
        engine: "zapret2",
        args: "--lua-desync=multisplit:pos=1,midsld:seqovl=1:fooling=badseq",
        description: "Optimized for GoogleVideo 4K chunk streams and TSPU TLS desync."
    },
    {
        id: "z2_yt_multisplit_sniext",
        name: "SNI Extension Split + Badseq",
        engine: "zapret2",
        args: "--lua-desync=multisplit:pos=1,sniext+4:seqovl=1:fooling=badseq",
        description: "Splits deep into SNI extensions to fool next-gen DPI signatures."
    },
    {
        id: "z2_aggressive_combo",
        name: "Aggressive Triple-Split + SeqOvl 2",
        engine: "zapret2",
        args: "--lua-desync=multisplit:pos=1,midsld,sniext+2:seqovl=2:fooling=badseq",
        description: "High-entropy triple fragmentation for heavily filtered regions."
    },
    {
        id: "z2_wsize_seqovl_combo",
        name: "Window Clamp (wsize=1) + SeqOvl",
        engine: "zapret2",
        args: "--lua-desync=multisplit:pos=1,midsld:wsize=1:seqovl=1:fooling=badseq",
        description: "Combines 1-byte window clamp with sequence overlap."
    },
    {
        id: "z2_wsize_multisplit",
        name: "Window Size Clamp (wsize=1)",
        engine: "zapret2",
        args: "--lua-desync=multisplit:pos=1,midsld:wsize=1:fooling=badseq",
        description: "Forces single-byte TCP window segments to evade reassembly."
    },

    // ── 5. DISCORD FULL-STACK & VOICE/RTC SUITE ────────────────────────────────
    {
        id: "z2_discord_fullstack",
        name: "Discord Full-Stack Multi-Profile",
        engine: "zapret2",
        args: "--filter-tcp=443 --lua-desync=fake:blob=tls_max:repeats=8:tcp_ts=-600000:tcp_ts_up --lua-desync=multisplit:pos=1:seqovl=664:seqovl_pattern=tls_max --new --filter-tcp=2053,2083,2087,2096,8443 --filter-l7=tls --payload=tls_client_hello --lua-desync=fake:blob=tls_google:repeats=6:tcp_ts=-600000:tcp_ts_up --lua-desync=multisplit:pos=1:seqovl=681:seqovl_pattern=tls_google --new --filter-udp=19294-19344,50000-50100 --filter-l7=discord,stun --payload=discord_ip_discovery,stun --lua-desync=fake:blob=discord_udp:repeats=6",
        description: "Production multi-profile: HTTPS, alternate Cloudflare edge ports, and Discord Voice/STUN UDP."
    },
    {
        id: "z2_discord_udp",
        name: "Discord Voice UDP Desync",
        engine: "zapret2",
        args: "--filter-udp=19294-19344,50000-65535 --filter-l7=discord,stun --payload=discord_ip_discovery,stun --lua-desync=fake:blob=discord_udp:repeats=6",
        description: "UDP fake packet desync for Discord RTC and Voice channels."
    },
    {
        id: "z2_quic_http3_udp",
        name: "QUIC / HTTP3 UDP Fake Desync (Google Kyber)",
        engine: "zapret2",
        args: "--filter-udp=443 --filter-l7=quic --payload=quic_initial --lua-desync=fake:blob=quic_google:repeats=11",
        description: "UDP fake desync using 1200-byte Google QUIC Initial blob with 11 repeats."
    },

    // ── 6. ADVANCED REORDER & FAKED SEGMENTS ────────────────────────────────────
    {
        id: "z2_fakedsplit_badseq",
        name: "Faked Split (pos=1,midsld) + BadSeq",
        engine: "zapret2",
        args: "--lua-desync=fakedsplit:pos=1,midsld:fooling=badseq",
        description: "Splits real stream and inserts fake packets between fragments."
    },
    {
        id: "z2_fakeddisorder",
        name: "Faked Disorder (pos=1,midsld)",
        engine: "zapret2",
        args: "--lua-desync=fakeddisorder:pos=1,midsld:fooling=badseq",
        description: "Inserts out-of-order fake fragments with invalid sequence fooling."
    },
    {
        id: "z2_hostfakesplit",
        name: "Hostfake Split (pos=1,midsld)",
        engine: "zapret2",
        args: "--lua-desync=hostfakesplit:pos=1,midsld:fooling=badseq",
        description: "Replaces host header/SNI in first split packet with dummy host."
    },
    {
        id: "z2_tcpseg_multisplit",
        name: "TCPSeg (size=40) + Multisplit (pos=midsld)",
        engine: "zapret2",
        args: "--lua-desync=tcpseg:size=40 --lua-desync=multisplit:pos=midsld:fooling=badseq",
        description: "Forces low TCP MSS segment size before mid-SLD desync."
    },
    {
        id: "z2_multidisorder_midsld",
        name: "Classic Multidisorder (pos=1,midsld)",
        engine: "zapret2",
        args: "--lua-desync=multidisorder:pos=1,midsld:fooling=badseq",
        description: "Sends out-of-order segments at start and mid-SLD with badseq fooling."
    },
    {
        id: "z2_split_pos1",
        name: "Classic Multisplit (pos=1)",
        engine: "zapret2",
        args: "--lua-desync=multisplit:pos=1:fooling=badseq",
        description: "Standard 2-fragment multisplit desync for compatibility."
    },
    {
        id: "z2_disorder_pos2",
        name: "Classic Multidisorder (pos=2)",
        engine: "zapret2",
        args: "--lua-desync=multidisorder:pos=2:fooling=badseq",
        description: "Sends out-of-order segment with badseq fooling."
    },

    // ── 7. LOW-TTL ADAPTIVE MATRIX ─────────────────────────────────────────────
    {
        id: "z2_fake_ttl3_md5sig",
        name: "Fake (TTL=3, MD5Sig) + Multisplit",
        engine: "zapret2",
        args: "--lua-desync=fake:ttl=3:fooling=md5sig --lua-desync=multisplit:pos=1,midsld",
        description: "Aggressive low-TTL MD5Sig injection for close TSPU hops."
    },
    {
        id: "z2_fake_ttl4_badseq",
        name: "Fake (TTL=4, BadSeq) + Multisplit",
        engine: "zapret2",
        args: "--lua-desync=fake:ttl=4:fooling=badseq --lua-desync=multisplit:pos=1,midsld",
        description: "Low-TTL fake ClientHello with badseq fooling and multisplit segmentation."
    },
    {
        id: "z2_fake_ttl5_md5sig",
        name: "Fake (TTL=5, MD5Sig) + Multisplit",
        engine: "zapret2",
        args: "--lua-desync=fake:ttl=5:fooling=md5sig --lua-desync=multisplit:pos=1,midsld",
        description: "MD5Sig TCP option drops packet at DPI while reaching end server."
    },
    {
        id: "z2_fake_ttl6_badack",
        name: "Fake (TTL=6, BadACK) + Multisplit",
        engine: "zapret2",
        args: "--lua-desync=fake:ttl=6:fooling=badack --lua-desync=multisplit:pos=1,sniext+2",
        description: "BadACK fooling invalidates packet in DPI state tracking."
    },
    {
        id: "z2_fake_badseq_mid",
        name: "Fake Packet (TTL=8) + MidSLD Split",
        engine: "zapret2",
        args: "--lua-desync=fake:ttl=8:fooling=badseq --lua-desync=multisplit:pos=midsld",
        description: "Injects fake ClientHello before segmented payload."
    },
    {
        id: "z2_fake_datanoack",
        name: "Fake (TTL=8, DataNoAck) + Multisplit",
        engine: "zapret2",
        args: "--lua-desync=fake:ttl=8:fooling=datanoack --lua-desync=multisplit:pos=1",
        description: "DataNoAck fooling confuses stateful DPI without triggering ACK RST."
    },
    {
        id: "z2_oob_pos1",
        name: "OOB Out-of-Band Data (pos=1)",
        engine: "zapret2",
        args: "--lua-desync=oob:pos=1",
        description: "TCP Out-Of-Band URG flag packet to desynchronize DPI reassembly."
    },

    // ── 8. BLOCKCHECKW & BLOCKCHECK2 COMBAT STRATEGIES ─────────────────────────
    {
        id: "z2_bc_multisplit_7point",
        name: "7-Point MultiSplit (ClientHello Full Spectrum)",
        engine: "zapret2",
        args: "--payload=tls_client_hello --lua-desync=multisplit:pos=1,sniext+1,host+1,midsld-2,midsld,midsld+2,endhost-1",
        description: "Splits at start, SNI extension, host header, mid-SLD, and end of host. Top blockcheck2 bypass."
    },
    {
        id: "z2_bc_multidisorder_7point",
        name: "7-Point MultiDisorder (ClientHello Full Spectrum)",
        engine: "zapret2",
        args: "--payload=tls_client_hello --lua-desync=multidisorder:pos=1,sniext+1,host+1,midsld-2,midsld,midsld+2,endhost-1",
        description: "Disorders all critical TLS ClientHello headers. Devastates stateful DPI reassembly."
    },
    {
        id: "z2_bc_multisplit_1220",
        name: "Tri-Point MultiSplit (pos=1,midsld,1220)",
        engine: "zapret2",
        args: "--payload=tls_client_hello --lua-desync=multisplit:pos=1,midsld,1220",
        description: "Splits at start, mid-SLD, and packet boundary (1220 B)."
    },
    {
        id: "z2_bc_multidisorder_1220",
        name: "Tri-Point MultiDisorder (pos=1,midsld,1220)",
        engine: "zapret2",
        args: "--payload=tls_client_hello --lua-desync=multidisorder:pos=1,midsld,1220",
        description: "Disorders stream at start, mid-SLD, and MTU boundary (1220 B)."
    },
    {
        id: "z2_bc_tcpseg_rep260",
        name: "TCP Segment Desync (repeats=260, pos=0,1)",
        engine: "zapret2",
        args: "--payload=tls_client_hello --lua-desync=tcpseg:pos=0,1:ip_id=rnd:repeats=260",
        description: "Forces randomized IP ID TCP segmentation burst with 260 repeats to overflow DPI state table."
    },
    {
        id: "z2_bc_tcpseg_rep100_midsld",
        name: "TCP Segment Desync (repeats=100, midsld)",
        engine: "zapret2",
        args: "--payload=tls_client_hello --lua-desync=tcpseg:pos=0,midsld:ip_id=rnd:repeats=100",
        description: "Mid-SLD TCP segmentation with 100 repeats."
    },
    {
        id: "z2_bc_oob_midsld",
        name: "OOB Desync (urp=midsld)",
        engine: "zapret2",
        args: "--in-range=-s1 --lua-desync=oob:urp=midsld",
        description: "TCP Out-Of-Band packet with urgent pointer pointing directly to mid-domain."
    },
    {
        id: "z2_bc_oob_b",
        name: "OOB Desync (urp=b)",
        engine: "zapret2",
        args: "--in-range=-s1 --lua-desync=oob:urp=b",
        description: "TCP Out-Of-Band with beginning urgent pointer offset."
    },
    {
        id: "z2_bc_seqovl_sniext",
        name: "Exact SeqOvl Pattern Overlap (sniext+1, Max.ru)",
        engine: "zapret2",
        args: "--payload=tls_client_hello --lua-desync=multidisorder:pos=sniext+1:seqovl=sniext:seqovl_pattern=tls_max",
        description: "Disorders at SNI extension with exact sequence overlap pattern."
    },
    {
        id: "z2_bc_seqovl_midsld",
        name: "Exact SeqOvl Pattern Overlap (midsld, Google)",
        engine: "zapret2",
        args: "--payload=tls_client_hello --lua-desync=multidisorder:pos=midsld:seqovl=midsld-1:seqovl_pattern=tls_google",
        description: "Disorders at mid-SLD with exact sequence overlap pattern from Google ClientHello."
    },
    {
        id: "z2_bc_lua_padencap",
        name: "Dynamic Lua TLS Mod (padencap + dupsid) + MultiSplit",
        engine: "zapret2",
        args: "--payload=tls_client_hello --lua-desync=luaexec:code=desync.patmod=tls_mod(fake_default_tls,'rnd,dupsid,padencap',desync.reasm_data) --lua-desync=multisplit:pos=10,sniext+1:seqovl=#patmod:seqovl_pattern=patmod",
        description: "Dynamically pads and encapsulates ClientHello payload via Lua runtime."
    },
    {
        id: "z2_bc_tcp_ack_offset",
        name: "TCP ACK Offset Spoofing (-66000) + TS_UP",
        engine: "zapret2",
        args: "--payload=tls_client_hello --lua-desync=fake:blob=tls_max:tcp_ack=-66000:tcp_ts_up:repeats=6",
        description: "Injects fake packets with corrupted ACK number and ascending TCP timestamps."
    },
    {
        id: "z2_bc_tcp_flags_unset_ack",
        name: "TCP Flags Manipulation (Unset ACK)",
        engine: "zapret2",
        args: "--payload=tls_client_hello --lua-desync=fake:blob=tls_google:tcp_flags_unset=ACK:repeats=6",
        description: "Fake packets with ACK flag cleared, accepted only by DPI state trackers."
    },
    {
        id: "z2_bc_tcp_flags_set_syn",
        name: "TCP Flags Manipulation (Set SYN on Data)",
        engine: "zapret2",
        args: "--payload=tls_client_hello --lua-desync=fake:blob=tls_max:tcp_flags_set=SYN:repeats=6",
        description: "Sets SYN flag on ClientHello fake packets to trigger DPI state desynchronization."
    },
    {
        id: "z2_bc_badsum",
        name: "BadSum Checksum Invalidation",
        engine: "zapret2",
        args: "--payload=tls_client_hello --lua-desync=fake:blob=tls_google:badsum:repeats=6",
        description: "Packets with invalid L4 checksum are dropped by remote server NIC but inspected by DPI."
    },
    {
        id: "z2_bc_autottl_1",
        name: "Auto-TTL Adaptive Probe (autottl=-1, 3-20)",
        engine: "zapret2",
        args: "--payload=tls_client_hello --lua-desync=fake:blob=tls_max:ip_autottl=-1,3-20:repeats=6",
        description: "Dynamically calculates hop distance to target and injects fake packets right before DPI hop."
    },
    {
        id: "z2_bc_autottl_2",
        name: "Auto-TTL Adaptive Probe (autottl=-2, 3-20)",
        engine: "zapret2",
        args: "--payload=tls_client_hello --lua-desync=fake:blob=tls_google:ip_autottl=-2,3-20:repeats=6",
        description: "Auto-TTL probe with 2 hops before target."
    },
    {
        id: "z2_bc_pktmod",
        name: "PktMod Packet Mutation (ip_ttl=1)",
        engine: "zapret2",
        args: "--payload=tls_client_hello --lua-desync=fake:blob=tls_max:ip_ttl=1:repeats=6 --payload=empty --out-range=s1<d1 --lua-desync=pktmod:ip_ttl=1",
        description: "Mutates outgoing packets in the range between server SYN and data."
    }
];

const STRATEGIES_ZAPRET = [
    {
        id: "z1_split2_pos2",
        name: "Standard Split2 (pos=2)",
        engine: "zapret",
        args: "--dpi-desync=split2 --dpi-desync-split-pos=2",
        description: "Base HTTP/TLS split inside SNI header."
    },
    {
        id: "z1_split2_pos1",
        name: "Standard Split2 (pos=1)",
        engine: "zapret",
        args: "--dpi-desync=split2 --dpi-desync-split-pos=1",
        description: "1-byte TLS ClientHello split."
    },
    {
        id: "z1_disorder2_badseq",
        name: "Disorder2 + BadSeq (pos=1)",
        engine: "zapret",
        args: "--dpi-desync=disorder2 --dpi-desync-split-pos=1 --dpi-desync-fooling=badseq",
        description: "Sends out-of-order packets with invalid TCP sequence fooling."
    },
    {
        id: "z1_disorder2_midsld",
        name: "Disorder2 + MidSLD (pos=midsld)",
        engine: "zapret",
        args: "--dpi-desync=disorder2 --dpi-desync-split-pos=midsld --dpi-desync-fooling=badseq",
        description: "Disorders stream in the middle of second-level domain name."
    },
    {
        id: "z1_fake_split2_ttl8",
        name: "Fake SNI + Split2 (TTL=8)",
        engine: "zapret",
        args: "--dpi-desync=fake,split2 --dpi-desync-split-pos=1 --dpi-desync-ttl=8 --dpi-desync-fooling=badseq",
        description: "Sends TTL=8 fake packet followed by segmented ClientHello."
    },
    {
        id: "z1_fake_split2_ttl6",
        name: "Fake SNI + Split2 (TTL=6)",
        engine: "zapret",
        args: "--dpi-desync=fake,split2 --dpi-desync-split-pos=1 --dpi-desync-ttl=6 --dpi-desync-fooling=badseq",
        description: "Sends TTL=6 fake packet for closer TSPU hops."
    },
    {
        id: "z1_fake_split2_ttl4",
        name: "Fake SNI + Split2 (TTL=4)",
        engine: "zapret",
        args: "--dpi-desync=fake,split2 --dpi-desync-split-pos=1 --dpi-desync-ttl=4 --dpi-desync-fooling=badseq",
        description: "Low TTL=4 fake packet for nearest TSPU filters."
    },
    {
        id: "z1_fake_disorder2_ttl8",
        name: "Fake SNI + Disorder2 (TTL=8)",
        engine: "zapret",
        args: "--dpi-desync=fake,disorder2 --dpi-desync-split-pos=1 --dpi-desync-ttl=8 --dpi-desync-fooling=badseq",
        description: "Sends fake packet and disorders real segments."
    },
    {
        id: "z1_seqovl_split2_1",
        name: "Sequence Overlap (SeqOvl=1)",
        engine: "zapret",
        args: "--dpi-desync=split2 --dpi-desync-split-seqovl=1 --dpi-desync-fooling=badseq",
        description: "1-byte overlapping TCP payload to confuse stateful DPI."
    },
    {
        id: "z1_seqovl_split2_2",
        name: "Sequence Overlap (SeqOvl=2)",
        engine: "zapret",
        args: "--dpi-desync=split2 --dpi-desync-split-seqovl=2 --dpi-desync-fooling=badseq",
        description: "2-byte overlapping TCP payload for aggressive DPI desync."
    },
    {
        id: "z1_seqovl_split2_336",
        name: "Deep Sequence Overlap (SeqOvl=336)",
        engine: "zapret",
        args: "--dpi-desync=split2 --dpi-desync-split-seqovl=336 --dpi-desync-fooling=badseq",
        description: "336-byte full SNI overlap to overwrite ClientHello in DPI reassembly."
    },
    {
        id: "z1_md5sig_disorder",
        name: "MD5Sig Fooling + Disorder (TTL=6)",
        engine: "zapret",
        args: "--dpi-desync=fake,disorder2 --dpi-desync-fooling=md5sig --dpi-desync-ttl=6",
        description: "Injects TCP MD5 signature option to trigger DPI packet drop."
    },
    {
        id: "z1_badack_disorder",
        name: "BadACK Fooling + Disorder (TTL=8)",
        engine: "zapret",
        args: "--dpi-desync=fake,disorder2 --dpi-desync-fooling=badack --dpi-desync-ttl=8",
        description: "Injects BadACK sequence to break TCP state tracking."
    },
    {
        id: "z1_fake_midsld_split",
        name: "Fake + MidSLD Split (TTL=8)",
        engine: "zapret",
        args: "--dpi-desync=fake,split2 --dpi-desync-split-pos=midsld --dpi-desync-ttl=8 --dpi-desync-fooling=badseq",
        description: "Splits in middle of domain name with fake injection."
    },
    {
        id: "z1_cutoff_fake_split",
        name: "Cutoff d4 + Fake,Split2 (TTL=6)",
        engine: "zapret",
        args: "--dpi-desync=fake,split2 --dpi-desync-cutoff=d4 --dpi-desync-ttl=6 --dpi-desync-fooling=badseq",
        description: "Stops desync after 4 server data packets to preserve CPU and performance."
    },
    {
        id: "z1_repeats_fake_split",
        name: "Burst Repeats=6 Fake + Split2 (pos=1)",
        engine: "zapret",
        args: "--dpi-desync=fake,split2 --dpi-desync-split-pos=1 --dpi-desync-repeats=6 --dpi-desync-ttl=8 --dpi-desync-fooling=badseq",
        description: "Sends 6 consecutive fake packets to saturate DPI connection tracking."
    }
];

const STRATEGIES_FLOWSEAL = [
    {
        id: "fs_split2",
        name: "[Flowseal] Split2 (pos=2)",
        engine: "zapret",
        args: "--dpi-desync=split2 --dpi-desync-split-pos=2",
        description: "Flowseal general: basic TLS SNI split at position 2."
    },
    {
        id: "fs_split2_pos1",
        name: "[Flowseal] Split2 (pos=1)",
        engine: "zapret",
        args: "--dpi-desync=split2 --dpi-desync-split-pos=1",
        description: "Flowseal general: 1-byte TLS ClientHello split."
    },
    {
        id: "fs_disorder2",
        name: "[Flowseal] Disorder2 (pos=1, badseq)",
        engine: "zapret",
        args: "--dpi-desync=disorder2 --dpi-desync-split-pos=1 --dpi-desync-fooling=badseq",
        description: "Flowseal general: out-of-order packet with badseq fooling."
    },
    {
        id: "fs_split2_ttl4",
        name: "[Flowseal] Split2 + TTL=4",
        engine: "zapret",
        args: "--dpi-desync=split2 --dpi-desync-split-pos=2 --dpi-desync-ttl=4",
        description: "Flowseal ALT2: split with low TTL fake."
    },
    {
        id: "fs_split2_ttl6",
        name: "[Flowseal] Split2 + TTL=6",
        engine: "zapret",
        args: "--dpi-desync=split2 --dpi-desync-split-pos=2 --dpi-desync-ttl=6",
        description: "Flowseal ALT2: split with medium TTL fake."
    },
    {
        id: "fs_disorder2_ttl4",
        name: "[Flowseal] Disorder2 + TTL=4 (badseq)",
        engine: "zapret",
        args: "--dpi-desync=disorder2 --dpi-desync-split-pos=1 --dpi-desync-ttl=4 --dpi-desync-fooling=badseq",
        description: "Flowseal ALT2: disorder with TTL=4."
    },
    {
        id: "fs_disorder2_ttl6",
        name: "[Flowseal] Disorder2 + TTL=6 (badseq)",
        engine: "zapret",
        args: "--dpi-desync=disorder2 --dpi-desync-split-pos=1 --dpi-desync-ttl=6 --dpi-desync-fooling=badseq",
        description: "Flowseal ALT2: disorder with TTL=6."
    },
    {
        id: "fs_fake_split2_ttl4",
        name: "[Flowseal] Fake + Split2 (TTL=4, badseq)",
        engine: "zapret",
        args: "--dpi-desync=fake,split2 --dpi-desync-split-pos=1 --dpi-desync-ttl=4 --dpi-desync-fooling=badseq",
        description: "Flowseal: fake packet + split at TTL=4."
    },
    {
        id: "fs_fake_split2_ttl6",
        name: "[Flowseal] Fake + Split2 (TTL=6, badseq)",
        engine: "zapret",
        args: "--dpi-desync=fake,split2 --dpi-desync-split-pos=1 --dpi-desync-ttl=6 --dpi-desync-fooling=badseq",
        description: "Flowseal: fake packet + split at TTL=6."
    },
    {
        id: "fs_fake_split2_ttl8",
        name: "[Flowseal] Fake + Split2 (TTL=8, badseq)",
        engine: "zapret",
        args: "--dpi-desync=fake,split2 --dpi-desync-split-pos=1 --dpi-desync-ttl=8 --dpi-desync-fooling=badseq",
        description: "Flowseal: fake packet + split at TTL=8."
    },
    {
        id: "fs_fake_disorder2_ttl6",
        name: "[Flowseal] Fake + Disorder2 (TTL=6, badseq)",
        engine: "zapret",
        args: "--dpi-desync=fake,disorder2 --dpi-desync-split-pos=1 --dpi-desync-ttl=6 --dpi-desync-fooling=badseq",
        description: "Flowseal: fake packet + disorder at TTL=6."
    },
    {
        id: "fs_fake_disorder2_ttl8",
        name: "[Flowseal] Fake + Disorder2 (TTL=8, badseq)",
        engine: "zapret",
        args: "--dpi-desync=fake,disorder2 --dpi-desync-split-pos=1 --dpi-desync-ttl=8 --dpi-desync-fooling=badseq",
        description: "Flowseal: fake packet + disorder at TTL=8."
    },
    {
        id: "fs_split2_seqovl1",
        name: "[Flowseal] Split2 + SeqOvl=1 (badseq)",
        engine: "zapret",
        args: "--dpi-desync=split2 --dpi-desync-split-pos=2 --dpi-desync-split-seqovl=1 --dpi-desync-fooling=badseq",
        description: "Flowseal ALT3: split with 1-byte sequence overlap."
    },
    {
        id: "fs_split2_seqovl2",
        name: "[Flowseal] Split2 + SeqOvl=2 (badseq)",
        engine: "zapret",
        args: "--dpi-desync=split2 --dpi-desync-split-pos=2 --dpi-desync-split-seqovl=2 --dpi-desync-fooling=badseq",
        description: "Flowseal ALT3: split with 2-byte sequence overlap."
    },
    {
        id: "fs_split2_seqovl1_ttl6",
        name: "[Flowseal] Split2 + SeqOvl=1 + TTL=6 (badseq)",
        engine: "zapret",
        args: "--dpi-desync=split2 --dpi-desync-split-pos=2 --dpi-desync-split-seqovl=1 --dpi-desync-ttl=6 --dpi-desync-fooling=badseq",
        description: "Flowseal ALT3: split with overlap and TTL=6."
    },
    {
        id: "fs_split2_seqovl2_ttl8",
        name: "[Flowseal] Split2 + SeqOvl=2 + TTL=8 (badseq)",
        engine: "zapret",
        args: "--dpi-desync=split2 --dpi-desync-split-pos=2 --dpi-desync-split-seqovl=2 --dpi-desync-ttl=8 --dpi-desync-fooling=badseq",
        description: "Flowseal ALT3: split with overlap and TTL=8."
    },
    {
        id: "fs_split2_repeats6",
        name: "[Flowseal] Split2 + Repeats=6 (TTL=8, badseq)",
        engine: "zapret",
        args: "--dpi-desync=split2 --dpi-desync-split-pos=2 --dpi-desync-repeats=6 --dpi-desync-ttl=8 --dpi-desync-fooling=badseq",
        description: "Flowseal ALT4: burst repeats with split."
    },
    {
        id: "fs_disorder2_repeats6",
        name: "[Flowseal] Disorder2 + Repeats=6 (TTL=8, badseq)",
        engine: "zapret",
        args: "--dpi-desync=disorder2 --dpi-desync-split-pos=1 --dpi-desync-repeats=6 --dpi-desync-ttl=8 --dpi-desync-fooling=badseq",
        description: "Flowseal ALT4: burst repeats with disorder."
    },
    {
        id: "fs_fake_split2_cutoff4",
        name: "[Flowseal] Fake + Split2 + Cutoff=d4 (TTL=6, badseq)",
        engine: "zapret",
        args: "--dpi-desync=fake,split2 --dpi-desync-split-pos=1 --dpi-desync-cutoff=d4 --dpi-desync-ttl=6 --dpi-desync-fooling=badseq",
        description: "Flowseal: stops desync after 4 server data packets."
    },
    {
        id: "fs_split2_cutoff3",
        name: "[Flowseal] Split2 + Cutoff=n3 (TTL=8, badseq)",
        engine: "zapret",
        args: "--dpi-desync=split2 --dpi-desync-split-pos=2 --dpi-desync-cutoff=n3 --dpi-desync-ttl=8 --dpi-desync-fooling=badseq",
        description: "Flowseal ALT6: cutoff after 3 packets."
    },
    {
        id: "fs_midsld_disorder",
        name: "[Flowseal] Disorder2 (pos=midsld, badseq)",
        engine: "zapret",
        args: "--dpi-desync=disorder2 --dpi-desync-split-pos=midsld --dpi-desync-fooling=badseq",
        description: "Flowseal: disorder at middle of second-level domain."
    },
    {
        id: "fs_midsld_split",
        name: "[Flowseal] Split2 (pos=midsld, badseq)",
        engine: "zapret",
        args: "--dpi-desync=split2 --dpi-desync-split-pos=midsld --dpi-desync-fooling=badseq",
        description: "Flowseal: split at middle of second-level domain."
    },
    {
        id: "fs_fake_split2_midsld_ttl8",
        name: "[Flowseal] Fake + Split2 (pos=midsld, TTL=8, badseq)",
        engine: "zapret",
        args: "--dpi-desync=fake,split2 --dpi-desync-split-pos=midsld --dpi-desync-ttl=8 --dpi-desync-fooling=badseq",
        description: "Flowseal ALT7: fake + split at midsld with TTL=8."
    },
    {
        id: "fs_md5sig_disorder_ttl4",
        name: "[Flowseal] Disorder2 + MD5Sig (TTL=4)",
        engine: "zapret",
        args: "--dpi-desync=disorder2 --dpi-desync-split-pos=1 --dpi-desync-ttl=4 --dpi-desync-fooling=md5sig",
        description: "Flowseal ALT8: MD5 signature fooling with disorder."
    },
    {
        id: "fs_badack_split_ttl6",
        name: "[Flowseal] Split2 + BadACK (TTL=6)",
        engine: "zapret",
        args: "--dpi-desync=split2 --dpi-desync-split-pos=2 --dpi-desync-ttl=6 --dpi-desync-fooling=badack",
        description: "Flowseal ALT9: BadACK fooling with split."
    },
    {
        id: "fs_fake_split2_seqovl_ttl4",
        name: "[Flowseal] Fake + Split2 + SeqOvl=1 (TTL=4, badseq)",
        engine: "zapret",
        args: "--dpi-desync=fake,split2 --dpi-desync-split-pos=1 --dpi-desync-split-seqovl=1 --dpi-desync-ttl=4 --dpi-desync-fooling=badseq",
        description: "Flowseal ALT10: fake + split with overlap at TTL=4."
    },
    {
        id: "fs_fake_disorder2_seqovl_ttl6",
        name: "[Flowseal] Fake + Disorder2 + SeqOvl=2 (TTL=6, badseq)",
        engine: "zapret",
        args: "--dpi-desync=fake,disorder2 --dpi-desync-split-pos=1 --dpi-desync-split-seqovl=2 --dpi-desync-ttl=6 --dpi-desync-fooling=badseq",
        description: "Flowseal ALT10: fake + disorder with overlap at TTL=6."
    },
    {
        id: "fs_split2_repeats12_ttl4",
        name: "[Flowseal] Split2 + Repeats=12 (TTL=4, badseq)",
        engine: "zapret",
        args: "--dpi-desync=split2 --dpi-desync-split-pos=2 --dpi-desync-repeats=12 --dpi-desync-ttl=4 --dpi-desync-fooling=badseq",
        description: "Flowseal ALT11: heavy burst at low TTL."
    },
    {
        id: "fs_fake_split2_repeats8_ttl8",
        name: "[Flowseal] Fake + Split2 + Repeats=8 (TTL=8, badseq)",
        engine: "zapret",
        args: "--dpi-desync=fake,split2 --dpi-desync-split-pos=1 --dpi-desync-repeats=8 --dpi-desync-ttl=8 --dpi-desync-fooling=badseq",
        description: "Flowseal ALT12: heavy burst fake+split at TTL=8."
    },
    {
        id: "fs_disorder2_ttl8_cutoff4",
        name: "[Flowseal] Disorder2 + TTL=8 + Cutoff=d4 (badseq)",
        engine: "zapret",
        args: "--dpi-desync=disorder2 --dpi-desync-split-pos=1 --dpi-desync-ttl=8 --dpi-desync-cutoff=d4 --dpi-desync-fooling=badseq",
        description: "Flowseal ALT13: disorder with cutoff after 4 data pkts."
    },
    {
        id: "fs_fake_split2_repeats6_ttl10",
        name: "[Flowseal] Fake + Split2 + Repeats=6 (TTL=10, badseq)",
        engine: "zapret",
        args: "--dpi-desync=fake,split2 --dpi-desync-split-pos=1 --dpi-desync-repeats=6 --dpi-desync-ttl=10 --dpi-desync-fooling=badseq",
        description: "Flowseal EXP: higher TTL for distant DPI."
    }
];

const STRATEGIES_BYEDPI = [
    // ── 1. COMBAT MULTI-SPLIT & LADDER CHAINS (Real TSPU Bypass) ───────────────
    {
        id: "bd_ladder_interleaved_10x",
        name: "Ultimate Multi-Split Ladder (10x SNI + Reverse + Drop-SACK)",
        engine: "byedpi",
        args: "-d1 -d3+s -s6+s -d9+s -s12+s -d15+s -s20+s -d25+s -s30+s -d35+s -r1+s -S -a1 -As",
        description: "10-stage interleaved split and disorder ladder across SNI offsets with reverse segment and SACK drop. Bypasses advanced stateful DPI reassembly."
    },
    {
        id: "bd_ladder_split_9x",
        name: "Staircase Split Ladder (9x SNI + Reverse + Drop-SACK)",
        engine: "byedpi",
        args: "-s1 -s3+s -s6+s -s9+s -s12+s -s15+s -s20+s -s25+s -s30+s -r1+s -S -a1",
        description: "Dense forward multi-split sequence along SNI with reverse disorder tail and SACK drop."
    },
    {
        id: "bd_ladder_disorder_8x",
        name: "Staircase Disorder Ladder (8x SNI + SACK Drop + Auto-s)",
        engine: "byedpi",
        args: "-d1 -d3+s -d6+s -d9+s -d12+s -d15+s -d20+s -d25+s -r1+s -S -As",
        description: "Out-of-order segment ladder across SNI payload prevents stateful DPI reassembly."
    },
    {
        id: "bd_ladder_fake_drop_t4",
        name: "Fake Ladder (TTL=4) + 4x SNI Step + Drop-SACK",
        engine: "byedpi",
        args: "-s1+s -d2+s -s3+s -d4+s -f-1 -t4 -r1+s -S -a1",
        description: "Low-TTL fake ClientHello burst followed by 4-step SNI fragmentation ladder."
    },
    {
        id: "bd_ladder_fake_drop_t6",
        name: "Fake Ladder (TTL=6) + 4x SNI Step + Drop-SACK",
        engine: "byedpi",
        args: "-s1+s -d2+s -s3+s -d4+s -f-1 -t6 -r1+s -S -a1 -As",
        description: "TTL=6 fake packet with stepped SNI offsets and reverse tail."
    },
    {
        id: "bd_ladder_fake_drop_t8",
        name: "Fake Ladder (TTL=8) + 4x SNI Step + Drop-SACK",
        engine: "byedpi",
        args: "-s1+s -d2+s -s3+s -d4+s -f-1 -t8 -r1+s -S -a1 -As",
        description: "TTL=8 fake packet with stepped SNI offsets."
    },
    {
        id: "bd_tlsrec_ladder",
        name: "TLS Record Fragment + SNI Ladder",
        engine: "byedpi",
        args: "--tlsrec 1+sniext -d1 -d3+s -s6+s -d9+s -r1+s -S -a1",
        description: "Fragments outer TLS Record header before SNI extension ladder."
    },
    {
        id: "bd_oob_ladder",
        name: "OOB Desync + SNI Ladder",
        engine: "byedpi",
        args: "-o 1 -q 1 -d1 -d3+s -s6+s -d9+s -r1+s -S -a1",
        description: "TCP Out-Of-Band URG flag with 4-step ladder."
    },
    {
        id: "bd_dense_staircase",
        name: "Dense Alternating Staircase (8-step) + Drop-SACK",
        engine: "byedpi",
        args: "-s1 -d2 -s3+s -d4+s -s5+s -d6+s -s7+s -d8+s -r1+s -S -As",
        description: "Alternating 1-byte split and disorder steps along SNI boundary."
    },
    {
        id: "bd_reverse_sni_combo",
        name: "Reverse SNI (-r 1+s) + Drop-SACK + Auto",
        engine: "byedpi",
        args: "-s 1 -d 1 -r 1+s -S --auto=r,s",
        description: "Reverses SNI chunks with auto fallback and SACK suppression."
    },

    // ── 2. CLASSIC & COMPATIBILITY SUITE ───────────────────────────────────────
    {
        id: "bd_auto_tr_d2",
        name: "ByeDPI Auto (t,r,a,s) + Disorder",
        engine: "byedpi",
        args: "-o 2 --auto=t,r,a,s -d 2",
        description: "Adaptive ByeDPI auto-mode with disorder and OOB."
    },
    {
        id: "bd_auto_tr_s1",
        name: "ByeDPI Auto (t,r,a,s) + Split",
        engine: "byedpi",
        args: "-o 1 --auto=t,r,a,s -s 1",
        description: "Adaptive ByeDPI auto-mode with 1-byte split."
    },
    {
        id: "bd_auto_drop_sack",
        name: "Auto (t,r,s) + Split 1 + Drop SACK",
        engine: "byedpi",
        args: "-s 1 -d 1 --auto=t,r,s --drop-sack",
        description: "Enforces drop-sack to prevent TCP SACK reassembly by DPI."
    },
    {
        id: "bd_disorder_fake_ttl8",
        name: "Disorder + Fake (TTL=8)",
        engine: "byedpi",
        args: "--split 1 --disorder 1 --fake -1 --ttl 8",
        description: "1-byte split with reverse disorder and fake handshake packet."
    },
    {
        id: "bd_disorder_fake_ttl6",
        name: "Disorder + Fake (TTL=6)",
        engine: "byedpi",
        args: "--split 1 --disorder 1 --fake -1 --ttl 6",
        description: "1-byte split with fake TTL=6 for intermediate hops."
    },
    {
        id: "bd_disorder_fake_ttl4",
        name: "Disorder + Fake (TTL=4)",
        engine: "byedpi",
        args: "--split 1 --disorder 1 --fake -1 --ttl 4",
        description: "1-byte split with low fake TTL=4."
    },
    {
        id: "bd_midsld_fake_frag_t6",
        name: "SNI Extension + Fake (TTL=6)",
        engine: "byedpi",
        args: "-s 1+sniext -f -1 -t 6",
        description: "SNI extension split with low-TTL fake payload."
    },
    {
        id: "bd_midsld_fake_frag_t8",
        name: "SNI Extension + Fake (TTL=8)",
        engine: "byedpi",
        args: "-s 1+sniext -f -1 -t 8",
        description: "SNI extension split with fake TTL=8."
    },
    {
        id: "bd_tls_sni_split2",
        name: "TLS SNI Split + Disorder (pos=2)",
        engine: "byedpi",
        args: "--split 2 --disorder 2",
        description: "Direct TLS SNI offset split with out-of-order delivery."
    },
    {
        id: "bd_tls_sni_split1",
        name: "TLS SNI Split + Disorder (pos=1)",
        engine: "byedpi",
        args: "--split 1 --disorder 1",
        description: "1-byte TLS ClientHello split with disorder."
    },
    {
        id: "bd_tlsrec_sniext",
        name: "TLS Record Split (1+sniext)",
        engine: "byedpi",
        args: "--tlsrec 1+sniext --split 1",
        description: "Fragments TLS Record header before SNI extension."
    },
    {
        id: "bd_fake_sni_disorder",
        name: "Fake SNI (-N) + Disorder",
        engine: "byedpi",
        args: "-N -s 1 -d 1 --auto=t,r,s",
        description: "Replaces SNI with fake random domain and disorders payload."
    },
    {
        id: "bd_ip_frag_24",
        name: "IP Fragmentation (24 bytes)",
        engine: "byedpi",
        args: "--ip-frag 24 --split 1",
        description: "Network layer IP fragmentation on 24-byte boundary."
    },
    {
        id: "bd_fake_sniext_disorder",
        name: "Aggressive Fake (TTL=8) + SNIExt",
        engine: "byedpi",
        args: "--fake -1 --ttl 8 --split 1+sniext --disorder 1",
        description: "Fake handshake with SNI extension split and disorder."
    },
    {
        id: "bd_aggressive_combo",
        name: "Aggressive Multi-Desync (-s 1 -d 1 -o 1 -q 1)",
        engine: "byedpi",
        args: "-s 1 -d 1 -o 1 -q 1 --auto=t,r,s --drop-sack",
        description: "Combines split, disorder, OOB, and drop-sack for tough censorship."
    }
];

const PRESETS_MIRRORS = [
    "https://raw.githubusercontent.com/Dushnilin/tachyon/main/tachyon/files/usr/share/tachyon/dpi-presets.json",
    "https://gh-proxy.com/https://raw.githubusercontent.com/Dushnilin/tachyon/main/tachyon/files/usr/share/tachyon/dpi-presets.json",
    "https://ghfast.top/https://raw.githubusercontent.com/Dushnilin/tachyon/main/tachyon/files/usr/share/tachyon/dpi-presets.json"
];

function validate_strategy_args(engine, args_val) {
    return fuzzer_runner.validate_strategy_args(engine, args_val);
}

function presets_file_candidates() {
    let list = [];
    if (getenv("TACHYON_PRESETS_FILE"))
        push(list, getenv("TACHYON_PRESETS_FILE"));
    push(list, "/usr/share/tachyon/dpi-presets.json");
    push(list, LIB_DIR + "/../share/tachyon/dpi-presets.json");
    return list;
}

function load_presets_file(path) {
    if (!path)
        return null;
    let data = read_json_file(path);
    if (!data || type(data) != "object")
        return null;
    return data;
}

function normalize_preset_entry(entry, engine) {
    if (!entry || type(entry) != "object")
        return null;
    let args = trim(as_string(entry.args));
    if (args == "")
        return null;
    let id = trim(as_string(entry.id));
    if (id == "") {
        _preset_autoid++;
        id = sprintf("preset_%s_%d", engine, _preset_autoid);
    }
    return {
        id: id,
        name: trim(as_string(entry.name)) || id,
        engine: engine,
        args: args,
        description: trim(as_string(entry.description)),
        source: trim(as_string(entry.source)) || "builtin",
        tags: type(entry.tags) == "array" ? entry.tags : [],
        requires_blobs: entry.requires_blobs ? entry.requires_blobs : []
    };
}

function load_builtin_presets() {
    if (_builtin_presets_cache != null)
        return _builtin_presets_cache;

    let result = { zapret2: [], zapret: [], byedpi: [] };
    let sources = [];
    for (let p in presets_file_candidates()) {
        let data = load_presets_file(p);
        if (data) {
            push(sources, data);
            break;
        }
    }
    let user_data = load_presets_file(USER_PRESETS_FILE);
    if (user_data)
        push(sources, user_data);

    let seen = {};
    for (let data in sources) {
        for (let engine in [ "zapret2", "zapret", "byedpi" ]) {
            let list = data[engine];
            if (type(list) != "array")
                continue;
            let target_list = result[engine];
            for (let raw in list) {
                let entry = normalize_preset_entry(raw, engine);
                if (entry == null)
                    continue;
                if (seen[entry.id])
                    continue;
                seen[entry.id] = true;
                push(target_list, entry);
            }
        }
    }

    _builtin_presets_cache = result;
    return result;
}

function reset_presets_cache() {
    _builtin_presets_cache = null;
}

function preset_blobs_available(entry) {
    if (entry == null || type(entry.requires_blobs) != "array" || length(entry.requires_blobs) == 0)
        return true;
    let dirs = [
        "/opt/zapret2/files/fake",
        "/opt/zapret/files/fake",
        "/usr/share/zapret2/files/fake",
        "/usr/share/zapret/files/fake",
        LIB_DIR + "/providers/zapret2/files/fake"
    ];
    for (let blob in entry.requires_blobs) {
        let found = false;
        for (let d in dirs) {
            if (fs.stat(d + "/" + blob) != null) {
                found = true;
                break;
            }
        }
        if (!found)
            return false;
    }
    return true;
}

function get_patterns_config() {
    let custom = read_json_file(PATTERNS_FILE);
    if (custom && type(custom) == "object") {
        return {
            zapret2: custom.zapret2 || DEFAULT_PATTERNS.zapret2,
            zapret: custom.zapret || DEFAULT_PATTERNS.zapret,
            byedpi: custom.byedpi || DEFAULT_PATTERNS.byedpi,
            custom_strategies: custom.custom_strategies || []
        };
    }
    return DEFAULT_PATTERNS;
}

function save_patterns_config(cfg_obj) {
    if (!cfg_obj || type(cfg_obj) != "object") {
        print(sprintf("%J\n", { success: false, error: "Invalid patterns configuration object" }));
        return;
    }
    common.ensure_dir("/etc/tachyon");
    write_json_file(PATTERNS_FILE, cfg_obj);
    print(sprintf("%J\n", { success: true, message: "Patterns configuration saved successfully" }));
}

function reset_patterns_config() {
    try { fs.unlink(PATTERNS_FILE); } catch(e) {}
    print(sprintf("%J\n", { success: true, message: "Patterns configuration reset to factory defaults", patterns: DEFAULT_PATTERNS }));
}

function generate_combinatorial_zapret2() {
    let cfg = get_patterns_config();
    let p = cfg.zapret2 || DEFAULT_PATTERNS.zapret2;
    let list = [];
    let seen = {};
    
    let add = function(name, args, desc) {
        args = trim(as_string(args));
        if (args == "" || seen[args]) return;
        if (!fuzzer_runner.validate_strategy_args("zapret2", args)) return;
        seen[args] = true;
        push(list, {
            id: sprintf("z2_comb_%d", length(list) + 1),
            name: name,
            engine: "zapret2",
            args: args,
            description: desc
        });
    };
    
    for (let s in STRATEGIES_ZAPRET2) add(s.name, s.args, s.description);
    
    if (cfg.custom_strategies && length(cfg.custom_strategies) > 0) {
        for (let cs in cfg.custom_strategies) {
            if (cs && cs.engine == "zapret2" && cs.args) {
                add(cs.name || "Custom Zapret v2", cs.args, cs.description || "User custom strategy");
            }
        }
    }
    
    let splits = p.splits || [ "1", "2", "3", "midsld", "sniext+2", "sniext+4", "1,midsld", "1,sniext+2" ];
    let foolings = p.foolings || [ "badseq", "md5sig", "badack", "datanoack", "fakeddrop" ];
    let ttls = p.ttls || [ 2, 3, 4, 5, 6, 8 ];
    let seqovls = p.seqovls || [ "1", "2" ];
    let wsizes = p.wsizes || [ "1" ];
    let blobs = p.blobs || [ "tls_max", "tls_google", "tls_gosuslugi", "tls_sber", "tls_iana" ];
    let repeats_list = p.repeats || [ 6, 8 ];
    
    // 1. Multisplit combinations
    for (let pos in splits) {
        for (let fooling in foolings) {
            add(sprintf("Multisplit (pos=%s, %s)", pos, fooling),
                sprintf("--lua-desync=multisplit:pos=%s:fooling=%s", pos, fooling),
                "Multisplit position and fooling method");
        }
        for (let sq in seqovls) {
            add(sprintf("Multisplit + SeqOvl %s (pos=%s, badseq)", sq, pos),
                sprintf("--lua-desync=multisplit:pos=%s:seqovl=%s:fooling=badseq", pos, sq),
                "Multisplit with sequence overlap");
        }
        for (let w in wsizes) {
            add(sprintf("Multisplit + Window %s (pos=%s, badseq)", w, pos),
                sprintf("--lua-desync=multisplit:pos=%s:wsize=%s:fooling=badseq", pos, w),
                "Multisplit with TCP window size clamping");
        }
    }
    
    // 2. Multidisorder combinations
    for (let pos in [ "2", "midsld", "1,midsld" ]) {
        for (let fooling in [ "badseq", "md5sig", "badack" ]) {
            add(sprintf("Multidisorder (pos=%s, %s)", pos, fooling),
                sprintf("--lua-desync=multidisorder:pos=%s:fooling=%s", pos, fooling),
                "Out-of-order segment delivery with fooling");
        }
    }
    
    // 3. PAWS Timestamp Spoofing with Authentic Blobs (Top-tier TSPU evasion)
    for (let blob in blobs) {
        for (let rep in repeats_list) {
            for (let pos in [ "1", "1,midsld", "midsld" ]) {
                add(sprintf("Fake PAWS (%s, rep=%d) + Multisplit (pos=%s)", blob, rep, pos),
                    sprintf("--lua-desync=fake:blob=%s:repeats=%d:tcp_ts=-600000:tcp_ts_up --lua-desync=multisplit:pos=%s", blob, rep, pos),
                    "PAWS ancient TCP timestamp spoofing with authentic ClientHello blob");
                let dis_pos = (pos == "1") ? "2" : pos;
                add(sprintf("Fake PAWS (%s, rep=%d) + Multidisorder (pos=%s)", blob, rep, dis_pos),
                    sprintf("--lua-desync=fake:blob=%s:repeats=%d:tcp_ts=-600000:tcp_ts_up --lua-desync=multidisorder:pos=%s", blob, rep, dis_pos),
                    "PAWS ancient TCP timestamp spoofing with multidisorder segments");
            }
        }
    }
    
    // 4. Exact SeqOvl Pattern Overlaps
    let blob_patterns = [
        { name: "tls_max", size: 664 },
        { name: "tls_google", size: 681 },
        { name: "tls_gosuslugi", size: 517 },
        { name: "tls_sber", size: 517 }
    ];
    for (let bp in blob_patterns) {
        add(sprintf("SeqOvl Pattern %s (%d B, pos=1)", bp.name, bp.size),
            sprintf("--lua-desync=multisplit:pos=1:seqovl=%d:seqovl_pattern=%s", bp.size, bp.name),
            "Sequence overlap filled with authentic ClientHello pattern");
        add(sprintf("Fake PAWS (%s) + SeqOvl Pattern (%d B)", bp.name, bp.size),
            sprintf("--lua-desync=fake:blob=%s:repeats=8:tcp_ts=-600000:tcp_ts_up --lua-desync=multisplit:pos=1:seqovl=%d:seqovl_pattern=%s", bp.name, bp.size, bp.name),
            "Combined PAWS fake burst and pattern sequence overlap");
    }
    
    // 5. TCP SYN Data combinations
    for (let pos in [ "1", "1,midsld", "midsld" ]) {
        let dis_pos = (pos == "1") ? "2" : pos;
        add(sprintf("SYN Data + Multidisorder (pos=%s)", dis_pos),
            sprintf("--lua-desync=syndata --lua-desync=multidisorder:pos=%s", dis_pos),
            "TCP SYN data payload with out-of-order data segments");
        add(sprintf("SYN Data + Multisplit (pos=%s, seqovl=1)", pos),
            sprintf("--lua-desync=syndata --lua-desync=multisplit:pos=%s:seqovl=1:fooling=badseq", pos),
            "TCP SYN data payload with multisplit sequence overlap");
        add(sprintf("SYN Data + Window Clamp (wsize=1, pos=%s)", pos),
            sprintf("--lua-desync=syndata --lua-desync=multisplit:pos=%s:wsize=1:fooling=badseq", pos),
            "TCP SYN data payload with 1-byte window clamp");
    }
    
    // 6. Low-TTL Fake combinations
    for (let ttl in ttls) {
        for (let fooling in [ "badseq", "md5sig", "badack" ]) {
            for (let pos in [ "1", "1,midsld", "midsld" ]) {
                add(sprintf("Fake (TTL=%d, %s) + Multisplit (pos=%s)", ttl, fooling, pos),
                    sprintf("--lua-desync=fake:ttl=%d:fooling=%s --lua-desync=multisplit:pos=%s", ttl, fooling, pos),
                    "Low-TTL fake injection followed by multisplit payload");
                let dis_pos = (pos == "1") ? "2" : pos;
                add(sprintf("Fake (TTL=%d, %s) + Multidisorder (pos=%s)", ttl, fooling, dis_pos),
                    sprintf("--lua-desync=fake:ttl=%d:fooling=%s --lua-desync=multidisorder:pos=%s", ttl, fooling, dis_pos),
                    "Low-TTL fake injection followed by multidisorder payload");
            }
        }
    }
    
    // 7. Fakedsplit, Fakeddisorder & Hostfakesplit
    for (let pos in [ "1", "1,midsld", "midsld" ]) {
        add(sprintf("Fakedsplit (pos=%s, badseq)", pos),
            sprintf("--lua-desync=fakedsplit:pos=%s:fooling=badseq", pos),
            "Stream splitting with embedded fake packets");
        let dis_pos = (pos == "1") ? "2" : pos;
        add(sprintf("Fakeddisorder (pos=%s, badseq)", dis_pos),
            sprintf("--lua-desync=fakeddisorder:pos=%s:fooling=badseq", dis_pos),
            "Out-of-order stream with embedded fake fragments");
        add(sprintf("Hostfakesplit (pos=%s, badseq)", pos),
            sprintf("--lua-desync=hostfakesplit:pos=%s:fooling=badseq", pos),
            "Host header substitution in initial packet");
    }

    // 8. Blockcheck2 & Blockcheckw Heavy Multi-Split Chains
    let multi_chains = [
        "1,sniext+1,host+1,midsld-2,midsld,midsld+2,endhost-1",
        "1,midsld,1220",
        "1,sniext+1,host+1",
        "10,sniext+4"
    ];
    for (let chain in multi_chains) {
        add(sprintf("7-Point MultiSplit (%s)", chain),
            sprintf("--payload=tls_client_hello --lua-desync=multisplit:pos=%s", chain),
            "Full-spectrum ClientHello multisplit fragmentation");
        add(sprintf("7-Point MultiDisorder (%s)", chain),
            sprintf("--payload=tls_client_hello --lua-desync=multidisorder:pos=%s", chain),
            "Full-spectrum ClientHello multidisorder fragmentation");
    }

    // 9. TCP Segmentation & OOB combinations
    for (let rep in [ 20, 100, 260 ]) {
        add(sprintf("TCPSegment (repeats=%d, pos=0,1)", rep),
            sprintf("--payload=tls_client_hello --lua-desync=tcpseg:pos=0,1:ip_id=rnd:repeats=%d", rep),
            "Randomized IP-ID TCP segmentation burst");
        add(sprintf("TCPSegment (repeats=%d, midsld)", rep),
            sprintf("--payload=tls_client_hello --lua-desync=tcpseg:pos=0,midsld:ip_id=rnd:repeats=%d", rep),
            "Mid-SLD TCP segmentation burst");
    }

    for (let urp in [ "midsld", "b", "2" ]) {
        add(sprintf("OOB Desync (urp=%s)", urp),
            sprintf("--in-range=-s1 --lua-desync=oob:urp=%s", urp),
            "TCP Out-Of-Band URG packet with urgent pointer offset");
    }

    // 10. Advanced TCP flag & ACK offsets with authentic blobs
    for (let blob in [ "tls_max", "tls_google" ]) {
        add(sprintf("TCP ACK Offset (-66000, %s)", blob),
            sprintf("--payload=tls_client_hello --lua-desync=fake:blob=%s:tcp_ack=-66000:tcp_ts_up:repeats=6", blob),
            "Corrupted TCP ACK offset with PAWS ascending timestamps");
        add(sprintf("TCP Flags Unset ACK (%s)", blob),
            sprintf("--payload=tls_client_hello --lua-desync=fake:blob=%s:tcp_flags_unset=ACK:repeats=6", blob),
            "Fake packets with ACK flag cleared");
        add(sprintf("BadSum Checksum Invalidation (%s)", blob),
            sprintf("--payload=tls_client_hello --lua-desync=fake:blob=%s:badsum:repeats=6", blob),
            "Corrupted L4 checksum fake packets");
        add(sprintf("Auto-TTL Adaptive Probe (%s, autottl=-1,3-20)", blob),
            sprintf("--payload=tls_client_hello --lua-desync=fake:blob=%s:ip_autottl=-1,3-20:repeats=6", blob),
            "Adaptive distance TTL calculation before DPI hop");
    }
    
    return list;
}

function generate_combinatorial_zapret() {
    let cfg = get_patterns_config();
    let p = cfg.zapret || DEFAULT_PATTERNS.zapret;
    let list = [];
    let seen = {};
    
    let add = function(name, args, desc) {
        args = trim(as_string(args));
        if (args == "" || seen[args]) return;
        if (!fuzzer_runner.validate_strategy_args("zapret", args)) return;
        seen[args] = true;
        push(list, {
            id: sprintf("z1_gen_%d", length(list) + 1),
            name: name,
            engine: "zapret",
            args: args,
            description: desc
        });
    };
    
    for (let s in STRATEGIES_ZAPRET) add(s.name, s.args, s.description);
    for (let s in STRATEGIES_FLOWSEAL) add(s.name, s.args, s.description);
    
    if (cfg.custom_strategies && length(cfg.custom_strategies) > 0) {
        for (let cs in cfg.custom_strategies) {
            if (cs && cs.engine == "zapret" && cs.args) {
                add(cs.name || "Custom Zapret v1", cs.args, cs.description || "User custom strategy");
            }
        }
    }
    
    let modes = p.split_modes || [ "split2", "disorder2", "fake,split2", "fake,disorder2" ];
    let positions = p.splits || [ "1", "2", "midsld" ];
    
    for (let mode in modes) {
        for (let pos in positions) {
            for (let fooling in [ "badseq", "md5sig", "badack" ]) {
                if (index(mode, "fake") >= 0) {
                    for (let ttl in [ 3, 4, 8 ]) {
                        add(sprintf("%s (pos=%s, TTL=%d, %s)", mode, pos, ttl, fooling),
                            sprintf("--dpi-desync=%s --dpi-desync-split-pos=%s --dpi-desync-ttl=%d --dpi-desync-fooling=%s", mode, pos, ttl, fooling),
                            "Fake desync with split pos and fooling");
                    }
                } else {
                    add(sprintf("%s (pos=%s, %s)", mode, pos, fooling),
                        sprintf("--dpi-desync=%s --dpi-desync-split-pos=%s --dpi-desync-fooling=%s", mode, pos, fooling),
                        "Desync with split pos and fooling");
                }
            }
        }
    }
    
    return list;
}

function generate_combinatorial_byedpi() {
    let cfg = get_patterns_config();
    let p = cfg.byedpi || DEFAULT_PATTERNS.byedpi;
    let list = [];
    let seen = {};
    
    let add = function(name, args, desc) {
        args = trim(as_string(args));
        if (args == "" || seen[args]) return;
        if (!fuzzer_runner.validate_strategy_args("byedpi", args)) return;
        seen[args] = true;
        push(list, {
            id: sprintf("bd_gen_%d", length(list) + 1),
            name: name,
            engine: "byedpi",
            args: args,
            description: desc
        });
    };
    
    for (let s in STRATEGIES_BYEDPI) add(s.name, s.args, s.description);
    
    if (cfg.custom_strategies && length(cfg.custom_strategies) > 0) {
        for (let cs in cfg.custom_strategies) {
            if (cs && cs.engine == "byedpi" && cs.args) {
                add(cs.name || "Custom ByeDPI", cs.args, cs.description || "User custom strategy");
            }
        }
    }
    
    let splits = p.splits || [ "1", "2", "1+sniext", "midsld" ];
    let disorders = p.disorders || [ "1", "2" ];
    let oobs = p.oobs || [ "1", "2" ];
    let autos = p.autos || [ "t,r,a,s", "r,s", "t,a" ];
    
    // 1. Classic adaptive combinations
    for (let a in autos) {
        for (let o in oobs) {
            for (let d in disorders) {
                add(sprintf("Auto (%s) + OOB=%s + Disorder=%s", a, o, d),
                    sprintf("-o %s --auto=%s -d %s", o, a, d),
                    "Adaptive auto mode with OOB and disorder");
            }
            for (let s in splits) {
                add(sprintf("Auto (%s) + OOB=%s + Split=%s", a, o, s),
                    sprintf("-o %s --auto=%s -s %s", o, a, s),
                    "Adaptive auto mode with OOB and split");
            }
        }
    }
    
    // 2. Fake with split & disorder
    for (let ttl in [ 3, 4, 8 ]) {
        for (let s in [ "1", "1+sniext", "midsld" ]) {
            for (let d in [ "1", "2" ]) {
                add(sprintf("Split=%s + Disorder=%s + Fake (TTL=%d)", s, d, ttl),
                    sprintf("--split %s --disorder %s --fake -1 --ttl %d", s, d, ttl),
                    "Fake injection with split and disorder");
            }
        }
    }

    // 3. Multi-split ladder chains (Combinatorial combat suites)
    let ladder_bases = [
        { name: "Ladder 3-Step", args: "-d1 -d3+s -s6+s" },
        { name: "Ladder 5-Step", args: "-d1 -d3+s -s6+s -d9+s -s12+s" },
        { name: "Ladder 8-Step", args: "-d1 -d3+s -s6+s -d9+s -s12+s -d15+s -s20+s -d25+s" },
        { name: "Ladder 10-Step", args: "-d1 -d3+s -s6+s -d9+s -s12+s -d15+s -s20+s -d25+s -s30+s -d35+s" },
        { name: "Split Ladder 6-Step", args: "-s1 -s3+s -s6+s -s9+s -s12+s -s15+s" },
        { name: "Disorder Ladder 6-Step", args: "-d1 -d3+s -d6+s -d9+s -d12+s -d15+s" }
    ];

    let reverse_tails = [ "", " -r1+s", " -r2+s" ];
    let sack_options = [ " -S", "" ];
    let auto_tails = [ " -a1 -As", " -a1", " --auto=r,s", "" ];

    for (let lb in ladder_bases) {
        for (let rt in reverse_tails) {
            for (let so in sack_options) {
                for (let at in auto_tails) {
                    let comb_args = trim(sprintf("%s%s%s%s", lb.args, rt, so, at));
                    add(sprintf("%s%s%s%s", lb.name, rt != "" ? " + Rev" : "", so != "" ? " + SACK" : "", at != "" ? " + Auto" : ""),
                        comb_args,
                        "Multi-stage ladder split & disorder chain for resilient DPI bypass");
                }
            }
        }
    }

    // 4. Fake packet with multi-split ladder
    for (let ttl in [ 3, 4, 6, 8 ]) {
        add(sprintf("Fake (TTL=%d) + 4-Step Ladder + SACK Drop", ttl),
            sprintf("-s1+s -d2+s -s3+s -d4+s -f-1 -t%d -r1+s -S -a1", ttl),
            "Fake handshake packet followed by 4-step SNI ladder and SACK suppression");
        add(sprintf("Fake (TTL=%d) + TLS Record Split + SACK Drop", ttl),
            sprintf("--tlsrec 1+sniext -s1+s -d2+s -f-1 -t%d -S -a1", ttl),
            "TLS record boundary split with fake packet and SACK drop");
    }
    
    return list;
}

function generate_adaptive_strategies(engine, target) {
    let list = [];
    let seen = {};

    let add = function(name, args, desc, rationale) {
        args = trim(as_string(args));
        if (args == "" || seen[args]) return;
        if (!fuzzer_runner.validate_strategy_args(engine == "all" ? "zapret2" : engine, args)) return;
        seen[args] = true;
        push(list, {
            id: sprintf("adapt_%s_%d", engine, length(list) + 1),
            name: name,
            engine: engine == "all" ? "zapret2" : engine,
            args: args,
            description: desc || "Adaptive evolved strategy",
            rationale: rationale || "Synthesized from parameter attribution and target profile"
        });
    };

    // 1. Seed from Prior History: inject historic winning strategies for this target & engine
    let history_res = history.get_history(20);
    if (history_res && length(history_res) > 0) {
        for (let h in history_res) {
            if (h && h.target == target && h.best_strategy && (engine == "all" || h.engine == engine)) {
                let bs = h.best_strategy;
                if (bs.args && !seen[bs.args]) {
                    add("⭐ Prior Winner: " + (bs.name || "Historical Best"), bs.args, "Previously verified effective on this target", "Historical success seed");
                }
            }
        }
    }

    // 2. High-probability domain seeds based on engine
    if (engine == "zapret2" || engine == "all") {
        for (let blob in [ "tls_max", "tls_google", "tls_gosuslugi", "tls_sber" ]) {
            let seq = (blob == "tls_max") ? 664 : (blob == "tls_google" ? 681 : 517);
            add(sprintf("PAWS (%s) + Multisplit pos=1", blob),
                sprintf("--lua-desync=fake:blob=%s:repeats=8:tcp_ts=-600000:tcp_ts_up --lua-desync=multisplit:pos=1:seqovl=%d:seqovl_pattern=%s", blob, seq, blob),
                "PAWS timestamp desync with authentic blob overlap");
            add(sprintf("PAWS (%s) + Multisplit pos=1,midsld", blob),
                sprintf("--lua-desync=fake:blob=%s:repeats=6:tcp_ts=-600000:tcp_ts_up --lua-desync=multisplit:pos=1,midsld:seqovl=%d:seqovl_pattern=%s", blob, seq, blob),
                "PAWS with midsld multisplit");
        }
        add("SYN Data + Multisplit pos=1,midsld (badseq)",
            "--lua-desync=syndata --lua-desync=multisplit:pos=1,midsld:seqovl=1:fooling=badseq",
            "TCP SYN payload injection with badseq fooling");
        add("SYN Data + Multidisorder pos=1,midsld",
            "--lua-desync=syndata --lua-desync=multidisorder:pos=1,midsld",
            "TCP SYN payload injection with segment disordering");
        add("SYN Data + Window Clamp wsize=1",
            "--lua-desync=syndata --lua-desync=multisplit:pos=1,midsld:wsize=1",
            "SYN data injection with 1-byte TCP window clamping");
        for (let fooling in [ "badseq", "fakeddrop", "badack" ]) {
            for (let ttl in [ 3, 4, 6 ]) {
                for (let pos in [ "1", "1,midsld", "sniext+4" ]) {
                    add(sprintf("Fake (%s, ttl=%d) + Multisplit %s", fooling, ttl, pos),
                        sprintf("--lua-desync=fake:blob=tls_max:repeats=6:ttl=%d:fooling=%s --lua-desync=multisplit:pos=%s", ttl, fooling, pos),
                        "Evolved fake desync parameter combination");
                }
            }
        }
    }

    if (engine == "zapret" || engine == "all") {
        for (let split_mode in [ "split2", "fake,split2", "disorder2", "fake,disorder2" ]) {
            for (let ttl in [ 2, 3, 4, 6, 8 ]) {
                for (let pos in [ "1", "2", "midsld", "sniext+4" ]) {
                    let fooling = index(split_mode, "fake") >= 0 ? " --dpi-desync-fooling=badseq" : "";
                    add(sprintf("%s (pos=%s, ttl=%d)", split_mode, pos, ttl),
                        sprintf("--dpi-desync=%s --dpi-desync-split-pos=%s --dpi-desync-ttl=%d%s", split_mode, pos, ttl, fooling),
                        "Adaptive parameter combination for Zapret v1");
                }
            }
        }
    }

    if (engine == "byedpi" || engine == "all") {
        for (let a in [ "t,r,a,s", "r,s", "t,a" ]) {
            for (let o in [ "1", "2" ]) {
                for (let d in [ "1", "2" ]) {
                    add(sprintf("Auto (%s) + OOB %s + Disorder %s", a, o, d),
                        sprintf("-o %s --auto=%s -d %s", o, a, d),
                        "Adaptive auto mode with OOB and disorder");
                }
                for (let s in [ "1", "1+sniext", "midsld" ]) {
                    add(sprintf("Auto (%s) + OOB %s + Split %s", a, o, s),
                        sprintf("-o %s --auto=%s -s %s", o, a, s),
                        "Adaptive auto mode with OOB and split");
                }
            }
        }
        for (let ttl in [ 3, 4, 8 ]) {
            for (let s in [ "1", "1+sniext", "midsld" ]) {
                add(sprintf("Fake (TTL=%d) + Split %s", ttl, s),
                    sprintf("--split %s --fake -1 --ttl %d", s, ttl),
                    "ByeDPI fake injection with split");
            }
        }
    }

    // Check memory budget: if low RAM (<32MB), cap to 20 strategies
    let avail_kb = fuzzer_runner.get_system_memory_kb();
    if (avail_kb < 32768 && length(list) > 20) {
        let capped = [];
        for (let i = 0; i < 20; i++) push(capped, list[i]);
        return capped;
    }

    return list;
}

function get_strategies_for_engine(engine, mode, target) {
    engine = lc(as_string(engine));
    mode = lc(trim(as_string(mode || "presets")));
    let cfg = get_patterns_config();
    
    if (mode == "custom" || mode == "user") {
        let custom_list = [];
        for (let cs in cfg.custom_strategies) {
            if (cs && (engine == "all" || cs.engine == engine) && cs.args) {
                push(custom_list, {
                    id: cs.id || sprintf("custom_%d", length(custom_list) + 1),
                    name: cs.name || "Custom Strategy",
                    engine: cs.engine || engine,
                    args: cs.args,
                    description: cs.description || ""
                });
            }
        }
        return custom_list;
    }

    if (mode == "adaptive" || mode == "smart") {
        return generate_adaptive_strategies(engine, target || "youtube_suite");
    }
    
    if (mode == "combinatorial" || mode == "deep_fuzz" || mode == "deep") {
        let combo = [];
        if (engine == "zapret2") combo = generate_combinatorial_zapret2();
        else if (engine == "zapret") combo = generate_combinatorial_zapret();
        else if (engine == "byedpi") combo = generate_combinatorial_byedpi();
        else if (engine == "all") {
            for (let s in generate_combinatorial_zapret2()) push(combo, s);
            for (let s in generate_combinatorial_zapret()) push(combo, s);
            for (let s in generate_combinatorial_byedpi()) push(combo, s);
        }

        let avail_kb = fuzzer_runner.get_system_memory_kb();
        if (avail_kb < 32768 && length(combo) > 30) {
            let capped = [];
            for (let i = 0; i < 30; i++) push(capped, combo[i]);
            return capped;
        }
        return combo;
    }
    
    let has_z2 = binaries.get_zapret2_bin() != null;
    let has_z1 = binaries.get_zapret_bin() != null;
    let has_bd = binaries.get_byedpi_bin() != null;

    let base = [];
    if (engine == "zapret2") base = STRATEGIES_ZAPRET2;
    else if (engine == "zapret") { base = []; for (let s in STRATEGIES_ZAPRET) push(base, s); for (let s in STRATEGIES_FLOWSEAL) push(base, s); }
    else if (engine == "byedpi") base = STRATEGIES_BYEDPI;
    else if (engine == "all") {
        if (has_z2) for (let s in STRATEGIES_ZAPRET2) push(base, s);
        if (has_z1) { for (let s in STRATEGIES_ZAPRET) push(base, s); for (let s in STRATEGIES_FLOWSEAL) push(base, s); }
        if (has_bd) for (let s in STRATEGIES_BYEDPI) push(base, s);
    }
    
    let result = [];
    let seen_args = {};

    // Seed prior winners from history if available
    let history_res = history.get_history(10);
    if (history_res && length(history_res) > 0) {
        for (let h in history_res) {
            if (h && target && h.target == target && h.best_strategy && (engine == "all" || h.engine == engine)) {
                let bs = h.best_strategy;
                if (bs.args && !seen_args[bs.args]) {
                    seen_args[bs.args] = true;
                    push(result, {
                        id: sprintf("hist_%s_1", bs.engine || engine),
                        name: "⭐ " + (bs.name || "Historical Best"),
                        engine: bs.engine || engine,
                        args: bs.args,
                        description: "Previously verified winner on this target"
                    });
                }
            }
        }
    }

    for (let s in base) {
        if (!seen_args[s.args]) {
            seen_args[s.args] = true;
            push(result, s);
        }
    }

    // Curated presets from external sources (zapret4rocket, homeproxy-hiddify)
    let presets = load_builtin_presets();
    let preset_engines = [];
    if (engine == "all") {
        if (has_z2) push(preset_engines, "zapret2");
        if (has_z1) push(preset_engines, "zapret");
        if (has_bd) push(preset_engines, "byedpi");
    } else {
        push(preset_engines, engine);
    }
    for (let eng in preset_engines) {
        let list = presets[eng];
        if (type(list) != "array")
            continue;
        for (let p in list) {
            if (p.args == "" || seen_args[p.args])
                continue;
            if (!fuzzer_runner.validate_strategy_args(p.engine, p.args))
                continue;
            if (!preset_blobs_available(p))
                continue;
            seen_args[p.args] = true;
            push(result, {
                id: p.id,
                name: p.name,
                engine: p.engine,
                args: p.args,
                description: p.description,
                source: p.source,
                tags: p.tags
            });
        }
    }

    for (let cs in cfg.custom_strategies) {
        if (cs && (engine == "all" || cs.engine == engine) && cs.args && !seen_args[cs.args]) {
            seen_args[cs.args] = true;
            push(result, {
                id: cs.id || sprintf("custom_%d", length(result) + 1),
                name: cs.name || "Custom Strategy",
                engine: cs.engine || engine,
                args: cs.args,
                description: cs.description || "User custom strategy"
            });
        }
    }
    
    return result;
}

function get_presets_info() {
    reset_presets_cache();
    let presets = load_builtin_presets();
    let sources = {};
    let tags = {};
    let counts = {};
    for (let engine in [ "zapret2", "zapret", "byedpi" ]) {
        counts[engine] = 0;
        let list = presets[engine];
        if (type(list) != "array")
            continue;
        for (let p in list) {
            counts[engine]++;
            sources[p.source] = true;
            for (let t in p.tags)
                tags[t] = true;
        }
    }
    let source_list = [];
    for (let s, _v in sources)
        push(source_list, s);
    let tag_list = [];
    for (let t, _v in tags)
        push(tag_list, t);
    return {
        success: true,
        counts: counts,
        sources: source_list,
        tags: tag_list,
        user_presets_file: USER_PRESETS_FILE,
        builtin_presets_file: BUILTIN_PRESETS_FILE
    };
}

function update_presets() {
    let tmp = "/tmp/tachyon-presets-download.json";
    let downloaded = false;
    let last_err = "";
    for (let url in PRESETS_MIRRORS) {
        try { fs.unlink(tmp); } catch (e) {}
        let rc = system(sprintf("curl -fsSL --connect-timeout 10 --max-time 30 -o %s %s >/dev/null 2>&1",
            shell_quote(tmp), shell_quote(url)));
        if (rc == 0 && fs.stat(tmp) != null) {
            let parsed = read_json_file(tmp);
            if (parsed && type(parsed) == "object") {
                downloaded = true;
                break;
            }
            last_err = "Downloaded presets file is not valid JSON";
        } else {
            last_err = "Failed to download presets from mirror";
        }
    }
    try { fs.unlink(tmp); } catch (e) {}
    if (!downloaded) {
        print(sprintf("%J\n", { success: false, error: last_err || "All preset mirrors failed" }));
        return;
    }
    print(sprintf("%J\n", {
        success: true,
        message: "Built-in presets are shipped with the package; update the tachyon package to refresh them",
        user_presets_file: USER_PRESETS_FILE
    }));
}

function module_exports() {
    return {
        DEFAULT_PATTERNS,
        STRATEGIES_ZAPRET2,
        STRATEGIES_ZAPRET,
        STRATEGIES_FLOWSEAL,
        STRATEGIES_BYEDPI,
        PATTERNS_FILE,
        BUILTIN_PRESETS_FILE,
        USER_PRESETS_FILE,
        PRESETS_MIRRORS,
        presets_file_candidates,
        load_presets_file,
        normalize_preset_entry,
        load_builtin_presets,
        reset_presets_cache,
        preset_blobs_available,
        get_patterns_config,
        save_patterns_config,
        reset_patterns_config,
        generate_combinatorial_zapret2,
        generate_combinatorial_zapret,
        generate_combinatorial_byedpi,
        generate_adaptive_strategies,
        get_strategies_for_engine,
        get_presets_info,
        update_presets
    };
}

if ((sourcepath(1) != null && sourcepath(1) != "") || ARGV[0] == null)
    return module_exports();

print("Usage: diagnostics/fuzzer/strategies.uc (library module, no CLI)
");
exit(1);
