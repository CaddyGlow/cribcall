use allo_isolate::Isolate;
use base64::{engine::general_purpose::STANDARD as BASE64, Engine as _};
use dashmap::DashMap;
use log::{error, info, warn};
use once_cell::sync::OnceCell;
use rand::{rngs::OsRng, RngCore};
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet};
use std::ffi::{CStr, CString};
use std::net::{SocketAddr, UdpSocket};
use std::os::raw::{c_char, c_void};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

const CONTROL_ALPN: &[u8] = b"cribcall-ctrl";
const DEFAULT_IDLE_TIMEOUT_MS: u64 = 30_000;
const DEFAULT_MAX_UDP_PAYLOAD: usize = 1350;
const DEFAULT_STREAM_WINDOW: u64 = 1_048_576; // 1 MiB baseline until tuned.
const CONTROL_STREAM_ID: u64 = 0;
const MAX_DATAGRAM_SIZE: usize = 1350;

#[repr(C)]
pub struct CcQuicConfig {
    inner: quiche::Config,
}

#[repr(C)]
#[derive(Copy, Clone, Debug, Eq, PartialEq)]
pub enum CcQuicStatus {
    Ok = 0,
    NullPointer = 1,
    ConfigError = 2,
    InvalidAlpn = 3,
    CertLoadError = 4,
    SocketError = 5,
    HandshakeError = 6,
    EventSendError = 7,
    Internal = 255,
}

impl CcQuicStatus {
    const fn code(self) -> i32 {
        self as i32
    }
}

#[derive(Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum QuicEvent {
    Connected {
        handle: u64,
        connection_id: String,
        peer_fingerprint: String,
    },
    Message {
        handle: u64,
        connection_id: String,
        data_base64: String,
    },
    Closed {
        handle: u64,
        connection_id: String,
        reason: Option<String>,
    },
    Error {
        handle: u64,
        connection_id: Option<String>,
        message: String,
    },
}

#[derive(Debug)]
enum WorkerCommand {
    Send { conn_id: Vec<u8>, payload: Vec<u8> },
    Close { conn_id: Option<Vec<u8>> },
}

struct ConnectionHandle {
    tx: mpsc::Sender<WorkerCommand>,
}

static NEXT_HANDLE: AtomicU64 = AtomicU64::new(1);
static CONNECTIONS: OnceCell<DashMap<u64, ConnectionHandle>> = OnceCell::new();

#[no_mangle]
pub extern "C" fn cc_quic_init_logging() -> i32 {
    #[cfg(target_os = "android")]
    {
        use android_logger::Config;
        use log::LevelFilter;
        android_logger::init_once(
            Config::default()
                .with_max_level(LevelFilter::Info)
                .with_tag("cribcall_quic"),
        );
        return CcQuicStatus::Ok.code();
    }

    #[cfg(not(target_os = "android"))]
    {
        let env = env_logger::Env::default().default_filter_or("info");
        let _ = env_logger::Builder::from_env(env)
            .format_timestamp_millis()
            .try_init();
        return CcQuicStatus::Ok.code();
    }
}

#[no_mangle]
pub extern "C" fn cc_quic_init_dart_api(post_cobject: *mut c_void) -> i32 {
    if post_cobject.is_null() {
        return CcQuicStatus::NullPointer.code();
    }
    // Safety: the pointer comes from Dart's NativeApi.postCObject.
    unsafe {
        allo_isolate::store_dart_post_cobject(std::mem::transmute(post_cobject));
    }
    CcQuicStatus::Ok.code()
}

#[no_mangle]
pub extern "C" fn cc_quic_version() -> *const c_char {
    static VERSION: OnceCell<CString> = OnceCell::new();
    VERSION
        .get_or_init(|| {
            CString::new(format!("cribcall-quic-rs/{}", env!("CARGO_PKG_VERSION")))
                .expect("static version string")
        })
        .as_ptr()
}

