#include "notify_dbus.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <dbus/dbus.h>

static DBusConnection *s_conn = NULL;
static MizuNotifyCallback s_callback = NULL;
static void *s_userdata = NULL;
static uint32_t s_next_id = 1;

static const char *INTROSPECTION_XML =
    "<!DOCTYPE node PUBLIC \"-//freedesktop//DTD D-BUS Object Introspection 1.0//EN\"\n"
    "\"http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd\">\n"
    "<node>\n"
    "  <interface name=\"org.freedesktop.DBus.Introspectable\">\n"
    "    <method name=\"Introspect\">\n"
    "      <arg name=\"data\" direction=\"out\" type=\"s\"/>\n"
    "    </method>\n"
    "  </interface>\n"
    "  <interface name=\"org.freedesktop.Notifications\">\n"
    "    <method name=\"GetCapabilities\">\n"
    "      <arg name=\"capabilities\" direction=\"out\" type=\"as\"/>\n"
    "    </method>\n"
    "    <method name=\"Notify\">\n"
    "      <arg name=\"app_name\" direction=\"in\" type=\"s\"/>\n"
    "      <arg name=\"replaces_id\" direction=\"in\" type=\"u\"/>\n"
    "      <arg name=\"app_icon\" direction=\"in\" type=\"s\"/>\n"
    "      <arg name=\"summary\" direction=\"in\" type=\"s\"/>\n"
    "      <arg name=\"body\" direction=\"in\" type=\"s\"/>\n"
    "      <arg name=\"actions\" direction=\"in\" type=\"as\"/>\n"
    "      <arg name=\"hints\" direction=\"in\" type=\"a{sv}\"/>\n"
    "      <arg name=\"expire_timeout\" direction=\"in\" type=\"i\"/>\n"
    "      <arg name=\"id\" direction=\"out\" type=\"u\"/>\n"
    "    </method>\n"
    "    <method name=\"CloseNotification\">\n"
    "      <arg name=\"id\" direction=\"in\" type=\"u\"/>\n"
    "    </method>\n"
    "    <method name=\"GetServerInformation\">\n"
    "      <arg name=\"name\" direction=\"out\" type=\"s\"/>\n"
    "      <arg name=\"vendor\" direction=\"out\" type=\"s\"/>\n"
    "      <arg name=\"version\" direction=\"out\" type=\"s\"/>\n"
    "      <arg name=\"spec_version\" direction=\"out\" type=\"s\"/>\n"
    "    </method>\n"
    "    <signal name=\"NotificationClosed\">\n"
    "      <arg name=\"id\" type=\"u\"/>\n"
    "      <arg name=\"reason\" type=\"u\"/>\n"
    "    </signal>\n"
    "    <signal name=\"ActionInvoked\">\n"
    "      <arg name=\"id\" type=\"u\"/>\n"
    "      <arg name=\"action_key\" type=\"s\"/>\n"
    "    </signal>\n"
    "  </interface>\n"
    "</node>\n";

