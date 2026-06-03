#ifndef MOSH_CLIENT_FFI_H
#define MOSH_CLIENT_FFI_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

#define MOSH_EXPORT __attribute__((visibility("default")))

typedef struct MoshClient MoshClient;

MOSH_EXPORT MoshClient* mosh_client_create(
    const char* host,
    int port,
    const char* key,
    int term_width,
    int term_height
);

MOSH_EXPORT int mosh_client_start(MoshClient* client);

MOSH_EXPORT void mosh_client_send_input(MoshClient* client, const uint8_t* data, int len);

MOSH_EXPORT int mosh_client_receive_output(MoshClient* client, uint8_t* buf, int max_len);

MOSH_EXPORT void mosh_client_resize(MoshClient* client, int width, int height);

MOSH_EXPORT int mosh_client_get_state(MoshClient* client);

MOSH_EXPORT int mosh_client_get_rtt(MoshClient* client);

MOSH_EXPORT int64_t mosh_client_get_last_heard(MoshClient* client);

MOSH_EXPORT void mosh_client_stop(MoshClient* client);

MOSH_EXPORT void mosh_client_destroy(MoshClient* client);

#ifdef __cplusplus
}
#endif

#endif