#[no_mangle]
pub extern "C" fn cc_quic_config_new(out_config: *mut *mut CcQuicConfig) -> i32 {
    if out_config.is_null() {
        return CcQuicStatus::NullPointer.code();
    }

    let mut config = match quiche::Config::new(quiche::PROTOCOL_VERSION) {
        Ok(cfg) => cfg,
        Err(_) => return CcQuicStatus::ConfigError.code(),
    };

    if config.set_application_protos(&[CONTROL_ALPN]).is_err() {
        return CcQuicStatus::InvalidAlpn.code();
    }

    config.verify_peer(true);
    config.set_max_idle_timeout(DEFAULT_IDLE_TIMEOUT_MS);
    config.set_max_recv_udp_payload_size(DEFAULT_MAX_UDP_PAYLOAD);
    config.set_max_send_udp_payload_size(DEFAULT_MAX_UDP_PAYLOAD);
    config.set_initial_max_data(DEFAULT_STREAM_WINDOW);
    config.set_initial_max_stream_data_bidi_local(DEFAULT_STREAM_WINDOW);
    config.set_initial_max_stream_data_bidi_remote(DEFAULT_STREAM_WINDOW);
    config.set_initial_max_stream_data_uni(DEFAULT_STREAM_WINDOW);
    config.set_initial_max_streams_bidi(8);
    config.set_initial_max_streams_uni(4);
    config.enable_dgram(true, 1024, 1024);
    config.enable_pacing(true);

    let handle = Box::new(CcQuicConfig { inner: config });
    unsafe {
        *out_config = Box::into_raw(handle);
    }

    CcQuicStatus::Ok.code()
}

#[no_mangle]
pub extern "C" fn cc_quic_config_free(config: *mut CcQuicConfig) {
    if config.is_null() {
        return;
    }

    unsafe {
        drop(Box::from_raw(config));
    }
}

#[no_mangle]
pub extern "C" fn cc_quic_client_connect(
    config: *mut CcQuicConfig,
    host: *const c_char,
    port: u16,
    server_name: *const c_char,
    expected_server_fingerprint_hex: *const c_char,
    cert_pem_path: *const c_char,
    key_pem_path: *const c_char,
    dart_port: i64,
    out_handle: *mut u64,
) -> i32 {
    if config.is_null()
        || host.is_null()
        || server_name.is_null()
        || expected_server_fingerprint_hex.is_null()
        || cert_pem_path.is_null()
        || key_pem_path.is_null()
        || out_handle.is_null()
    {
        return CcQuicStatus::NullPointer.code();
    }

    let host = match cstr_to_string(host) {
        Ok(s) => s,
        Err(code) => return code.code(),
    };
    let server_name = match cstr_to_string(server_name) {
        Ok(s) => s,
        Err(code) => return code.code(),
    };
    let expected_fp = match cstr_to_string(expected_server_fingerprint_hex) {
        Ok(s) => s.to_lowercase(),
        Err(code) => return code.code(),
    };
    let cert_path = match cstr_to_string(cert_pem_path) {
        Ok(s) => s,
        Err(code) => return code.code(),
    };
    let key_path = match cstr_to_string(key_pem_path) {
        Ok(s) => s,
        Err(code) => return code.code(),
    };
    info!(
        "client connect host={host}:{port} server_name={server_name} expected_fp={}",
        short_hex(&expected_fp)
    );

    let mut config = unsafe { Box::from_raw(config) }.inner;
    if let Err(err) = config.load_cert_chain_from_pem_file(&cert_path) {
        error!("load cert error: {err}");
        return CcQuicStatus::CertLoadError.code();
    }
    if let Err(err) = config.load_priv_key_from_pem_file(&key_path) {
        error!("load key error: {err}");
        return CcQuicStatus::CertLoadError.code();
    }

    let peer: SocketAddr = match format!("{host}:{port}").parse() {
        Ok(addr) => addr,
        Err(err) => {
            error!("invalid peer addr: {err}");
            return CcQuicStatus::SocketError.code();
        }
    };

    let socket = match UdpSocket::bind("0.0.0.0:0") {
        Ok(s) => s,
        Err(err) => {
            error!("bind failed: {err}");
            return CcQuicStatus::SocketError.code();
        }
    };
    socket
        .connect(peer)
        .map_err(|err| error!("connect error: {err}"))
        .ok();
    if socket.set_nonblocking(true).is_err() {
        warn!("failed to set nonblocking on client socket");
    }

    let (tx, rx) = mpsc::channel();
    let handle_id = NEXT_HANDLE.fetch_add(1, Ordering::SeqCst);

    CONNECTIONS
        .get_or_init(DashMap::new)
        .insert(handle_id, ConnectionHandle { tx });

    thread::spawn(move || {
        run_client_worker(
            handle_id,
            config,
            socket,
            peer,
            server_name,
            expected_fp,
            dart_port,
            rx,
        );
        if let Some(map) = CONNECTIONS.get() {
            map.remove(&handle_id);
        }
    });

    unsafe {
        *out_handle = handle_id;
    }

    CcQuicStatus::Ok.code()
}

