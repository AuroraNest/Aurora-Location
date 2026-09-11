// SPDX-License-Identifier: MIT

use boringtun::noise::{errors::WireGuardError, Tunn, TunnResult};
use boringtun::x25519::{PublicKey, StaticSecret};
use std::net::{Ipv4Addr, SocketAddr, SocketAddrV4, UdpSocket};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{self, Receiver, TryRecvError};
use std::sync::Arc;
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

const CLIENT_ADDRESS: [u8; 4] = [10, 7, 0, 10];
const PROXY_ADDRESS: [u8; 4] = [10, 7, 0, 1];
const PAIRING_PORT: u16 = 49_152;
const MAX_DATAGRAM_SIZE: usize = 65_535;
const MAX_WIREGUARD_PACKET_SIZE: usize = ((u16::MAX as usize + 15) & !15) + 32;
const MAX_PACKETS_PER_TICK: usize = 64;
const POLL_INTERVAL: Duration = Duration::from_millis(5);
const TIMER_INTERVAL: Duration = Duration::from_millis(250);

pub const AURORA_EMPROXY_OK: i32 = 0;
pub const AURORA_EMPROXY_ERROR_NULL_ARGUMENT: i32 = -1;
pub const AURORA_EMPROXY_ERROR_INVALID_PORT: i32 = -2;
pub const AURORA_EMPROXY_ERROR_INVALID_KEY: i32 = -3;
pub const AURORA_EMPROXY_ERROR_BIND: i32 = -4;
pub const AURORA_EMPROXY_ERROR_SOCKET: i32 = -5;
pub const AURORA_EMPROXY_ERROR_THREAD: i32 = -6;
pub const AURORA_EMPROXY_ERROR_ALREADY_STARTED: i32 = -7;
pub const AURORA_EMPROXY_ERROR_STOP: i32 = -8;

#[derive(Default)]
struct Counters {
    received_udp: AtomicU64,
    authenticated_ipv4: AtomicU64,
    reflected_ipv4: AtomicU64,
    rejected_packets: AtomicU64,
    last_rejection: AtomicU64,
    tcp_resets: AtomicU64,
    pairing_port_resets: AtomicU64,
}

#[repr(C)]
pub struct AuroraEMProxyStats {
    pub received_udp: u64,
    pub authenticated_ipv4: u64,
    pub reflected_ipv4: u64,
    pub rejected_packets: u64,
    pub last_rejection: u64,
    pub tcp_resets: u64,
    pub pairing_port_resets: u64,
}

struct Worker {
    stop_sender: mpsc::Sender<()>,
    join_handle: JoinHandle<()>,
    counters: Arc<Counters>,
}

#[repr(C)]
pub struct AuroraEMProxyHandle {
    worker: Worker,
}

fn validate_keys(
    server_private_bytes: [u8; 32],
    client_public_bytes: [u8; 32],
) -> Option<(StaticSecret, PublicKey)> {
    if server_private_bytes.iter().all(|byte| *byte == 0)
        || client_public_bytes.iter().all(|byte| *byte == 0)
    {
        return None;
    }

    let server_private = StaticSecret::from(server_private_bytes);
    let client_public = PublicKey::from(client_public_bytes);
    if server_private
        .diffie_hellman(&client_public)
        .as_bytes()
        .iter()
        .all(|byte| *byte == 0)
    {
        return None;
    }

    Some((server_private, client_public))
}

fn start_worker(
    server_private: StaticSecret,
    client_public: PublicKey,
    udp_port: u16,
) -> Result<Worker, i32> {
    let bind_address = SocketAddrV4::new(Ipv4Addr::LOCALHOST, udp_port);
    let socket = UdpSocket::bind(bind_address).map_err(|_| AURORA_EMPROXY_ERROR_BIND)?;
    socket
        .set_nonblocking(true)
        .map_err(|_| AURORA_EMPROXY_ERROR_SOCKET)?;

    let counters = Arc::new(Counters::default());
    let thread_counters = Arc::clone(&counters);
    let (stop_sender, stop_receiver) = mpsc::channel();
    let join_handle = thread::Builder::new()
        .name("aurora-emproxy".to_owned())
        .spawn(move || {
            run_proxy(
                socket,
                server_private,
                client_public,
                stop_receiver,
                thread_counters,
            )
        })
        .map_err(|_| AURORA_EMPROXY_ERROR_THREAD)?;

    Ok(Worker {
        stop_sender,
        join_handle,
        counters,
    })
}

