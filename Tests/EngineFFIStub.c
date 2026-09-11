#include "idevice.h"
#include <assert.h>
#include <stdlib.h>

// Test the Swift owner's lifetime against the real FFI declarations, without a device.
static int counts[8];
static int fail_set;
int aurora_test_count(int index) { assert(index >= 0 && index < 8); return counts[index]; }
void aurora_test_fail_set(void) { fail_set = 1; }
void aurora_test_fail_eof(void) { fail_set = 2; }
void idevice_set_global_timeout(uint64_t seconds) { assert(seconds > 0); }
struct IdeviceFfiError *rp_pairing_file_read(const char *path, struct RpPairingFileHandle **out) {
    assert(path); *out = malloc(1); return NULL;
}
void rp_pairing_file_free(struct RpPairingFileHandle *handle) { free(handle); }
struct IdeviceFfiError *tunnel_create_rppairing(const idevice_sockaddr *address,
    idevice_socklen_t length, const char *hostname, struct RpPairingFileHandle *pairing,
    const char *(*callback)(void *), void *context, struct AdapterHandle **adapter,
    struct RsdHandshakeHandle **handshake) {
    assert(address && length && hostname && pairing && !callback && !context);
    counts[0]++; *adapter = malloc(1); *handshake = malloc(1); return NULL;
}
struct IdeviceFfiError *remote_server_connect_rsd(struct AdapterHandle *adapter,
    struct RsdHandshakeHandle *handshake, struct RemoteServerHandle **server) {
    assert(adapter && handshake); *server = malloc(1); return NULL;
}
struct IdeviceFfiError *location_simulation_new(struct RemoteServerHandle *server,
    struct LocationSimulationHandle **simulation) {
    assert(server); *simulation = malloc(1); return NULL;
}
struct IdeviceFfiError *location_simulation_set(struct LocationSimulationHandle *simulation,
    double latitude, double longitude) {
    assert(simulation && latitude >= -90 && latitude <= 90 && longitude >= -180 && longitude <= 180);
    counts[1]++;
    if (fail_set) {
        int failure = fail_set;
        fail_set = 0;
        struct IdeviceFfiError *error = calloc(1, sizeof(struct IdeviceFfiError));
        error->code = 42; error->sub_code = 7;
        error->message = failure == 2
            ? "Socket(Custom { kind: UnexpectedEof, error: PRIVATE_PEER_DATA })"
            : "timed out: PRIVATE_PEER_DATA";
        return error;
    }
    return NULL;
}
struct IdeviceFfiError *location_simulation_clear(struct LocationSimulationHandle *simulation) {
    assert(simulation); counts[2]++; return NULL;
}
void location_simulation_free(struct LocationSimulationHandle *handle) {
    assert(handle && counts[3] == counts[6]); counts[3]++; free(handle);
}
void remote_server_free(struct RemoteServerHandle *handle) {
    assert(handle && counts[3] == counts[4] + 1); counts[4]++; free(handle);
}
void rsd_handshake_free(struct RsdHandshakeHandle *handle) {
    assert(handle && counts[4] == counts[5] + 1); counts[5]++; free(handle);
}
void adapter_free(struct AdapterHandle *handle) {
    assert(handle && counts[5] == counts[6] + 1); counts[6]++; free(handle);
}
void idevice_error_free(struct IdeviceFfiError *error) { assert(error); counts[7]++; free(error); }