static DBusHandlerResult handle_message(DBusConnection *conn, DBusMessage *msg, void *user_data) {
    (void)user_data;
    const char *interface = dbus_message_get_interface(msg);
    const char *member = dbus_message_get_member(msg);

    if (!interface || !member) {
        return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
    }

    if (strcmp(interface, "org.freedesktop.DBus.Introspectable") == 0 &&
        strcmp(member, "Introspect") == 0) {
        DBusMessage *reply = dbus_message_new_method_return(msg);
        if (reply) {
            dbus_message_append_args(reply, DBUS_TYPE_STRING, &INTROSPECTION_XML, DBUS_TYPE_INVALID);
            dbus_connection_send(conn, reply, NULL);
            dbus_message_unref(reply);
        }
        return DBUS_HANDLER_RESULT_HANDLED;
    }

    if (strcmp(interface, "org.freedesktop.Notifications") != 0) {
        return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
    }

    if (strcmp(member, "GetCapabilities") == 0) {
        DBusMessage *reply = dbus_message_new_method_return(msg);
        if (reply) {
            const char *caps[] = {"actions", "body", "body-markup", "icon-static", "persistence"};
            int num_caps = 5;
            DBusMessageIter iter, sub;
            dbus_message_iter_init_append(reply, &iter);
            if (dbus_message_iter_open_container(&iter, DBUS_TYPE_ARRAY, "s", &sub)) {
                for (int i = 0; i < num_caps; i++) {
                    dbus_message_iter_append_basic(&sub, DBUS_TYPE_STRING, &caps[i]);
                }
                dbus_message_iter_close_container(&iter, &sub);
            }
            dbus_connection_send(conn, reply, NULL);
            dbus_message_unref(reply);
        }
        return DBUS_HANDLER_RESULT_HANDLED;
    }

    if (strcmp(member, "GetServerInformation") == 0) {
        DBusMessage *reply = dbus_message_new_method_return(msg);
        if (reply) {
            const char *name = "Mizu Notification Daemon";
            const char *vendor = "Mizu";
            const char *version = "0.1.0";
            const char *spec_version = "1.2";
            dbus_message_append_args(reply,
                DBUS_TYPE_STRING, &name,
                DBUS_TYPE_STRING, &vendor,
                DBUS_TYPE_STRING, &version,
                DBUS_TYPE_STRING, &spec_version,
                DBUS_TYPE_INVALID);
            dbus_connection_send(conn, reply, NULL);
            dbus_message_unref(reply);
        }
        return DBUS_HANDLER_RESULT_HANDLED;
    }

    if (strcmp(member, "Notify") == 0) {
        DBusMessageIter iter;
        if (!dbus_message_iter_init(msg, &iter)) {
            return DBUS_HANDLER_RESULT_HANDLED;
        }

        const char *app_name = "";
        uint32_t replaces_id = 0;
        const char *app_icon = "";
        const char *summary = "";
        const char *body = "";
        int32_t expire_timeout = -1;

        if (dbus_message_iter_get_arg_type(&iter) == DBUS_TYPE_STRING) {
            dbus_message_iter_get_basic(&iter, &app_name);
            dbus_message_iter_next(&iter);
        }
        if (dbus_message_iter_get_arg_type(&iter) == DBUS_TYPE_UINT32) {
            dbus_message_iter_get_basic(&iter, &replaces_id);
            dbus_message_iter_next(&iter);
        }
        if (dbus_message_iter_get_arg_type(&iter) == DBUS_TYPE_STRING) {
            dbus_message_iter_get_basic(&iter, &app_icon);
            dbus_message_iter_next(&iter);
        }
        if (dbus_message_iter_get_arg_type(&iter) == DBUS_TYPE_STRING) {
            dbus_message_iter_get_basic(&iter, &summary);
            dbus_message_iter_next(&iter);
        }
        if (dbus_message_iter_get_arg_type(&iter) == DBUS_TYPE_STRING) {
            dbus_message_iter_get_basic(&iter, &body);
            dbus_message_iter_next(&iter);
        }
        // actions (as)
        if (dbus_message_iter_get_arg_type(&iter) == DBUS_TYPE_ARRAY) {
            dbus_message_iter_next(&iter);
        }
        // hints (a{sv})
        if (dbus_message_iter_get_arg_type(&iter) == DBUS_TYPE_ARRAY) {
            dbus_message_iter_next(&iter);
        }
        // expire_timeout (i)
        if (dbus_message_iter_get_arg_type(&iter) == DBUS_TYPE_INT32) {
            dbus_message_iter_get_basic(&iter, &expire_timeout);
        }

        uint32_t id = (replaces_id > 0) ? replaces_id : s_next_id++;
        if (s_next_id == 0) s_next_id = 1;

        MizuDbusNotification notif;
        memset(&notif, 0, sizeof(notif));
        notif.id = id;
        strncpy(notif.app_name, app_name ? app_name : "App", sizeof(notif.app_name) - 1);
        strncpy(notif.app_icon, app_icon ? app_icon : "", sizeof(notif.app_icon) - 1);
        strncpy(notif.summary, summary ? summary : "", sizeof(notif.summary) - 1);
        strncpy(notif.body, body ? body : "", sizeof(notif.body) - 1);
        notif.expire_timeout_ms = (expire_timeout > 0) ? expire_timeout : 4000;
        notif.timestamp = (uint64_t)time(NULL);

        if (s_callback) {
            s_callback(&notif, s_userdata);
        }

        DBusMessage *reply = dbus_message_new_method_return(msg);
        if (reply) {
            dbus_message_append_args(reply, DBUS_TYPE_UINT32, &id, DBUS_TYPE_INVALID);
            dbus_connection_send(conn, reply, NULL);
            dbus_connection_flush(conn);
            dbus_message_unref(reply);
        }
        return DBUS_HANDLER_RESULT_HANDLED;
    }

    if (strcmp(member, "CloseNotification") == 0) {
        uint32_t id = 0;
        if (dbus_message_get_args(msg, NULL, DBUS_TYPE_UINT32, &id, DBUS_TYPE_INVALID)) {
            mizu_dbus_notify_send_closed(id, 3); // 3 = closed by CloseNotification call
        }
        DBusMessage *reply = dbus_message_new_method_return(msg);
        if (reply) {
            dbus_connection_send(conn, reply, NULL);
            dbus_message_unref(reply);
        }
        return DBUS_HANDLER_RESULT_HANDLED;
    }

    return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
}