#[no_mangle]
pub extern "C" fn cc_quic_server_start(
    config: *mut CcQuicConfig,
    bind_addr: *const c_char,
    port: u16,
    cert_pem_path: *const c_char,
    key_pem_path: *const c_char,
    trusted_fingerprints_csv: *const c_char,
    dart_port: i64,
    out_handle: *mut u64,
) -> i32 {
    if config.is_null()
        || bind_addr.is_null()
        || cert_pem_path.is_null()
        || key_pem_path.is_null()
        || trusted_fingerprints_csv.is_null()
        || out_handle.is_null()
    {
        return CcQuicStatus::NullPointer.code();
    }

    let bind_host = match cstr_to_string(bind_addr) {
        Ok(s) => s,
        Err(code) => return code.code(),
    };
    let cert_path = match cstr_to_string(cert_pem_path) {
        Ok(s) => s,
        Err(code) => return code.code(),
    };
    let key_path = match cstr_to_string(key_pem_path) {
        Ok(s) => s,
        Err(code) => return code.code(),
    };

    let trusted_allowlist = match cstr_to_string(trusted_fingerprints_csv) {
        Ok(s) => parse_allowlist(&s),
        Err(code) => return code.code(),
    };

    let local: SocketAddr = match format!("{bind_host}:{port}").parse() {
        Ok(addr) => addr,
        Err(err) => {
            error!("invalid bind addr: {err}");
            return CcQuicStatus::SocketError.code();
        }
    };

    let mut config = unsafe { Box::from_raw(config) }.inner;
    if let Err(err) = config.load_cert_chain_from_pem_file(&cert_path) {
        error!("load cert error: {err}");
        return CcQuicStatus::CertLoadError.code();
    }
    if let Err(err) = config.load_priv_key_from_pem_file(&key_path) {
        error!("load key error: {err}");
        return CcQuicStatus::CertLoadError.code();
    }

    let socket = match UdpSocket::bind(local) {
        Ok(s) => s,
        Err(err) => {
            error!("server bind failed: {err}");
            return CcQuicStatus::SocketError.code();
        }
    };
    info!(
        "server start bind={bind_host}:{port} trusted_allowlist={}",
        trusted_allowlist.len()
    );
    if socket.set_nonblocking(true).is_err() {
        warn!("failed to set nonblocking on server socket");
    }

    let (tx, rx) = mpsc::channel();
    let handle_id = NEXT_HANDLE.fetch_add(1, Ordering::SeqCst);

    CONNECTIONS
        .get_or_init(DashMap::new)
        .insert(handle_id, ConnectionHandle { tx });

    thread::spawn(move || {
        run_server_worker(
            handle_id,
            config,
            socket,
            dart_port,
            trusted_allowlist,
            rx,
        );
        if let Some(map) = CONNECTIONS.get() {
            map.remove(&handle_id);
        }
    });

    unsafe {
        *out_handle = handle_id;
    }

    CcQuicStatus::Ok.code()
}

