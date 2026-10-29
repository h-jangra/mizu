#ifndef MIZU_TRAY_DBUS_H
#define MIZU_TRAY_DBUS_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

#define MIZU_MAX_TRAY_ITEMS 32

typedef struct {
    char service[128];
    char path[128];
    char id[64];
    char title[128];
    char icon_name[128];
    char status[32];
    char menu_path[128];
    bool is_menu;
    uint32_t pixmap_w;
    uint32_t pixmap_h;
    uint32_t pixmap_data[32 * 32]; // ARGB32 cached up to 32x32
} MizuTrayItem;

typedef void (*MizuTrayUpdateCallback)(void *userdata);

// Initializes org.kde.StatusNotifierWatcher service on session bus
int mizu_tray_dbus_init(MizuTrayUpdateCallback cb, void *userdata);

// Dispatches pending D-Bus events for the tray watcher. Pass 0 for non-blocking.
int mizu_tray_dbus_dispatch(int timeout_ms);

// Returns active item count and fills out_items array up to max_items.
int mizu_tray_get_items(MizuTrayItem *out_items, int max_items);

// Actions triggered by user clicks
void mizu_tray_item_activate(const char *service, const char *path, int32_t x, int32_t y);
void mizu_tray_item_context_menu(const char *service, const char *path, int32_t x, int32_t y);
void mizu_tray_item_secondary_activate(const char *service, const char *path, int32_t x, int32_t y);
void mizu_tray_item_scroll(const char *service, const char *path, int32_t delta, bool horizontal);

typedef struct {
    int32_t id;
    char label[128];
    bool enabled;
    bool visible;
    bool is_separator;
} MizuTrayMenuAction;

// Retrieves actions from com.canonical.dbusmenu or generates standard fallback actions
int mizu_tray_get_menu_actions(const char *service, const char *menu_path, MizuTrayMenuAction *out_actions, int max_actions);

// Triggers an action clicked by the user
void mizu_tray_trigger_action(const char *service, const char *menu_path, int32_t action_id);

// Closes connection and unregisters watcher
void mizu_tray_dbus_deinit(void);

#ifdef __cplusplus
}
#endif

#endif // MIZU_TRAY_DBUS_H