int mizu_dbus_notify_init(MizuNotifyCallback callback, void *userdata) {
    if (s_conn) return 0; // already initialized

    DBusError err;
    dbus_error_init(&err);

    s_conn = dbus_bus_get_private(DBUS_BUS_SESSION, &err);
    if (dbus_error_is_set(&err) || !s_conn) {
        dbus_error_free(&err);
        return -1;
    }

    int ret = dbus_bus_request_name(
        s_conn,
        "org.freedesktop.Notifications",
        DBUS_NAME_FLAG_REPLACE_EXISTING | DBUS_NAME_FLAG_DO_NOT_QUEUE | DBUS_NAME_FLAG_ALLOW_REPLACEMENT,
        &err
    );
    if (dbus_error_is_set(&err)) {
        dbus_error_free(&err);
        dbus_connection_close(s_conn);
        dbus_connection_unref(s_conn);
        s_conn = NULL;
        return -2;
    }

    if (ret != DBUS_REQUEST_NAME_REPLY_PRIMARY_OWNER &&
        ret != DBUS_REQUEST_NAME_REPLY_ALREADY_OWNER) {
        // If another notification daemon (e.g. mako, dunst, swaync, fnott) is running,
        // terminate competing daemons so Mizu can become the active notification service.
        system("pkill -x mako 2>/dev/null; pkill -x dunst 2>/dev/null; pkill -x swaync 2>/dev/null; pkill -x fnott 2>/dev/null");
        struct timespec ts;
        ts.tv_sec = 0;
        ts.tv_nsec = 150000000; // 150ms
        nanosleep(&ts, NULL);

        dbus_error_free(&err);
        dbus_error_init(&err);
        ret = dbus_bus_request_name(
            s_conn,
            "org.freedesktop.Notifications",
            DBUS_NAME_FLAG_REPLACE_EXISTING | DBUS_NAME_FLAG_DO_NOT_QUEUE | DBUS_NAME_FLAG_ALLOW_REPLACEMENT,
            &err
        );
        if (dbus_error_is_set(&err)) {
            dbus_error_free(&err);
            dbus_connection_close(s_conn);
            dbus_connection_unref(s_conn);
            s_conn = NULL;
            return -2;
        }
    }

    if (ret != DBUS_REQUEST_NAME_REPLY_PRIMARY_OWNER &&
        ret != DBUS_REQUEST_NAME_REPLY_ALREADY_OWNER) {
        dbus_connection_close(s_conn);
        dbus_connection_unref(s_conn);
        s_conn = NULL;
        return -3;
    }

    s_callback = callback;
    s_userdata = userdata;

    DBusObjectPathVTable vtable;
    memset(&vtable, 0, sizeof(vtable));
    vtable.message_function = handle_message;

    if (!dbus_connection_register_object_path(s_conn, "/org/freedesktop/Notifications", &vtable, userdata)) {
        mizu_dbus_notify_deinit();
        return -4;
    }

    return 0;
}