fn run_proxy(
    socket: UdpSocket,
    server_private: StaticSecret,
    client_public: PublicKey,
    stop_receiver: Receiver<()>,
    counters: Arc<Counters>,
) {
    let mut tunnel = Tunn::new(server_private, client_public, None, None, 0, None);
    let mut received = vec![0_u8; MAX_DATAGRAM_SIZE];
    let mut decrypted = vec![0_u8; MAX_DATAGRAM_SIZE];
    let mut encrypted = vec![0_u8; MAX_WIREGUARD_PACKET_SIZE];
    let mut peer_endpoint: Option<SocketAddr> = None;
    let mut next_timer = Instant::now() + TIMER_INTERVAL;

    loop {
        match stop_receiver.try_recv() {
            Ok(()) | Err(TryRecvError::Disconnected) => break,
            Err(TryRecvError::Empty) => {}
        }

        for _ in 0..MAX_PACKETS_PER_TICK {
            match socket.recv_from(&mut received) {
                Ok((length, endpoint)) => {
                    counters.received_udp.fetch_add(1, Ordering::Relaxed);
                    if !endpoint.ip().is_loopback()
                        || peer_endpoint.is_some_and(|current| current != endpoint)
                    {
                        counters.rejected_packets.fetch_add(1, Ordering::Relaxed);
                        counters.last_rejection.store(1, Ordering::Relaxed);
                        continue;
                    }

                    let authenticated = process_datagram(
                        &socket,
                        &mut tunnel,
                        endpoint,
                        &received[..length],
                        &mut decrypted,
                        &mut encrypted,
                        &counters,
                    );
                    if authenticated {
                        peer_endpoint = Some(endpoint);
                    }
                }
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => break,
                Err(_) => break,
            }
        }

        let now = Instant::now();
        if now >= next_timer {
            if let Some(endpoint) = peer_endpoint {
                if let TunnResult::WriteToNetwork(packet) = tunnel.update_timers(&mut encrypted) {
                    let _ = socket.send_to(packet, endpoint);
                }
            }
            next_timer = now + TIMER_INTERVAL;
        }

        match stop_receiver.recv_timeout(POLL_INTERVAL) {
            Ok(()) | Err(mpsc::RecvTimeoutError::Disconnected) => break,
            Err(mpsc::RecvTimeoutError::Timeout) => {}
        }
    }
}

fn process_datagram(
    socket: &UdpSocket,
    tunnel: &mut Tunn,
    endpoint: SocketAddr,
    datagram: &[u8],
    decrypted: &mut [u8],
    encrypted: &mut [u8],
    counters: &Counters,
) -> bool {
    let mut input = datagram;
    let mut authenticated = false;

    loop {
        match tunnel.decapsulate(Some(endpoint.ip()), input, decrypted) {
            TunnResult::Done => return authenticated,
            TunnResult::Err(error) => {
                counters.rejected_packets.fetch_add(1, Ordering::Relaxed);
                let reason = match error {
                    WireGuardError::NoCurrentSession => {
                        // Restarting the app loses session keys while the local VPN can retain them.
                        // Initiate the standard authenticated handshake; do not trust or pin this packet.
                        // ponytail: one-shot localhost recovery; add timed retries if local packet loss is observed.
                        if let TunnResult::WriteToNetwork(packet) =
                            tunnel.format_handshake_initiation(encrypted, false)
                        {
                            let _ = socket.send_to(packet, endpoint);
                        }
                        2
                    }
                    WireGuardError::WrongIndex => 3,
                    _ => 4,
                };
                counters.last_rejection.store(reason, Ordering::Relaxed);
                return authenticated;
            }
            TunnResult::WriteToNetwork(packet) => {
                let _ = socket.send_to(packet, endpoint);
            }
            TunnResult::WriteToTunnelV4(packet, _) => {
                authenticated = true;
                counters.authenticated_ipv4.fetch_add(1, Ordering::Relaxed);
                if remap_pairing_packet(packet) {
                    let tcp_flags = packet[usize::from(packet[0] & 0x0f) * 4 + 13];
                    if tcp_flags & 0x04 != 0 {
                        counters.tcp_resets.fetch_add(1, Ordering::Relaxed);
                        let offset = usize::from(packet[0] & 0x0f) * 4;
                        if u16::from_be_bytes([packet[offset], packet[offset + 1]]) == PAIRING_PORT {
                            counters.pairing_port_resets.fetch_add(1, Ordering::Relaxed);
                        }
                    }
                    if let TunnResult::WriteToNetwork(packet) =
                        tunnel.encapsulate(packet, encrypted)
                    {
                        if socket.send_to(packet, endpoint).is_ok() {
                            counters.reflected_ipv4.fetch_add(1, Ordering::Relaxed);
                        }
                    }
                } else {
                    counters.rejected_packets.fetch_add(1, Ordering::Relaxed);
                    counters.last_rejection.store(5, Ordering::Relaxed);
                }
            }
            TunnResult::WriteToTunnelV6(_, _) => {
                authenticated = true;
                counters.rejected_packets.fetch_add(1, Ordering::Relaxed);
                counters.last_rejection.store(6, Ordering::Relaxed);
            }
        }
        input = &[];
    }
}