#[no_mangle]
pub extern "C" fn cc_quic_conn_send(
    handle: u64,
    conn_id_ptr: *const u8,
    conn_id_len: usize,
    data: *const u8,
    data_len: usize,
) -> i32 {
    if data.is_null() || data_len == 0 {
        return CcQuicStatus::NullPointer.code();
    }
    if conn_id_ptr.is_null() || conn_id_len == 0 {
        return CcQuicStatus::NullPointer.code();
    }
    let slice = unsafe { std::slice::from_raw_parts(data, data_len) };
    let payload = slice.to_vec();
    let conn_id_raw = unsafe { std::slice::from_raw_parts(conn_id_ptr, conn_id_len) }.to_vec();
    let conn_id_str = match String::from_utf8(conn_id_raw) {
        Ok(s) => s,
        Err(_) => return CcQuicStatus::Internal.code(),
    };
    let conn_id = match hex::decode(conn_id_str.trim()) {
        Ok(bytes) => bytes,
        Err(_) => return CcQuicStatus::Internal.code(),
    };

    let map = match CONNECTIONS.get() {
        Some(map) => map,
        None => return CcQuicStatus::Internal.code(),
    };
    match map.get(&handle) {
        Some(entry) => {
            if entry
                .tx
                .send(WorkerCommand::Send {
                    conn_id,
                    payload,
                })
                .is_err()
            {
                return CcQuicStatus::Internal.code();
            }
        }
        None => return CcQuicStatus::Internal.code(),
    }

    CcQuicStatus::Ok.code()
}

#[no_mangle]
pub extern "C" fn cc_quic_conn_close(handle: u64) -> i32 {
    let map = match CONNECTIONS.get() {
        Some(map) => map,
        None => return CcQuicStatus::Internal.code(),
    };
    if let Some(entry) = map.get(&handle) {
        let _ = entry.tx.send(WorkerCommand::Close { conn_id: None });
    }
    CcQuicStatus::Ok.code()
}

