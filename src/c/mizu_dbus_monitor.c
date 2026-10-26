#include "mizu_dbus_monitor.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>
#include <poll.h>
#include <dbus/dbus.h>

static pthread_t s_thread;
static pthread_mutex_t s_mutex = PTHREAD_MUTEX_INITIALIZER;
static int s_running = 0;
static int s_wake_fd = -1;
static int s_shutdown_pipe[2] = { -1, -1 };

static DBusConnection *s_session_conn = NULL;
static DBusConnection *s_system_conn = NULL;

static MizuMprisSnapshot s_mpris_snap = {
    .mpris_state = MIZU_MPRIS_STOPPED,
    .mpris_track = {0},
    .mpris_title = {0},
    .mpris_artist = {0},
    .mpris_art_url = {0},
    .version = 0,
};

static int s_network_dirty = 0;
static int s_bluetooth_dirty = 0;
static char s_active_player[128] = {0};

static void notify_wake(void) {
    int fd = -1;
    pthread_mutex_lock(&s_mutex);
    fd = s_wake_fd;
    pthread_mutex_unlock(&s_mutex);

    if (fd >= 0) {
        uint64_t val = 1;
        ssize_t res = write(fd, &val, sizeof(val));
        (void)res;
    }
}

static void parse_mpris_metadata(DBusMessageIter *dict_iter, MizuMprisSnapshot *snap) {
    snap->mpris_title[0] = '\0';
    snap->mpris_artist[0] = '\0';
    snap->mpris_art_url[0] = '\0';

    DBusMessageIter entry_iter;
    for (; dbus_message_iter_get_arg_type(dict_iter) == DBUS_TYPE_DICT_ENTRY; dbus_message_iter_next(dict_iter)) {
        dbus_message_iter_recurse(dict_iter, &entry_iter);
        if (dbus_message_iter_get_arg_type(&entry_iter) != DBUS_TYPE_STRING) continue;
        const char *key = NULL;
        dbus_message_iter_get_basic(&entry_iter, &key);
        if (!key) continue;

        dbus_message_iter_next(&entry_iter);
        if (dbus_message_iter_get_arg_type(&entry_iter) != DBUS_TYPE_VARIANT) continue;

        DBusMessageIter var_iter;
        dbus_message_iter_recurse(&entry_iter, &var_iter);
        int var_type = dbus_message_iter_get_arg_type(&var_iter);

        if (strcmp(key, "xesam:title") == 0 && var_type == DBUS_TYPE_STRING) {
            const char *val = NULL;
            dbus_message_iter_get_basic(&var_iter, &val);
            if (val) {
                strncpy(snap->mpris_title, val, sizeof(snap->mpris_title) - 1);
                snap->mpris_title[sizeof(snap->mpris_title) - 1] = '\0';
            }
        } else if (strcmp(key, "mpris:artUrl") == 0 && var_type == DBUS_TYPE_STRING) {
            const char *val = NULL;
            dbus_message_iter_get_basic(&var_iter, &val);
            if (val) {
                strncpy(snap->mpris_art_url, val, sizeof(snap->mpris_art_url) - 1);
                snap->mpris_art_url[sizeof(snap->mpris_art_url) - 1] = '\0';
            }
        } else if (strcmp(key, "xesam:artist") == 0) {
            if (var_type == DBUS_TYPE_STRING) {
                const char *val = NULL;
                dbus_message_iter_get_basic(&var_iter, &val);
                if (val) {
                    strncpy(snap->mpris_artist, val, sizeof(snap->mpris_artist) - 1);
                    snap->mpris_artist[sizeof(snap->mpris_artist) - 1] = '\0';
                }
            } else if (var_type == DBUS_TYPE_ARRAY) {
                DBusMessageIter arr_iter;
                dbus_message_iter_recurse(&var_iter, &arr_iter);
                if (dbus_message_iter_get_arg_type(&arr_iter) == DBUS_TYPE_STRING) {
                    const char *val = NULL;
                    dbus_message_iter_get_basic(&arr_iter, &val);
                    if (val) {
                        strncpy(snap->mpris_artist, val, sizeof(snap->mpris_artist) - 1);
                        snap->mpris_artist[sizeof(snap->mpris_artist) - 1] = '\0';
                    }
                }
            }
        }
    }

    if (snap->mpris_artist[0] != '\0' && snap->mpris_title[0] != '\0') {
        snprintf(snap->mpris_track, sizeof(snap->mpris_track), "%s - %s", snap->mpris_artist, snap->mpris_title);
    } else if (snap->mpris_title[0] != '\0') {
        strncpy(snap->mpris_track, snap->mpris_title, sizeof(snap->mpris_track) - 1);
        snap->mpris_track[sizeof(snap->mpris_track) - 1] = '\0';
    } else if (snap->mpris_artist[0] != '\0') {
        strncpy(snap->mpris_track, snap->mpris_artist, sizeof(snap->mpris_track) - 1);
        snap->mpris_track[sizeof(snap->mpris_track) - 1] = '\0';
    } else {
        snap->mpris_track[0] = '\0';
    }
}