fn remap_pairing_packet(packet: &mut [u8]) -> bool {
    if packet.len() < 40 || packet[0] >> 4 != 4 {
        return false;
    }

    let header_length = usize::from(packet[0] & 0x0f) * 4;
    let total_length = usize::from(u16::from_be_bytes([packet[2], packet[3]]));
    if header_length < 20
        || header_length > packet.len()
        || total_length != packet.len()
        || total_length < header_length + 20
        || packet[9] != 6
    {
        return false;
    }

    let fragment = u16::from_be_bytes([packet[6], packet[7]]);
    if fragment & !0x4000 != 0 || internet_checksum(&packet[..header_length]) != 0xffff {
        return false;
    }

    if packet[12..16] != CLIENT_ADDRESS || packet[16..20] != PROXY_ADDRESS {
        return false;
    }

    let tcp = &packet[header_length..total_length];
    let tcp_header_length = usize::from(tcp[12] >> 4) * 4;
    if tcp_header_length < 20 || tcp_header_length > tcp.len() {
        return false;
    }

    let source_port = u16::from_be_bytes([tcp[0], tcp[1]]);
    let destination_port = u16::from_be_bytes([tcp[2], tcp[3]]);
    // Remote Pairing negotiates a second TCP listener (observed: 54673).
    // Keep reflection within the authenticated peer's dynamic/private port range.
    if source_port < PAIRING_PORT || destination_port < PAIRING_PORT {
        return false;
    }

    if tcp_checksum(packet, header_length, total_length) != 0xffff {
        return false;
    }

    for offset in 0..4 {
        packet.swap(12 + offset, 16 + offset);
    }
    true
}

fn internet_checksum(bytes: &[u8]) -> u16 {
    let mut sum = 0_u32;
    let mut chunks = bytes.chunks_exact(2);
    for chunk in &mut chunks {
        sum += u32::from(u16::from_be_bytes([chunk[0], chunk[1]]));
    }
    if let Some(byte) = chunks.remainder().first() {
        sum += u32::from(*byte) << 8;
    }
    while sum > 0xffff {
        sum = (sum & 0xffff) + (sum >> 16);
    }
    sum as u16
}

fn tcp_checksum(packet: &[u8], header_length: usize, total_length: usize) -> u16 {
    let tcp_length = total_length - header_length;
    let mut sum = 0_u32;
    sum += u32::from(u16::from_be_bytes([packet[12], packet[13]]));
    sum += u32::from(u16::from_be_bytes([packet[14], packet[15]]));
    sum += u32::from(u16::from_be_bytes([packet[16], packet[17]]));
    sum += u32::from(u16::from_be_bytes([packet[18], packet[19]]));
    sum += 6;
    sum += tcp_length as u32;
    sum += u32::from(internet_checksum(&packet[header_length..total_length]));
    while sum > 0xffff {
        sum = (sum & 0xffff) + (sum >> 16);
    }
    sum as u16
}

