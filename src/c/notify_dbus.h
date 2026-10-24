#ifndef MIZU_NOTIFY_DBUS_H
#define MIZU_NOTIFY_DBUS_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    uint32_t id;
    char app_name[64];
    char app_icon[128];
    char summary[128];
    char body[512];
    int32_t expire_timeout_ms;
    uint64_t timestamp;
} MizuDbusNotification;

typedef void (*MizuNotifyCallback)(const MizuDbusNotification *notif, void *userdata);

// Initializes D-Bus and requests org.freedesktop.Notifications
// Returns 0 on success, negative error code on failure.
int mizu_dbus_notify_init(MizuNotifyCallback callback, void *userdata);

// Dispatches pending D-Bus events with timeout (ms). Pass 0 for non-blocking poll.
int mizu_dbus_notify_dispatch(int timeout_ms);

// Closes D-Bus connection and unregisters service.
void mizu_dbus_notify_deinit(void);

// Sends NotificationClosed signal
void mizu_dbus_notify_send_closed(uint32_t id, uint32_t reason);

// Emits a notification directly to the D-Bus bus
int mizu_dbus_notify_send(const char *summary, const char *body, const char *app_name, int timeout_ms);

typedef struct {
    int has_battery;
    int state;             // 1 = charging, 2 = discharging, 4 = fully charged
    double percentage;     // 0.0 to 100.0
    int64_t time_to_empty; // seconds, 0 if unknown
    int64_t time_to_full;  // seconds, 0 if unknown
    double energy_rate;    // Watts
} MizuBatteryTelemetry;

// Queries org.freedesktop.UPower for battery telemetry.
// Returns 0 on success, negative error code on failure.
int mizu_upower_get_telemetry(MizuBatteryTelemetry *out);

#ifdef __cplusplus
}
#endif

#endif // MIZU_NOTIFY_DBUS_H