static void parse_mpris_properties(DBusMessageIter *dict_iter, MizuMprisSnapshot *snap) {
    DBusMessageIter entry_iter;
    for (; dbus_message_iter_get_arg_type(dict_iter) == DBUS_TYPE_DICT_ENTRY; dbus_message_iter_next(dict_iter)) {
        dbus_message_iter_recurse(dict_iter, &entry_iter);
        if (dbus_message_iter_get_arg_type(&entry_iter) != DBUS_TYPE_STRING) continue;
        const char *key = NULL;
        dbus_message_iter_get_basic(&entry_iter, &key);
        if (!key) continue;

        dbus_message_iter_next(&entry_iter);
        if (dbus_message_iter_get_arg_type(&entry_iter) != DBUS_TYPE_VARIANT) continue;

        DBusMessageIter var_iter;
        dbus_message_iter_recurse(&entry_iter, &var_iter);
        int var_type = dbus_message_iter_get_arg_type(&var_iter);

        if (strcmp(key, "PlaybackStatus") == 0 && var_type == DBUS_TYPE_STRING) {
            const char *val = NULL;
            dbus_message_iter_get_basic(&var_iter, &val);
            if (val) {
                if (strcmp(val, "Playing") == 0) {
                    snap->mpris_state = MIZU_MPRIS_PLAYING;
                } else if (strcmp(val, "Paused") == 0) {
                    snap->mpris_state = MIZU_MPRIS_PAUSED;
                } else {
                    snap->mpris_state = MIZU_MPRIS_STOPPED;
                }
            }
        } else if (strcmp(key, "Metadata") == 0 && var_type == DBUS_TYPE_ARRAY) {
            DBusMessageIter meta_iter;
            dbus_message_iter_recurse(&var_iter, &meta_iter);
            parse_mpris_metadata(&meta_iter, snap);
        }
    }
}

static void query_player_locked(DBusConnection *conn, const char *dest) {
    if (!conn || !dest) return;
    DBusMessage *msg = dbus_message_new_method_call(dest, "/org/mpris/MediaPlayer2",
                                                    "org.freedesktop.DBus.Properties", "GetAll");
    if (!msg) return;
    const char *iface = "org.mpris.MediaPlayer2.Player";
    dbus_message_append_args(msg, DBUS_TYPE_STRING, &iface, DBUS_TYPE_INVALID);

    DBusPendingCall *pending = NULL;
    if (!dbus_connection_send_with_reply(conn, msg, &pending, 1000) || !pending) {
        dbus_message_unref(msg);
        return;
    }
    dbus_message_unref(msg);
    dbus_connection_flush(conn);

    dbus_pending_call_block(pending);
    DBusMessage *reply = dbus_pending_call_steal_reply(pending);
    dbus_pending_call_unref(pending);
    if (!reply) return;

    DBusMessageIter args;
    if (dbus_message_iter_init(reply, &args) &&
        dbus_message_iter_get_arg_type(&args) == DBUS_TYPE_ARRAY) {
        DBusMessageIter dict_iter;
        dbus_message_iter_recurse(&args, &dict_iter);

        pthread_mutex_lock(&s_mutex);
        strncpy(s_active_player, dest, sizeof(s_active_player) - 1);
        s_active_player[sizeof(s_active_player) - 1] = '\0';
        parse_mpris_properties(&dict_iter, &s_mpris_snap);
        s_mpris_snap.version++;
        pthread_mutex_unlock(&s_mutex);

        notify_wake();
    }
    dbus_message_unref(reply);
}