#[no_mangle]
/// Starts a loopback responder and returns its owned handle.
///
/// # Safety
/// `server_private_key` and `client_public_key` must each reference 32 readable bytes.
/// `out_handle` must reference writable, exclusively accessed storage containing null.
pub unsafe extern "C" fn aurora_emproxy_start(
    server_private_key: *const u8,
    client_public_key: *const u8,
    udp_port: u16,
    out_handle: *mut *mut AuroraEMProxyHandle,
) -> i32 {
    if server_private_key.is_null() || client_public_key.is_null() || out_handle.is_null() {
        return AURORA_EMPROXY_ERROR_NULL_ARGUMENT;
    }
    if udp_port == 0 {
        return AURORA_EMPROXY_ERROR_INVALID_PORT;
    }
    if !(*out_handle).is_null() {
        return AURORA_EMPROXY_ERROR_ALREADY_STARTED;
    }

    let mut server_private_bytes = [0_u8; 32];
    let mut client_public_bytes = [0_u8; 32];
    server_private_bytes.copy_from_slice(std::slice::from_raw_parts(server_private_key, 32));
    client_public_bytes.copy_from_slice(std::slice::from_raw_parts(client_public_key, 32));

    let Some((server_private, client_public)) =
        validate_keys(server_private_bytes, client_public_bytes)
    else {
        server_private_bytes.fill(0);
        return AURORA_EMPROXY_ERROR_INVALID_KEY;
    };
    server_private_bytes.fill(0);

    match start_worker(server_private, client_public, udp_port) {
        Ok(worker) => {
            *out_handle = Box::into_raw(Box::new(AuroraEMProxyHandle { worker }));
            AURORA_EMPROXY_OK
        }
        Err(error) => error,
    }
}

#[no_mangle]
/// Copies the current counter snapshot into caller-owned storage.
///
/// # Safety
/// `handle` must be a live handle returned by `aurora_emproxy_start` and must not be stopped
/// concurrently. `out_stats` must reference writable, exclusively accessed storage.
pub unsafe extern "C" fn aurora_emproxy_get_stats(
    handle: *const AuroraEMProxyHandle,
    out_stats: *mut AuroraEMProxyStats,
) -> i32 {
    if handle.is_null() || out_stats.is_null() {
        return AURORA_EMPROXY_ERROR_NULL_ARGUMENT;
    }

    let counters = &(*handle).worker.counters;
    *out_stats = AuroraEMProxyStats {
        received_udp: counters.received_udp.load(Ordering::Relaxed),
        authenticated_ipv4: counters.authenticated_ipv4.load(Ordering::Relaxed),
        reflected_ipv4: counters.reflected_ipv4.load(Ordering::Relaxed),
        rejected_packets: counters.rejected_packets.load(Ordering::Relaxed),
        last_rejection: counters.last_rejection.load(Ordering::Relaxed),
        tcp_resets: counters.tcp_resets.load(Ordering::Relaxed),
        pairing_port_resets: counters.pairing_port_resets.load(Ordering::Relaxed),
    };
    AURORA_EMPROXY_OK
}