int mizu_dbus_notify_dispatch(int timeout_ms) {
    if (!s_conn) return -1;
    if (dbus_connection_read_write(s_conn, timeout_ms)) {
        while (dbus_connection_dispatch(s_conn) == DBUS_DISPATCH_DATA_REMAINS) {
            // Process all pending messages
        }
        return 0;
    }
    return -1;
}

void mizu_dbus_notify_send_closed(uint32_t id, uint32_t reason) {
    if (!s_conn) return;
    DBusMessage *sig = dbus_message_new_signal(
        "/org/freedesktop/Notifications",
        "org.freedesktop.Notifications",
        "NotificationClosed"
    );
    if (sig) {
        dbus_message_append_args(sig,
            DBUS_TYPE_UINT32, &id,
            DBUS_TYPE_UINT32, &reason,
            DBUS_TYPE_INVALID
        );
        dbus_connection_send(s_conn, sig, NULL);
        dbus_connection_flush(s_conn);
        dbus_message_unref(sig);
    }
}

void mizu_dbus_notify_deinit(void) {
    if (s_conn) {
        dbus_connection_unregister_object_path(s_conn, "/org/freedesktop/Notifications");
        dbus_connection_close(s_conn);
        dbus_connection_unref(s_conn);
        s_conn = NULL;
    }
    s_callback = NULL;
    s_userdata = NULL;
}

int mizu_dbus_notify_send(const char *summary, const char *body, const char *app_name, int timeout_ms) {
    DBusError err;
    dbus_error_init(&err);

    DBusConnection *conn = dbus_bus_get(DBUS_BUS_SESSION, &err);
    if (dbus_error_is_set(&err) || !conn) {
        dbus_error_free(&err);
        return -1;
    }

    DBusMessage *msg = dbus_message_new_method_call(
        "org.freedesktop.Notifications",
        "/org/freedesktop/Notifications",
        "org.freedesktop.Notifications",
        "Notify"
    );
    if (!msg) return -2;

    const char *an = app_name ? app_name : "Mizu";
    uint32_t replaces_id = 0;
    const char *icon = "";
    const char *sum = summary ? summary : "";
    const char *bod = body ? body : "";
    int32_t tout = (timeout_ms > 0) ? timeout_ms : 4000;

    DBusMessageIter iter, actions_iter, hints_iter;
    dbus_message_iter_init_append(msg, &iter);
    dbus_message_iter_append_basic(&iter, DBUS_TYPE_STRING, &an);
    dbus_message_iter_append_basic(&iter, DBUS_TYPE_UINT32, &replaces_id);
    dbus_message_iter_append_basic(&iter, DBUS_TYPE_STRING, &icon);
    dbus_message_iter_append_basic(&iter, DBUS_TYPE_STRING, &sum);
    dbus_message_iter_append_basic(&iter, DBUS_TYPE_STRING, &bod);

    // empty actions array
    dbus_message_iter_open_container(&iter, DBUS_TYPE_ARRAY, "s", &actions_iter);
    dbus_message_iter_close_container(&iter, &actions_iter);

    // empty hints dict
    dbus_message_iter_open_container(&iter, DBUS_TYPE_ARRAY, "{sv}", &hints_iter);
    dbus_message_iter_close_container(&iter, &hints_iter);

    dbus_message_iter_append_basic(&iter, DBUS_TYPE_INT32, &tout);

    dbus_connection_send(conn, msg, NULL);
    dbus_connection_flush(conn);
    dbus_message_unref(msg);
    return 0;
}