fn run_client_worker(
    handle_id: u64,
    mut config: quiche::Config,
    socket: UdpSocket,
    peer: SocketAddr,
    server_name: String,
    expected_fp: String,
    dart_port: i64,
    rx: mpsc::Receiver<WorkerCommand>,
) {
    let start = Instant::now();
    let local_addr = match socket.local_addr() {
        Ok(addr) => addr,
        Err(err) => {
            post_event(
                dart_port,
                QuicEvent::Error {
                    handle: handle_id,
                    connection_id: None,
                    message: format!("socket addr error: {err}"),
                },
            );
            return;
        }
    };

    let mut scid = [0u8; quiche::MAX_CONN_ID_LEN];
    OsRng.fill_bytes(&mut scid);
    let scid = quiche::ConnectionId::from_ref(&scid);
    let conn_id_hex = hex_string(scid.as_ref());
    info!(
        "client {} connecting from {} to {} (server_name={} expected_fp={})",
        handle_id,
        local_addr,
        peer,
        server_name,
        short_hex(&expected_fp)
    );

    let mut conn = match quiche::connect(
        Some(&server_name),
        &scid,
        local_addr,
        peer,
        &mut config,
    ) {
        Ok(c) => c,
        Err(err) => {
            post_event(
                dart_port,
                QuicEvent::Error {
                    handle: handle_id,
                    connection_id: Some(conn_id_hex.clone()),
                    message: format!("connect error: {err}"),
                },
            );
            return;
        }
    };

    let mut out = [0u8; MAX_DATAGRAM_SIZE];
    let mut buf = [0u8; 65_536];
    let mut announced = false;

    loop {
        while let Ok(cmd) = rx.try_recv() {
            match cmd {
                WorkerCommand::Send { conn_id, payload } => {
                    if conn.is_established() && conn_id == scid.as_ref() {
                        if let Err(err) = conn.stream_send(CONTROL_STREAM_ID, &payload, false) {
                            if err != quiche::Error::Done {
                                warn!("send error: {err:?}");
                            }
                        }
                    }
                }
                WorkerCommand::Close { conn_id } => {
                    if conn_id.is_none() || conn_id.as_deref() == Some(scid.as_ref()) {
                        let _ = conn.close(false, 0x100, b"app close");
                    }
                }
            }
        }

        match conn.send(&mut out) {
            Ok((len, send_info)) => {
                if let Err(err) = socket.send_to(&out[..len], send_info.to) {
                    warn!("udp send error: {err}");
                }
            }
            Err(quiche::Error::Done) => {}
            Err(err) => {
                warn!(
                    "client {} send loop error (established={}): {err}",
                    conn_id_hex,
                    conn.is_established()
                );
                post_event(
                    dart_port,
                    QuicEvent::Error {
                        handle: handle_id,
                        connection_id: Some(conn_id_hex.clone()),
                        message: format!("quic send error: {err}"),
                    },
                );
                break;
            }
        }

        match socket.recv_from(&mut buf) {
            Ok((len, from)) => {
                let recv_info = quiche::RecvInfo { from, to: local_addr };
                if let Err(err) = conn.recv(&mut buf[..len], recv_info) {
                    if err != quiche::Error::Done {
                        warn!("recv error: {err:?}");
                    }
                }
            }
            Err(err) if err.kind() == std::io::ErrorKind::WouldBlock => {}
            Err(err) => {
                warn!("client udp recv error: {err}");
                break;
            }
        }

        if conn.is_established() && !announced {
            announced = true;
            let peer_fp = match conn.peer_cert() {
                Some(cert) => sha256_hex(cert),
                None => String::new(),
            };
            if !expected_fp.is_empty() && peer_fp.to_lowercase() != expected_fp {
                warn!(
                    "client {} fingerprint mismatch: expected {} got {}",
                    conn_id_hex,
                    short_hex(&expected_fp),
                    short_hex(&peer_fp)
                );
                let _ = conn.close(false, 0x102, b"fingerprint mismatch");
                post_event(
                    dart_port,
                    QuicEvent::Error {
                        handle: handle_id,
                        connection_id: Some(conn_id_hex.clone()),
                        message: "server fingerprint mismatch".to_string(),
                    },
                );
                break;
            }
            info!(
                "client connected conn_id={} peer_fp={}",
                conn_id_hex,
                short_hex(&peer_fp)
            );
            post_event(
                dart_port,
                QuicEvent::Connected {
                    handle: handle_id,
                    connection_id: conn_id_hex.clone(),
                    peer_fingerprint: peer_fp,
                },
            );
        }

        for stream_id in conn.readable() {
            loop {
                let mut app_buf = [0u8; 65535];
                match conn.stream_recv(stream_id, &mut app_buf) {
                    Ok((read, _fin)) => {
                        let data = &app_buf[..read];
                        post_event(
                            dart_port,
                            QuicEvent::Message {
                                handle: handle_id,
                                connection_id: conn_id_hex.clone(),
                                data_base64: BASE64.encode(data),
                            },
                        );
                    }
                    Err(quiche::Error::Done) => break,
                    Err(err) => {
                        warn!("stream read error: {err:?}");
                        break;
                    }
                }
            }
        }

        if conn.is_closed() {
            let reason = conn.peer_error().map(|err| format!("{err:?}"));
            info!(
                "client connection {} closed established={} ({:?}) stats={}",
                conn_id_hex,
                conn.is_established(),
                reason,
                format_stats(&conn.stats())
            );
            post_event(
                dart_port,
                QuicEvent::Closed {
                    handle: handle_id,
                    connection_id: conn_id_hex.clone(),
                    reason,
                },
            );
            break;
        }

        if let Some(timeout) = conn.timeout() {
            if timeout.is_zero() {
                conn.on_timeout();
            } else {
                let wait = timeout.min(Duration::from_millis(5));
                thread::sleep(wait);
                if wait >= timeout {
                    if !conn.is_established() {
                        warn!(
                            "client {} handshake timeout fired after {:?} stats={}",
                            conn_id_hex,
                            start.elapsed(),
                            format_stats(&conn.stats())
                        );
                    }
                    conn.on_timeout();
                }
            }
        } else {
            thread::sleep(Duration::from_millis(2));
        }
    }
}