static void scan_initial_players(DBusConnection *conn) {
    if (!conn) return;
    DBusMessage *msg = dbus_message_new_method_call("org.freedesktop.DBus", "/org/freedesktop/DBus",
                                                    "org.freedesktop.DBus", "ListNames");
    if (!msg) return;
    DBusPendingCall *pending = NULL;
    if (!dbus_connection_send_with_reply(conn, msg, &pending, 1000) || !pending) {
        dbus_message_unref(msg);
        return;
    }
    dbus_message_unref(msg);
    dbus_connection_flush(conn);

    dbus_pending_call_block(pending);
    DBusMessage *reply = dbus_pending_call_steal_reply(pending);
    dbus_pending_call_unref(pending);
    if (!reply) return;

    DBusMessageIter args;
    if (dbus_message_iter_init(reply, &args) &&
        dbus_message_iter_get_arg_type(&args) == DBUS_TYPE_ARRAY) {
        DBusMessageIter arr_iter;
        dbus_message_iter_recurse(&args, &arr_iter);
        while (dbus_message_iter_get_arg_type(&arr_iter) == DBUS_TYPE_STRING) {
            const char *name = NULL;
            dbus_message_iter_get_basic(&arr_iter, &name);
            if (name && strncmp(name, "org.mpris.MediaPlayer2.", 23) == 0) {
                query_player_locked(conn, name);
                break;
            }
            dbus_message_iter_next(&arr_iter);
        }
    }
    dbus_message_unref(reply);
}

static DBusHandlerResult session_filter(DBusConnection *conn, DBusMessage *msg, void *user_data) {
    (void)user_data;

    if (dbus_message_is_signal(msg, "org.freedesktop.DBus.Properties", "PropertiesChanged")) {
        const char *path = dbus_message_get_path(msg);
        if (!path || strcmp(path, "/org/mpris/MediaPlayer2") != 0) {
            return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
        }

        DBusMessageIter args;
        if (!dbus_message_iter_init(msg, &args)) return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
        if (dbus_message_iter_get_arg_type(&args) != DBUS_TYPE_STRING) return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
        const char *iface = NULL;
        dbus_message_iter_get_basic(&args, &iface);
        if (!iface || strcmp(iface, "org.mpris.MediaPlayer2.Player") != 0) {
            return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
        }

        dbus_message_iter_next(&args);
        if (dbus_message_iter_get_arg_type(&args) != DBUS_TYPE_ARRAY) return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;

        DBusMessageIter dict_iter;
        dbus_message_iter_recurse(&args, &dict_iter);

        pthread_mutex_lock(&s_mutex);
        const char *sender = dbus_message_get_sender(msg);
        if (sender) {
            strncpy(s_active_player, sender, sizeof(s_active_player) - 1);
            s_active_player[sizeof(s_active_player) - 1] = '\0';
        }
        parse_mpris_properties(&dict_iter, &s_mpris_snap);
        s_mpris_snap.version++;
        pthread_mutex_unlock(&s_mutex);

        notify_wake();
        return DBUS_HANDLER_RESULT_HANDLED;
    }

    if (dbus_message_is_signal(msg, "org.freedesktop.DBus", "NameOwnerChanged")) {
        const char *name = NULL;
        const char *old_owner = NULL;
        const char *new_owner = NULL;
        DBusError err;
        dbus_error_init(&err);
        if (dbus_message_get_args(msg, &err,
                                  DBUS_TYPE_STRING, &name,
                                  DBUS_TYPE_STRING, &old_owner,
                                  DBUS_TYPE_STRING, &new_owner,
                                  DBUS_TYPE_INVALID)) {
            if (name && strncmp(name, "org.mpris.MediaPlayer2.", 23) == 0) {
                if (new_owner && new_owner[0] != '\0') {
                    // New player registered
                    query_player_locked(conn, name);
                } else if (new_owner && new_owner[0] == '\0') {
                    // Player exited
                    pthread_mutex_lock(&s_mutex);
                    s_mpris_snap.mpris_state = MIZU_MPRIS_STOPPED;
                    s_mpris_snap.mpris_track[0] = '\0';
                    s_mpris_snap.mpris_title[0] = '\0';
                    s_mpris_snap.mpris_artist[0] = '\0';
                    s_mpris_snap.mpris_art_url[0] = '\0';
                    s_active_player[0] = '\0';
                    s_mpris_snap.version++;
                    pthread_mutex_unlock(&s_mutex);
                    notify_wake();
                }
            }
        }
        dbus_error_free(&err);
        return DBUS_HANDLER_RESULT_HANDLED;
    }

    return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
}

