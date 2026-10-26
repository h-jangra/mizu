#ifndef MIZU_DBUS_MONITOR_H
#define MIZU_DBUS_MONITOR_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    MIZU_MPRIS_STOPPED = 0,
    MIZU_MPRIS_PAUSED = 1,
    MIZU_MPRIS_PLAYING = 2,
} MizuMprisState;

typedef struct {
    int mpris_state;            // MizuMprisState
    char mpris_track[128];       // "Artist - Title" or "Title"
    char mpris_title[128];
    char mpris_artist[128];
    char mpris_art_url[256];
    uint32_t version;            // Monotonically increasing revision number
} MizuMprisSnapshot;

// Initialize the background D-Bus monitor thread for MPRIS, NetworkManager, and BlueZ.
// If wake_fd >= 0, a 64-bit counter is written to it upon state changes to wake the UI event loop.
int mizu_dbus_monitor_init(int wake_fd);

// Set or update the wake_fd.
void mizu_dbus_monitor_set_wake_fd(int wake_fd);

// Thread-safe copy of the latest MPRIS snapshot. Returns true on success.
bool mizu_dbus_monitor_get_mpris(MizuMprisSnapshot *out);

// Check if NetworkManager signaled state changes since the last check. Resets the dirty flag.
bool mizu_dbus_monitor_check_network_dirty(void);

// Check if BlueZ signaled state changes since the last check. Resets the dirty flag.
bool mizu_dbus_monitor_check_bluetooth_dirty(void);

// Asynchronously request a refresh of active MPRIS players.
void mizu_dbus_monitor_trigger_mpris_refresh(void);

// Cleanly stop the background monitor thread and close D-Bus connections.
void mizu_dbus_monitor_deinit(void);

#ifdef __cplusplus
}
#endif

#endif // MIZU_DBUS_MONITOR_H