fn run_server_worker(
    handle_id: u64,
    mut config: quiche::Config,
    socket: UdpSocket,
    dart_port: i64,
    trusted_allowlist: HashSet<String>,
    rx: mpsc::Receiver<WorkerCommand>,
) {
    let local_addr = match socket.local_addr() {
        Ok(addr) => addr,
        Err(err) => {
            post_event(
                dart_port,
                QuicEvent::Error {
                    handle: handle_id,
                    connection_id: None,
                    message: format!("socket addr error: {err}"),
                },
            );
            return;
        }
    };

    let mut buf = [0u8; 65_536];
    let mut out = [0u8; MAX_DATAGRAM_SIZE];
    let mut conns: HashMap<Vec<u8>, quiche::Connection> = HashMap::new();
    let mut announced: HashSet<Vec<u8>> = HashSet::new();
    let mut start_times: HashMap<Vec<u8>, Instant> = HashMap::new();

    loop {
        while let Ok(cmd) = rx.try_recv() {
            match cmd {
                WorkerCommand::Send { conn_id, payload } => {
                    if let Some(connection) = conns.get_mut(&conn_id) {
                        if connection.is_established() {
                            if let Err(err) =
                                connection.stream_send(CONTROL_STREAM_ID, &payload, false)
                            {
                                if err != quiche::Error::Done {
                                    warn!("server send error: {err:?}");
                                }
                            }
                        }
                    }
                }
                WorkerCommand::Close { conn_id } => {
                    if let Some(id) = conn_id {
                        if let Some(conn) = conns.get_mut(&id) {
                            let _ = conn.close(false, 0x101, b"server close");
                        }
                    } else {
                        for connection in conns.values_mut() {
                            let _ = connection.close(false, 0x101, b"server close");
                        }
                    }
                }
            }
        }

        match socket.recv_from(&mut buf) {
            Ok((len, from)) => {
                let hdr = match quiche::Header::from_slice(&mut buf[..len], quiche::MAX_CONN_ID_LEN)
                {
                    Ok(h) => h,
                    Err(err) => {
                        warn!("header parse error: {err:?}");
                        continue;
                    }
                };

                if !conns.contains_key(hdr.dcid.as_ref()) {
                    let mut scid = [0u8; quiche::MAX_CONN_ID_LEN];
                    OsRng.fill_bytes(&mut scid);
                    let scid = quiche::ConnectionId::from_ref(&scid);
                    match quiche::accept(&scid, Some(&hdr.scid), local_addr, from, &mut config) {
                        Ok(c) => {
                            info!(
                                "server accepted conn_id={} from {}",
                                hex_string(scid.as_ref()),
                                from
                            );
                            conns.insert(scid.to_vec(), c);
                            start_times.insert(scid.to_vec(), Instant::now());
                        }
                        Err(err) => {
                            warn!("accept error: {err}");
                            continue;
                        }
                    }
                }

                if let Some(connection) = conns.get_mut(hdr.dcid.as_ref()) {
                    let recv_info = quiche::RecvInfo { from, to: local_addr };
                    if let Err(err) = connection.recv(&mut buf[..len], recv_info) {
                        if err != quiche::Error::Done {
                            warn!("server recv error: {err:?}");
                        }
                    }
                }
            }
            Err(err) if err.kind() == std::io::ErrorKind::WouldBlock => {}
            Err(err) => {
                warn!("server udp recv error: {err}");
                break;
            }
        }

        let mut to_close: Vec<Vec<u8>> = Vec::new();

        for (id, connection) in conns.iter_mut() {
            let id_hex = hex_string(id);
            match connection.send(&mut out) {
                Ok((len, send_info)) => {
                    if let Err(err) = socket.send_to(&out[..len], send_info.to) {
                        warn!("server udp send error: {err}");
                    }
                }
                Err(quiche::Error::Done) => {}
                Err(err) => {
                    warn!(
                        "server send error conn_id={} established={} err={err}",
                        id_hex,
                        connection.is_established()
                    );
                    post_event(
                        dart_port,
                        QuicEvent::Error {
                            handle: handle_id,
                            connection_id: Some(id_hex.clone()),
                            message: format!("server send error: {err}"),
                        },
                    );
                    to_close.push(id.clone());
                    continue;
                }
            }

            if connection.is_established() && !announced.contains(id) {
                let peer_fp = match connection.peer_cert() {
                    Some(cert) => sha256_hex(cert),
                    None => String::new(),
                };

                if !trusted_allowlist.is_empty() && !trusted_allowlist.contains(&peer_fp) {
                    warn!(
                        "rejecting untrusted client conn={} fp={}",
                        id_hex,
                        short_hex(&peer_fp)
                    );
                    let _ = connection.close(false, 0x103, b"untrusted client");
                    to_close.push(id.clone());
                    continue;
                }

                info!(
                    "server connection established conn_id={} peer_fp={}",
                    id_hex,
                    short_hex(&peer_fp)
                );
                announced.insert(id.clone());
                post_event(
                    dart_port,
                    QuicEvent::Connected {
                        handle: handle_id,
                        connection_id: id_hex.clone(),
                        peer_fingerprint: peer_fp,
                    },
                );
            }

            for stream_id in connection.readable() {
                loop {
                    let mut app_buf = [0u8; 65535];
                    match connection.stream_recv(stream_id, &mut app_buf) {
                        Ok((read, _fin)) => {
                            let data = &app_buf[..read];
                            post_event(
                                dart_port,
                                QuicEvent::Message {
                                    handle: handle_id,
                                    connection_id: id_hex.clone(),
                                    data_base64: BASE64.encode(data),
                                },
                            );
                        }
                        Err(quiche::Error::Done) => break,
                        Err(err) => {
                            warn!("server stream read error: {err:?}");
                            break;
                        }
                    }
                }
            }

            if connection.is_closed() {
                let reason = connection.peer_error().map(|err| format!("{err:?}"));
                info!(
                    "server connection {} closed established={} ({:?}) stats={}",
                    id_hex,
                    connection.is_established(),
                    reason,
                    format_stats(&connection.stats())
                );
                post_event(
                    dart_port,
                    QuicEvent::Closed {
                        handle: handle_id,
                        connection_id: id_hex.clone(),
                        reason,
                    },
                );
                to_close.push(id.clone());
                continue;
            }

            if let Some(timeout) = connection.timeout() {
                if timeout.is_zero() {
                    connection.on_timeout();
                } else {
                    let wait = timeout.min(Duration::from_millis(5));
                    thread::sleep(wait);
                    if wait >= timeout {
                        if !connection.is_established() {
                            let elapsed = start_times
                                .get(id)
                                .map(|s| s.elapsed())
                                .unwrap_or_default();
                            warn!(
                                "server conn {} handshake timeout fired after {:?} stats={}",
                                id_hex,
                                elapsed,
                                format_stats(&connection.stats())
                            );
                        }
                        connection.on_timeout();
                    }
                }
            }
        }

        for id in to_close {
            conns.remove(&id);
            announced.remove(&id);
            start_times.remove(&id);
        }

    }
}