static DBusHandlerResult system_filter(DBusConnection *conn, DBusMessage *msg, void *user_data) {
    (void)conn;
    (void)user_data;
    const char *path = dbus_message_get_path(msg);
    const char *iface = dbus_message_get_interface(msg);
    const char *sender = dbus_message_get_sender(msg);

    bool is_net = false;
    bool is_bt = false;

    if (path && strstr(path, "NetworkManager") != NULL) is_net = true;
    if (iface && strstr(iface, "NetworkManager") != NULL) is_net = true;
    if (sender && strstr(sender, "NetworkManager") != NULL) is_net = true;

    if (path && (strstr(path, "bluez") != NULL || strncmp(path, "/org/bluez", 10) == 0)) is_bt = true;
    if (iface && (strstr(iface, "bluez") != NULL || strstr(iface, "Bluetooth") != NULL)) is_bt = true;
    if (sender && strstr(sender, "bluez") != NULL) is_bt = true;

    if (is_net) {
        pthread_mutex_lock(&s_mutex);
        s_network_dirty = 1;
        pthread_mutex_unlock(&s_mutex);
        notify_wake();
        return DBUS_HANDLER_RESULT_HANDLED;
    }

    if (is_bt) {
        pthread_mutex_lock(&s_mutex);
        s_bluetooth_dirty = 1;
        pthread_mutex_unlock(&s_mutex);
        notify_wake();
        return DBUS_HANDLER_RESULT_HANDLED;
    }

    return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
}

static void *monitor_worker(void *arg) {
    (void)arg;
    DBusError err;

    // Connect to session bus
    dbus_error_init(&err);
    s_session_conn = dbus_bus_get_private(DBUS_BUS_SESSION, &err);
    if (!s_session_conn || dbus_error_is_set(&err)) {
        dbus_error_free(&err);
        s_session_conn = NULL;
    } else {
        dbus_bus_add_match(s_session_conn,
            "type='signal',interface='org.freedesktop.DBus.Properties',member='PropertiesChanged',path='/org/mpris/MediaPlayer2'",
            NULL);
        dbus_bus_add_match(s_session_conn,
            "type='signal',interface='org.freedesktop.DBus',member='NameOwnerChanged'",
            NULL);
        dbus_connection_add_filter(s_session_conn, session_filter, NULL, NULL);
        scan_initial_players(s_session_conn);
    }

    // Connect to system bus
    dbus_error_init(&err);
    s_system_conn = dbus_bus_get_private(DBUS_BUS_SYSTEM, &err);
    if (!s_system_conn || dbus_error_is_set(&err)) {
        dbus_error_free(&err);
        s_system_conn = NULL;
    } else {
        dbus_bus_add_match(s_system_conn,
            "type='signal',sender='org.freedesktop.NetworkManager'",
            NULL);
        dbus_bus_add_match(s_system_conn,
            "type='signal',sender='org.bluez'",
            NULL);
        dbus_connection_add_filter(s_system_conn, system_filter, NULL, NULL);
    }

    while (s_running) {
        struct pollfd pfd;
        pfd.fd = s_shutdown_pipe[0];
        pfd.events = POLLIN;
        pfd.revents = 0;

        int poll_timeout = 80;
        int poll_res = poll(&pfd, 1, poll_timeout);
        if (poll_res > 0 && (pfd.revents & POLLIN)) {
            char buf[16];
            ssize_t n = read(s_shutdown_pipe[0], buf, sizeof(buf));
            (void)n;
            break;
        }

        if (s_session_conn) {
            dbus_connection_read_write_dispatch(s_session_conn, 0);
        }
        if (s_system_conn) {
            dbus_connection_read_write_dispatch(s_system_conn, 0);
        }
    }

    if (s_session_conn) {
        dbus_connection_close(s_session_conn);
        dbus_connection_unref(s_session_conn);
        s_session_conn = NULL;
    }
    if (s_system_conn) {
        dbus_connection_close(s_system_conn);
        dbus_connection_unref(s_system_conn);
        s_system_conn = NULL;
    }

    return NULL;
}