int mizu_upower_get_telemetry(MizuBatteryTelemetry *out) {
    if (!out) return -1;
    out->has_battery = 0;
    out->state = 0;
    out->percentage = 0.0;
    out->time_to_empty = 0;
    out->time_to_full = 0;
    out->energy_rate = 0.0;

    DBusError err;
    dbus_error_init(&err);

    DBusConnection *conn = dbus_bus_get(DBUS_BUS_SYSTEM, &err);
    if (!conn || dbus_error_is_set(&err)) {
        dbus_error_free(&err);
        return -1;
    }

    DBusMessage *msg = dbus_message_new_method_call(
        "org.freedesktop.UPower",
        "/org/freedesktop/UPower/devices/DisplayDevice",
        "org.freedesktop.DBus.Properties",
        "GetAll"
    );
    if (!msg) return -1;

    const char *iface = "org.freedesktop.UPower.Device";
    dbus_message_append_args(msg, DBUS_TYPE_STRING, &iface, DBUS_TYPE_INVALID);

    DBusMessage *reply = dbus_connection_send_with_reply_and_block(conn, msg, 200, &err);
    dbus_message_unref(msg);

    if (!reply || dbus_error_is_set(&err)) {
        dbus_error_free(&err);
        return -1;
    }

    DBusMessageIter iter, dict_iter;
    if (dbus_message_iter_init(reply, &iter) &&
        dbus_message_iter_get_arg_type(&iter) == DBUS_TYPE_ARRAY) {
        dbus_message_iter_recurse(&iter, &dict_iter);

        while (dbus_message_iter_get_arg_type(&dict_iter) == DBUS_TYPE_DICT_ENTRY) {
            DBusMessageIter entry_iter, var_iter;
            dbus_message_iter_recurse(&dict_iter, &entry_iter);

            const char *key = NULL;
            dbus_message_iter_get_basic(&entry_iter, &key);
            dbus_message_iter_next(&entry_iter);

            dbus_message_iter_recurse(&entry_iter, &var_iter);
            int var_type = dbus_message_iter_get_arg_type(&var_iter);

            if (key) {
                if (strcmp(key, "IsPresent") == 0 && var_type == DBUS_TYPE_BOOLEAN) {
                    dbus_bool_t b;
                    dbus_message_iter_get_basic(&var_iter, &b);
                    out->has_battery = b ? 1 : 0;
                } else if (strcmp(key, "State") == 0 && var_type == DBUS_TYPE_UINT32) {
                    uint32_t s;
                    dbus_message_iter_get_basic(&var_iter, &s);
                    out->state = (int)s;
                } else if (strcmp(key, "Percentage") == 0 && var_type == DBUS_TYPE_DOUBLE) {
                    dbus_message_iter_get_basic(&var_iter, &out->percentage);
                } else if (strcmp(key, "TimeToEmpty") == 0 && var_type == DBUS_TYPE_INT64) {
                    dbus_message_iter_get_basic(&var_iter, &out->time_to_empty);
                } else if (strcmp(key, "TimeToFull") == 0 && var_type == DBUS_TYPE_INT64) {
                    dbus_message_iter_get_basic(&var_iter, &out->time_to_full);
                } else if (strcmp(key, "EnergyRate") == 0 && var_type == DBUS_TYPE_DOUBLE) {
                    dbus_message_iter_get_basic(&var_iter, &out->energy_rate);
                }
            }

            dbus_message_iter_next(&dict_iter);
        }
    }

    dbus_message_unref(reply);
    return 0;
}