fn cstr_to_string(ptr: *const c_char) -> Result<String, CcQuicStatus> {
    if ptr.is_null() {
        return Err(CcQuicStatus::NullPointer);
    }
    unsafe {
        CStr::from_ptr(ptr)
            .to_str()
            .map(|s| s.to_string())
            .map_err(|_| CcQuicStatus::Internal)
    }
}

fn parse_allowlist(csv: &str) -> HashSet<String> {
    csv.split(',')
        .filter_map(|s| {
            let trimmed = s.trim();
            if trimmed.is_empty() {
                None
            } else {
                Some(trimmed.to_lowercase())
            }
        })
        .collect()
}

fn sha256_hex(data: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(data);
    let digest = hasher.finalize();
    digest
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect::<String>()
}

fn hex_string(data: &[u8]) -> String {
    data.iter().map(|b| format!("{b:02x}")).collect()
}

fn format_stats(stats: &quiche::Stats) -> String {
    format!(
        "tx {} pkts ({} retrans) rx {} pkts lost {} spurious {}",
        stats.sent, stats.retrans, stats.recv, stats.lost, stats.spurious_lost
    )
}

fn short_hex(hex: &str) -> String {
    let trimmed = hex.trim();
    if trimmed.len() <= 12 {
        return trimmed.to_string();
    }
    let prefix_len = 6.min(trimmed.len());
    let suffix_len = 4.min(trimmed.len().saturating_sub(prefix_len));
    let suffix_start = trimmed.len().saturating_sub(suffix_len);
    format!(
        "{}...{}",
        &trimmed[..prefix_len],
        &trimmed[suffix_start..]
    )
}

fn post_event(port: i64, event: QuicEvent) {
    if let Ok(json) = serde_json::to_string(&event) {
        let _ = Isolate::new(port).post(json);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn builds_default_config() {
        let mut ptr: *mut CcQuicConfig = std::ptr::null_mut();
        let status = cc_quic_config_new(&mut ptr);
        assert_eq!(status, CcQuicStatus::Ok.code());
        assert!(!ptr.is_null());
        cc_quic_config_free(ptr);
    }
}
