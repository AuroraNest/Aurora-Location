#ifndef AURORA_EMPROXY_H
#define AURORA_EMPROXY_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct AuroraEMProxyHandle AuroraEMProxyHandle;

typedef struct AuroraEMProxyStats {
    uint64_t received_udp;
    uint64_t authenticated_ipv4;
    uint64_t reflected_ipv4;
    uint64_t rejected_packets;
} AuroraEMProxyStats;

enum {
    AURORA_EMPROXY_OK = 0,
    AURORA_EMPROXY_ERROR_NULL_ARGUMENT = -1,
    AURORA_EMPROXY_ERROR_INVALID_PORT = -2,
    AURORA_EMPROXY_ERROR_INVALID_KEY = -3,
    AURORA_EMPROXY_ERROR_BIND = -4,
    AURORA_EMPROXY_ERROR_SOCKET = -5,
    AURORA_EMPROXY_ERROR_THREAD = -6,
    AURORA_EMPROXY_ERROR_ALREADY_STARTED = -7,
    AURORA_EMPROXY_ERROR_STOP = -8,
};

/*
 * Starts one localhost-only WireGuard responder.
 *
 * server_private_key and client_public_key each point to exactly 32 bytes.
 * out_handle must point to NULL on entry. The function binds only
 * 127.0.0.1:udp_port and returns after the UDP socket and worker are ready.
 * Key material is copied into the responder and is never logged.
 */
int32_t aurora_emproxy_start(const uint8_t *server_private_key,
                             const uint8_t *client_public_key,
                             uint16_t udp_port,
                             AuroraEMProxyHandle **out_handle);

/* Returns a snapshot containing counters only. No peer or key data is exposed. */
int32_t aurora_emproxy_get_stats(const AuroraEMProxyHandle *handle,
                                 AuroraEMProxyStats *out_stats);

/*
 * Stops and joins the worker, then stores NULL through handle.
 * Call exactly once for every successful start.
 */
int32_t aurora_emproxy_stop(AuroraEMProxyHandle **handle);

#ifdef __cplusplus
}
#endif

#endif