#[no_mangle]
/// Stops the responder and clears the caller's handle.
///
/// # Safety
/// `handle` must reference writable, exclusively accessed storage containing a live handle
/// returned by `aurora_emproxy_start`. No other call may use that handle concurrently.
pub unsafe extern "C" fn aurora_emproxy_stop(handle: *mut *mut AuroraEMProxyHandle) -> i32 {
    if handle.is_null() || (*handle).is_null() {
        return AURORA_EMPROXY_ERROR_NULL_ARGUMENT;
    }

    let owned = Box::from_raw(*handle);
    *handle = std::ptr::null_mut();
    let sent = owned.worker.stop_sender.send(()).is_ok();
    let joined = owned.worker.join_handle.join().is_ok();
    if sent && joined {
        AURORA_EMPROXY_OK
    } else {
        AURORA_EMPROXY_ERROR_STOP
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs::File;
    use std::io::Read;

    fn random_array() -> [u8; 32] {
        let mut bytes = [0_u8; 32];
        File::open("/dev/urandom")
            .unwrap()
            .read_exact(&mut bytes)
            .unwrap();
        bytes
    }

    fn test_packet(source_port: u16, destination_port: u16) -> Vec<u8> {
        let mut packet = vec![0_u8; 40];
        packet[0] = 0x45;
        let packet_length = packet.len() as u16;
        packet[2..4].copy_from_slice(&packet_length.to_be_bytes());
        packet[6..8].copy_from_slice(&0x4000_u16.to_be_bytes());
        packet[8] = 64;
        packet[9] = 6;
        packet[12..16].copy_from_slice(&CLIENT_ADDRESS);
        packet[16..20].copy_from_slice(&PROXY_ADDRESS);
        packet[20..22].copy_from_slice(&source_port.to_be_bytes());
        packet[22..24].copy_from_slice(&destination_port.to_be_bytes());
        packet[32] = 0x50;
        packet[33] = 0x02;
        packet[34..36].copy_from_slice(&65_535_u16.to_be_bytes());

        let tcp_sum = !tcp_checksum(&packet, 20, 40);
        packet[36..38].copy_from_slice(&tcp_sum.to_be_bytes());
        let ip_sum = !internet_checksum(&packet[..20]);
        packet[10..12].copy_from_slice(&ip_sum.to_be_bytes());
        packet
    }

    fn linked_tunnels() -> (Tunn, Tunn) {
        let client_private = StaticSecret::from(random_array());
        let client_public = PublicKey::from(&client_private);
        let server_private = StaticSecret::from(random_array());
        let server_public = PublicKey::from(&server_private);
        (
            Tunn::new(client_private, server_public, None, None, 1, None),
            Tunn::new(server_private, client_public, None, None, 2, None),
        )
    }

    fn establish(client: &mut Tunn, server: &mut Tunn) {
        let mut first = vec![0_u8; 2048];
        let mut second = vec![0_u8; 2048];
        let initiation = match client.format_handshake_initiation(&mut first, false) {
            TunnResult::WriteToNetwork(packet) => packet,
            _ => panic!("client did not create a handshake"),
        };
        let response = match server.decapsulate(None, initiation, &mut second) {
            TunnResult::WriteToNetwork(packet) => packet,
            _ => panic!("server did not answer the handshake"),
        };
        let keepalive = match client.decapsulate(None, response, &mut first) {
            TunnResult::WriteToNetwork(packet) => packet,
            _ => panic!("client did not finish the handshake"),
        };
        assert!(matches!(
            server.decapsulate(None, keepalive, &mut second),
            TunnResult::Done
        ));
    }

    #[test]
    fn wireguard_round_trip_remaps_pairing_tcp() {
        let (mut client, mut server) = linked_tunnels();
        establish(&mut client, &mut server);
        let original = test_packet(52_000, PAIRING_PORT);
        let mut client_buffer = vec![0_u8; 2048];
        let mut server_buffer = vec![0_u8; 2048];

        let encrypted = match client.encapsulate(&original, &mut client_buffer) {
            TunnResult::WriteToNetwork(packet) => packet,
            _ => panic!("client did not encrypt the packet"),
        };
        let plaintext = match server.decapsulate(None, encrypted, &mut server_buffer) {
            TunnResult::WriteToTunnelV4(packet, _) => packet,
            _ => panic!("server did not decrypt the packet"),
        };
        assert!(remap_pairing_packet(plaintext));
        let returned = match server.encapsulate(plaintext, &mut client_buffer) {
            TunnResult::WriteToNetwork(packet) => packet,
            _ => panic!("server did not encrypt the returned packet"),
        };
        let remapped = match client.decapsulate(None, returned, &mut server_buffer) {
            TunnResult::WriteToTunnelV4(packet, _) => packet,
            _ => panic!("client did not decrypt the returned packet"),
        };

        assert_eq!(&remapped[12..16], &PROXY_ADDRESS);
        assert_eq!(&remapped[16..20], &CLIENT_ADDRESS);
        assert_eq!(
            u16::from_be_bytes([remapped[22], remapped[23]]),
            PAIRING_PORT
        );
        assert_eq!(internet_checksum(&remapped[..20]), 0xffff);
        assert_eq!(tcp_checksum(remapped, 20, 40), 0xffff);
    }

    #[test]
    fn maximum_ipv4_packet_fits_encryption_buffer() {
        let (mut client, mut server) = linked_tunnels();
        establish(&mut client, &mut server);
        let packet = vec![0_u8; u16::MAX as usize];
        let mut encrypted = vec![0_u8; MAX_WIREGUARD_PACKET_SIZE];

        let encrypted_packet = match client.encapsulate(&packet, &mut encrypted) {
            TunnResult::WriteToNetwork(packet) => packet,
            _ => panic!("client did not encrypt the maximum packet"),
        };
        assert!(encrypted_packet.len() <= MAX_WIREGUARD_PACKET_SIZE);
    }

    #[test]
    fn filter_accepts_negotiated_ports_and_rejects_invalid_packets() {
        let mut negotiated = test_packet(52_000, 54_673);
        assert!(remap_pairing_packet(&mut negotiated));
        let mut return_packet = test_packet(54_673, 52_000);
        assert!(remap_pairing_packet(&mut return_packet));
        let mut unrelated = test_packet(52_000, 443);
        assert!(!remap_pairing_packet(&mut unrelated));

        let mut fragmented = test_packet(52_000, PAIRING_PORT);
        fragmented[6..8].copy_from_slice(&0x2000_u16.to_be_bytes());
        fragmented[10..12].fill(0);
        let ip_sum = !internet_checksum(&fragmented[..20]);
        fragmented[10..12].copy_from_slice(&ip_sum.to_be_bytes());
        assert!(!remap_pairing_packet(&mut fragmented));

        assert!(!remap_pairing_packet(&mut [0_u8; 12]));
    }

    #[test]
    fn responder_restart_recovers_the_existing_client_session() {
        let client_key = random_array();
        let server_key = random_array();
        let client_public = PublicKey::from(&StaticSecret::from(client_key));
        let server_public = PublicKey::from(&StaticSecret::from(server_key));
        let mut client = Tunn::new(StaticSecret::from(client_key), server_public, None, None, 1, None);
        let mut server = Tunn::new(StaticSecret::from(server_key), client_public, None, None, 0, None);
        establish(&mut client, &mut server);
        let mut client_buffer = vec![0; 2048];
        let stale = match client.encapsulate(&test_packet(52_000, PAIRING_PORT), &mut client_buffer) {
            TunnResult::WriteToNetwork(packet) => packet.to_vec(),
            _ => panic!("client must have an established session"),
        };
        server = Tunn::new(StaticSecret::from(server_key), client_public, None, None, 0, None);
        let sender = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        let receiver = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        receiver.set_read_timeout(Some(Duration::from_secs(1))).unwrap();
        let endpoint = receiver.local_addr().unwrap();
        let counters = Counters::default();
        let mut decrypted = vec![0; 2048];
        let mut encrypted = vec![0; 2048];
        assert!(!process_datagram(&sender, &mut server, endpoint, &stale, &mut decrypted, &mut encrypted, &counters));
        assert_eq!(counters.last_rejection.load(Ordering::Relaxed), 2);
        let mut incoming = vec![0; 2048];
        let length = receiver.recv(&mut incoming).unwrap();
        let response = match client.decapsulate(None, &incoming[..length], &mut client_buffer) {
            TunnResult::WriteToNetwork(packet) => packet.to_vec(),
            _ => panic!("client must answer the recovery handshake"),
        };
        process_datagram(&sender, &mut server, endpoint, &response, &mut decrypted, &mut encrypted, &counters);
        let length = receiver.recv(&mut incoming).unwrap();
        assert!(matches!(client.decapsulate(None, &incoming[..length], &mut client_buffer), TunnResult::Done));
        let fresh = match client.encapsulate(&test_packet(52_000, PAIRING_PORT), &mut client_buffer) {
            TunnResult::WriteToNetwork(packet) => packet.to_vec(),
            _ => panic!("client must use the recovered session"),
        };
        assert!(process_datagram(&sender, &mut server, endpoint, &fresh, &mut decrypted, &mut encrypted, &counters));
        assert_eq!(counters.reflected_ipv4.load(Ordering::Relaxed), 1);
        assert_eq!(counters.tcp_resets.load(Ordering::Relaxed), 0);
        let mut reset = test_packet(PAIRING_PORT, 52_000);
        reset[33] = 0x14;
        reset[36..38].fill(0);
        let checksum = !tcp_checksum(&reset, 20, 40);
        reset[36..38].copy_from_slice(&checksum.to_be_bytes());
        let reset_data = match client.encapsulate(&reset, &mut client_buffer) {
            TunnResult::WriteToNetwork(packet) => packet.to_vec(),
            _ => panic!("client must encrypt reset"),
        };
        assert!(process_datagram(&sender, &mut server, endpoint, &reset_data, &mut decrypted, &mut encrypted, &counters));
        assert_eq!(counters.tcp_resets.load(Ordering::Relaxed), 1);
        assert_eq!(counters.pairing_port_resets.load(Ordering::Relaxed), 1);
    }

    #[test]
    fn worker_start_and_stop_owns_only_loopback_port() {
        let probe = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        let port = probe.local_addr().unwrap().port();
        drop(probe);
        let server_private = StaticSecret::from(random_array());
        let client_private = StaticSecret::from(random_array());
        let client_public = PublicKey::from(&client_private);
        let worker = start_worker(server_private, client_public, port).unwrap();
        assert_eq!(worker.stop_sender.send(()), Ok(()));
        assert!(worker.join_handle.join().is_ok());
    }
}