int mizu_dbus_monitor_init(int wake_fd) {
    pthread_mutex_lock(&s_mutex);
    if (s_running) {
        s_wake_fd = wake_fd;
        pthread_mutex_unlock(&s_mutex);
        return 0;
    }
    s_wake_fd = wake_fd;
    s_running = 1;
    s_network_dirty = 0;
    s_bluetooth_dirty = 0;

    if (pipe(s_shutdown_pipe) != 0) {
        s_shutdown_pipe[0] = -1;
        s_shutdown_pipe[1] = -1;
    }
    pthread_mutex_unlock(&s_mutex);

    if (pthread_create(&s_thread, NULL, monitor_worker, NULL) != 0) {
        s_running = 0;
        if (s_shutdown_pipe[0] >= 0) close(s_shutdown_pipe[0]);
        if (s_shutdown_pipe[1] >= 0) close(s_shutdown_pipe[1]);
        s_shutdown_pipe[0] = -1;
        s_shutdown_pipe[1] = -1;
        return -1;
    }

    return 0;
}

void mizu_dbus_monitor_set_wake_fd(int wake_fd) {
    pthread_mutex_lock(&s_mutex);
    s_wake_fd = wake_fd;
    pthread_mutex_unlock(&s_mutex);
}

bool mizu_dbus_monitor_get_mpris(MizuMprisSnapshot *out) {
    if (!out) return false;
    pthread_mutex_lock(&s_mutex);
    *out = s_mpris_snap;
    pthread_mutex_unlock(&s_mutex);
    return true;
}

bool mizu_dbus_monitor_check_network_dirty(void) {
    pthread_mutex_lock(&s_mutex);
    bool d = (s_network_dirty != 0);
    s_network_dirty = 0;
    pthread_mutex_unlock(&s_mutex);
    return d;
}

bool mizu_dbus_monitor_check_bluetooth_dirty(void) {
    pthread_mutex_lock(&s_mutex);
    bool d = (s_bluetooth_dirty != 0);
    s_bluetooth_dirty = 0;
    pthread_mutex_unlock(&s_mutex);
    return d;
}

void mizu_dbus_monitor_trigger_mpris_refresh(void) {
    pthread_mutex_lock(&s_mutex);
    if (s_session_conn) {
        scan_initial_players(s_session_conn);
    }
    pthread_mutex_unlock(&s_mutex);
}

void mizu_dbus_monitor_deinit(void) {
    pthread_mutex_lock(&s_mutex);
    if (!s_running) {
        pthread_mutex_unlock(&s_mutex);
        return;
    }
    s_running = 0;
    if (s_shutdown_pipe[1] >= 0) {
        ssize_t n = write(s_shutdown_pipe[1], "q", 1);
        (void)n;
    }
    pthread_mutex_unlock(&s_mutex);

    pthread_join(s_thread, NULL);

    if (s_shutdown_pipe[0] >= 0) close(s_shutdown_pipe[0]);
    if (s_shutdown_pipe[1] >= 0) close(s_shutdown_pipe[1]);
    s_shutdown_pipe[0] = -1;
    s_shutdown_pipe[1] = -1;
}
