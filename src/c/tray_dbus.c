#include "tray_dbus.h"
#include <dbus/dbus.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static DBusConnection *s_tray_conn = NULL;
static MizuTrayItem s_items[MIZU_MAX_TRAY_ITEMS];
static int s_item_count = 0;
static MizuTrayUpdateCallback s_update_cb = NULL;
static void *s_update_userdata = NULL;

static const char *s_introspect_xml =
    "<!DOCTYPE node PUBLIC \"-//freedesktop//DTD D-BUS Object Introspection 1.0//EN\"\n"
    "\"http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd\">\n"
    "<node>\n"
    "  <interface name=\"org.kde.StatusNotifierWatcher\">\n"
    "    <method name=\"RegisterStatusNotifierItem\">\n"
    "      <arg name=\"service\" type=\"s\" direction=\"in\"/>\n"
    "    </method>\n"
    "    <method name=\"RegisterStatusNotifierHost\">\n"
    "      <arg name=\"service\" type=\"s\" direction=\"in\"/>\n"
    "    </method>\n"
    "    <property name=\"RegisteredStatusNotifierItems\" type=\"as\" access=\"read\"/>\n"
    "    <property name=\"IsStatusNotifierHostRegistered\" type=\"b\" access=\"read\"/>\n"
    "    <property name=\"ProtocolVersion\" type=\"i\" access=\"read\"/>\n"
    "    <signal name=\"StatusNotifierItemRegistered\">\n"
    "      <arg name=\"service\" type=\"s\"/>\n"
    "    </signal>\n"
    "    <signal name=\"StatusNotifierItemUnregistered\">\n"
    "      <arg name=\"service\" type=\"s\"/>\n"
    "    </signal>\n"
    "    <signal name=\"StatusNotifierHostRegistered\"/>\n"
    "  </interface>\n"
    "  <interface name=\"org.freedesktop.DBus.Introspectable\">\n"
    "    <method name=\"Introspect\">\n"
    "      <arg name=\"xml_data\" type=\"s\" direction=\"out\"/>\n"
    "    </method>\n"
    "  </interface>\n"
    "  <interface name=\"org.freedesktop.DBus.Properties\">\n"
    "    <method name=\"Get\">\n"
    "      <arg name=\"interface_name\" type=\"s\" direction=\"in\"/>\n"
    "      <arg name=\"property_name\" type=\"s\" direction=\"in\"/>\n"
    "      <arg name=\"value\" type=\"v\" direction=\"out\"/>\n"
    "    </method>\n"
    "    <method name=\"GetAll\">\n"
    "      <arg name=\"interface_name\" type=\"s\" direction=\"in\"/>\n"
    "      <arg name=\"properties\" type=\"a{sv}\" direction=\"out\"/>\n"
    "    </method>\n"
    "  </interface>\n"
    "</node>\n";

static void notify_update(void) {
    if (s_update_cb) {
        s_update_cb(s_update_userdata);
    }
}

static void query_pixmap(DBusMessageIter *variant_iter, MizuTrayItem *item) {
    if (dbus_message_iter_get_arg_type(variant_iter) != DBUS_TYPE_ARRAY) return;

    DBusMessageIter array_iter;
    dbus_message_iter_recurse(variant_iter, &array_iter);

    uint32_t best_w = 0, best_h = 0;

    while (dbus_message_iter_get_arg_type(&array_iter) == DBUS_TYPE_STRUCT) {
        DBusMessageIter struct_iter;
        dbus_message_iter_recurse(&array_iter, &struct_iter);

        int32_t w = 0, h = 0;
        if (dbus_message_iter_get_arg_type(&struct_iter) == DBUS_TYPE_INT32) {
            dbus_message_iter_get_basic(&struct_iter, &w);
            dbus_message_iter_next(&struct_iter);
        }
        if (dbus_message_iter_get_arg_type(&struct_iter) == DBUS_TYPE_INT32) {
            dbus_message_iter_get_basic(&struct_iter, &h);
            dbus_message_iter_next(&struct_iter);
        }

        if (w > 0 && h > 0 && dbus_message_iter_get_arg_type(&struct_iter) == DBUS_TYPE_ARRAY) {
            DBusMessageIter byte_iter;
            dbus_message_iter_recurse(&struct_iter, &byte_iter);
            const uint8_t *raw_bytes = NULL;
            int n_elements = 0;
            dbus_message_iter_get_fixed_array(&byte_iter, &raw_bytes, &n_elements);

            if (raw_bytes && n_elements >= (int)(w * h * 4)) {
                // Prefer 16px to 32px
                bool choose = false;
                if (best_w == 0) {
                    choose = true;
                } else if (w >= 16 && w <= 32 && (best_w < 16 || best_w > 32)) {
                    choose = true;
                } else if (w <= 32 && w > (int32_t)best_w) {
                    choose = true;
                }

                if (choose) {
                    uint32_t target_w = (uint32_t)w;
                    uint32_t target_h = (uint32_t)h;
                    if (target_w > 32) target_w = 32;
                    if (target_h > 32) target_h = 32;

                    item->pixmap_w = target_w;
                    item->pixmap_h = target_h;

                    for (uint32_t y = 0; y < target_w; y++) {
                        uint32_t src_y = (y * (uint32_t)h) / target_h;
                        for (uint32_t x = 0; x < target_w; x++) {
                            uint32_t src_x = (x * (uint32_t)w) / target_w;
                            size_t src_idx = (src_y * (size_t)w + src_x) * 4;
                            uint8_t a = raw_bytes[src_idx];
                            uint8_t r = raw_bytes[src_idx + 1];
                            uint8_t g = raw_bytes[src_idx + 2];
                            uint8_t b = raw_bytes[src_idx + 3];
                            item->pixmap_data[y * 32 + x] = ((uint32_t)a << 24) |
                                                            ((uint32_t)r << 16) |
                                                            ((uint32_t)g << 8) |
                                                            ((uint32_t)b);
                        }
                    }
                    best_w = target_w;
                    best_h = target_h;
                }
            }
        }
        dbus_message_iter_next(&array_iter);
    }
}

static void query_item_properties(MizuTrayItem *item) {
    if (!s_tray_conn || !item) return;

    DBusMessage *msg = dbus_message_new_method_call(
        item->service,
        item->path,
        "org.freedesktop.DBus.Properties",
        "GetAll"
    );
    if (!msg) return;

    const char *iface = "org.kde.StatusNotifierItem";
    dbus_message_append_args(msg, DBUS_TYPE_STRING, &iface, DBUS_TYPE_INVALID);

    DBusError err;
    dbus_error_init(&err);
    DBusMessage *reply = dbus_connection_send_with_reply_and_block(s_tray_conn, msg, 300, &err);
    dbus_message_unref(msg);

    if (dbus_error_is_set(&err) || !reply) {
        dbus_error_free(&err);
        return;
    }

    DBusMessageIter iter;
    if (dbus_message_iter_init(reply, &iter) && dbus_message_iter_get_arg_type(&iter) == DBUS_TYPE_ARRAY) {
        DBusMessageIter dict_iter;
        dbus_message_iter_recurse(&iter, &dict_iter);

        while (dbus_message_iter_get_arg_type(&dict_iter) == DBUS_TYPE_DICT_ENTRY) {
            DBusMessageIter entry_iter;
            dbus_message_iter_recurse(&dict_iter, &entry_iter);

            if (dbus_message_iter_get_arg_type(&entry_iter) == DBUS_TYPE_STRING) {
                const char *key = NULL;
                dbus_message_iter_get_basic(&entry_iter, &key);
                dbus_message_iter_next(&entry_iter);

                if (key && dbus_message_iter_get_arg_type(&entry_iter) == DBUS_TYPE_VARIANT) {
                    DBusMessageIter var_iter;
                    dbus_message_iter_recurse(&entry_iter, &var_iter);

                    if (strcmp(key, "Id") == 0 && dbus_message_iter_get_arg_type(&var_iter) == DBUS_TYPE_STRING) {
                        const char *s = NULL;
                        dbus_message_iter_get_basic(&var_iter, &s);
                        if (s) strncpy(item->id, s, sizeof(item->id) - 1);
                    } else if (strcmp(key, "Title") == 0 && dbus_message_iter_get_arg_type(&var_iter) == DBUS_TYPE_STRING) {
                        const char *s = NULL;
                        dbus_message_iter_get_basic(&var_iter, &s);
                        if (s) strncpy(item->title, s, sizeof(item->title) - 1);
                    } else if (strcmp(key, "IconName") == 0 && dbus_message_iter_get_arg_type(&var_iter) == DBUS_TYPE_STRING) {
                        const char *s = NULL;
                        dbus_message_iter_get_basic(&var_iter, &s);
                        if (s) strncpy(item->icon_name, s, sizeof(item->icon_name) - 1);
                    } else if (strcmp(key, "Status") == 0 && dbus_message_iter_get_arg_type(&var_iter) == DBUS_TYPE_STRING) {
                        const char *s = NULL;
                        dbus_message_iter_get_basic(&var_iter, &s);
                        if (s) strncpy(item->status, s, sizeof(item->status) - 1);
                    } else if (strcmp(key, "Menu") == 0 && dbus_message_iter_get_arg_type(&var_iter) == DBUS_TYPE_OBJECT_PATH) {
                        const char *s = NULL;
                        dbus_message_iter_get_basic(&var_iter, &s);
                        if (s) strncpy(item->menu_path, s, sizeof(item->menu_path) - 1);
                    } else if (strcmp(key, "IconPixmap") == 0) {
                        query_pixmap(&var_iter, item);
                    }
                }
            }
            dbus_message_iter_next(&dict_iter);
        }
    }

    dbus_message_unref(reply);
}

static void emit_watcher_signal(const char *signal_name, const char *arg_str) {
    if (!s_tray_conn) return;

    DBusMessage *sig = dbus_message_new_signal("/StatusNotifierWatcher", "org.kde.StatusNotifierWatcher", signal_name);
    if (!sig) return;

    if (arg_str) {
        dbus_message_append_args(sig, DBUS_TYPE_STRING, &arg_str, DBUS_TYPE_INVALID);
    }

    dbus_connection_send(s_tray_conn, sig, NULL);
    dbus_connection_flush(s_tray_conn);
    dbus_message_unref(sig);
}

static int find_item(const char *service, const char *path) {
    for (int i = 0; i < s_item_count; i++) {
        if (strcmp(s_items[i].service, service) == 0 &&
            (!path || strcmp(s_items[i].path, path) == 0)) {
            return i;
        }
    }
    return -1;
}

static void add_or_update_item(const char *service, const char *path) {
    int idx = find_item(service, path);
    if (idx < 0) {
        if (s_item_count >= MIZU_MAX_TRAY_ITEMS) return;
        idx = s_item_count++;
        memset(&s_items[idx], 0, sizeof(MizuTrayItem));
        strncpy(s_items[idx].service, service, sizeof(s_items[idx].service) - 1);
        strncpy(s_items[idx].path, path ? path : "/StatusNotifierItem", sizeof(s_items[idx].path) - 1);
    }

    query_item_properties(&s_items[idx]);

    char full_id[256];
    snprintf(full_id, sizeof(full_id), "%s%s", s_items[idx].service, s_items[idx].path);
    emit_watcher_signal("StatusNotifierItemRegistered", full_id);
    notify_update();
}

static void remove_item(int idx) {
    if (idx < 0 || idx >= s_item_count) return;

    char full_id[256];
    snprintf(full_id, sizeof(full_id), "%s%s", s_items[idx].service, s_items[idx].path);

    for (int i = idx; i < s_item_count - 1; i++) {
        s_items[i] = s_items[i + 1];
    }
    s_item_count--;

    emit_watcher_signal("StatusNotifierItemUnregistered", full_id);
    notify_update();
}

static DBusHandlerResult handle_watcher_message(DBusConnection *conn, DBusMessage *msg, void *user_data) {
    (void)user_data;

    if (dbus_message_is_method_call(msg, "org.freedesktop.DBus.Introspectable", "Introspect")) {
        DBusMessage *reply = dbus_message_new_method_return(msg);
        if (reply) {
            dbus_message_append_args(reply, DBUS_TYPE_STRING, &s_introspect_xml, DBUS_TYPE_INVALID);
            dbus_connection_send(conn, reply, NULL);
            dbus_message_unref(reply);
        }
        return DBUS_HANDLER_RESULT_HANDLED;
    }

    if (dbus_message_is_method_call(msg, "org.freedesktop.DBus.Properties", "Get")) {
        const char *iface = NULL, *prop = NULL;
        if (dbus_message_get_args(msg, NULL, DBUS_TYPE_STRING, &iface, DBUS_TYPE_STRING, &prop, DBUS_TYPE_INVALID)) {
            if (iface && strcmp(iface, "org.kde.StatusNotifierWatcher") == 0 && prop) {
                DBusMessage *reply = dbus_message_new_method_return(msg);
                if (reply) {
                    DBusMessageIter iter, var_iter;
                    dbus_message_iter_init_append(reply, &iter);

                    if (strcmp(prop, "RegisteredStatusNotifierItems") == 0) {
                        dbus_message_iter_open_container(&iter, DBUS_TYPE_VARIANT, "as", &var_iter);
                        DBusMessageIter array_iter;
                        dbus_message_iter_open_container(&var_iter, DBUS_TYPE_ARRAY, "s", &array_iter);
                        for (int i = 0; i < s_item_count; i++) {
                            char full_id[256];
                            snprintf(full_id, sizeof(full_id), "%s%s", s_items[i].service, s_items[i].path);
                            const char *ptr = full_id;
                            dbus_message_iter_append_basic(&array_iter, DBUS_TYPE_STRING, &ptr);
                        }
                        dbus_message_iter_close_container(&var_iter, &array_iter);
                        dbus_message_iter_close_container(&iter, &var_iter);
                    } else if (strcmp(prop, "IsStatusNotifierHostRegistered") == 0) {
                        dbus_bool_t val = TRUE;
                        dbus_message_iter_open_container(&iter, DBUS_TYPE_VARIANT, "b", &var_iter);
                        dbus_message_iter_append_basic(&var_iter, DBUS_TYPE_BOOLEAN, &val);
                        dbus_message_iter_close_container(&iter, &var_iter);
                    } else if (strcmp(prop, "ProtocolVersion") == 0) {
                        int32_t val = 0;
                        dbus_message_iter_open_container(&iter, DBUS_TYPE_VARIANT, "i", &var_iter);
                        dbus_message_iter_append_basic(&var_iter, DBUS_TYPE_INT32, &val);
                        dbus_message_iter_close_container(&iter, &var_iter);
                    }

                    dbus_connection_send(conn, reply, NULL);
                    dbus_message_unref(reply);
                    return DBUS_HANDLER_RESULT_HANDLED;
                }
            }
        }
    }

    if (dbus_message_is_method_call(msg, "org.freedesktop.DBus.Properties", "GetAll")) {
        const char *iface = NULL;
        if (dbus_message_get_args(msg, NULL, DBUS_TYPE_STRING, &iface, DBUS_TYPE_INVALID)) {
            if (iface && strcmp(iface, "org.kde.StatusNotifierWatcher") == 0) {
                DBusMessage *reply = dbus_message_new_method_return(msg);
                if (reply) {
                    DBusMessageIter iter, dict_iter, entry_iter, var_iter;
                    dbus_message_iter_init_append(reply, &iter);
                    dbus_message_iter_open_container(&iter, DBUS_TYPE_ARRAY, "{sv}", &dict_iter);

                    // RegisteredStatusNotifierItems
                    const char *k1 = "RegisteredStatusNotifierItems";
                    dbus_message_iter_open_container(&dict_iter, DBUS_TYPE_DICT_ENTRY, NULL, &entry_iter);
                    dbus_message_iter_append_basic(&entry_iter, DBUS_TYPE_STRING, &k1);
                    dbus_message_iter_open_container(&entry_iter, DBUS_TYPE_VARIANT, "as", &var_iter);
                    DBusMessageIter array_iter;
                    dbus_message_iter_open_container(&var_iter, DBUS_TYPE_ARRAY, "s", &array_iter);
                    for (int i = 0; i < s_item_count; i++) {
                        char full_id[256];
                        snprintf(full_id, sizeof(full_id), "%s%s", s_items[i].service, s_items[i].path);
                        const char *ptr = full_id;
                        dbus_message_iter_append_basic(&array_iter, DBUS_TYPE_STRING, &ptr);
                    }
                    dbus_message_iter_close_container(&var_iter, &array_iter);
                    dbus_message_iter_close_container(&entry_iter, &var_iter);
                    dbus_message_iter_close_container(&dict_iter, &entry_iter);

                    // IsStatusNotifierHostRegistered
                    const char *k2 = "IsStatusNotifierHostRegistered";
                    dbus_bool_t b_val = TRUE;
                    dbus_message_iter_open_container(&dict_iter, DBUS_TYPE_DICT_ENTRY, NULL, &entry_iter);
                    dbus_message_iter_append_basic(&entry_iter, DBUS_TYPE_STRING, &k2);
                    dbus_message_iter_open_container(&entry_iter, DBUS_TYPE_VARIANT, "b", &var_iter);
                    dbus_message_iter_append_basic(&var_iter, DBUS_TYPE_BOOLEAN, &b_val);
                    dbus_message_iter_close_container(&entry_iter, &var_iter);
                    dbus_message_iter_close_container(&dict_iter, &entry_iter);

                    // ProtocolVersion
                    const char *k3 = "ProtocolVersion";
                    int32_t proto_val = 0;
                    dbus_message_iter_open_container(&dict_iter, DBUS_TYPE_DICT_ENTRY, NULL, &entry_iter);
                    dbus_message_iter_append_basic(&entry_iter, DBUS_TYPE_STRING, &k3);
                    dbus_message_iter_open_container(&entry_iter, DBUS_TYPE_VARIANT, "i", &var_iter);
                    dbus_message_iter_append_basic(&var_iter, DBUS_TYPE_INT32, &proto_val);
                    dbus_message_iter_close_container(&entry_iter, &var_iter);
                    dbus_message_iter_close_container(&dict_iter, &entry_iter);

                    dbus_message_iter_close_container(&iter, &dict_iter);
                    dbus_connection_send(conn, reply, NULL);
                    dbus_message_unref(reply);
                    return DBUS_HANDLER_RESULT_HANDLED;
                }
            }
        }
    }

    if (dbus_message_is_method_call(msg, "org.kde.StatusNotifierWatcher", "RegisterStatusNotifierItem")) {
        const char *service_arg = NULL;
        if (dbus_message_get_args(msg, NULL, DBUS_TYPE_STRING, &service_arg, DBUS_TYPE_INVALID)) {
            const char *sender = dbus_message_get_sender(msg);
            if (service_arg && sender) {
                char bus_name[128];
                char obj_path[128];

                if (service_arg[0] == '/') {
                    strncpy(bus_name, sender, sizeof(bus_name) - 1);
                    strncpy(obj_path, service_arg, sizeof(obj_path) - 1);
                } else {
                    const char *slash = strchr(service_arg, '/');
                    if (slash) {
                        size_t b_len = (size_t)(slash - service_arg);
                        if (b_len >= sizeof(bus_name)) b_len = sizeof(bus_name) - 1;
                        memcpy(bus_name, service_arg, b_len);
                        bus_name[b_len] = '\0';
                        strncpy(obj_path, slash, sizeof(obj_path) - 1);
                    } else {
                        strncpy(bus_name, service_arg, sizeof(bus_name) - 1);
                        strncpy(obj_path, "/StatusNotifierItem", sizeof(obj_path) - 1);
                    }
                }

                add_or_update_item(bus_name, obj_path);
            }

            DBusMessage *reply = dbus_message_new_method_return(msg);
            if (reply) {
                dbus_connection_send(conn, reply, NULL);
                dbus_message_unref(reply);
            }
            return DBUS_HANDLER_RESULT_HANDLED;
        }
    }

    if (dbus_message_is_method_call(msg, "org.kde.StatusNotifierWatcher", "RegisterStatusNotifierHost")) {
        emit_watcher_signal("StatusNotifierHostRegistered", NULL);
        DBusMessage *reply = dbus_message_new_method_return(msg);
        if (reply) {
            dbus_connection_send(conn, reply, NULL);
            dbus_message_unref(reply);
        }
        return DBUS_HANDLER_RESULT_HANDLED;
    }

    return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
}

static DBusHandlerResult filter_signals(DBusConnection *conn, DBusMessage *msg, void *user_data) {
    (void)conn;
    (void)user_data;

    if (dbus_message_is_signal(msg, "org.freedesktop.DBus", "NameOwnerChanged")) {
        const char *name = NULL, *old_owner = NULL, *new_owner = NULL;
        if (dbus_message_get_args(msg, NULL, DBUS_TYPE_STRING, &name, DBUS_TYPE_STRING, &old_owner, DBUS_TYPE_STRING, &new_owner, DBUS_TYPE_INVALID)) {
            if (new_owner && strlen(new_owner) == 0) {
                // Name vanished: find and remove any items matching name or old_owner
                for (int i = s_item_count - 1; i >= 0; i--) {
                    if ((name && strcmp(s_items[i].service, name) == 0) ||
                        (old_owner && strcmp(s_items[i].service, old_owner) == 0)) {
                        remove_item(i);
                    }
                }
            }
        }
        return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
    }

    if (dbus_message_is_signal(msg, "org.kde.StatusNotifierItem", "NewIcon") ||
        dbus_message_is_signal(msg, "org.kde.StatusNotifierItem", "NewAttentionIcon") ||
        dbus_message_is_signal(msg, "org.kde.StatusNotifierItem", "NewTitle") ||
        dbus_message_is_signal(msg, "org.kde.StatusNotifierItem", "NewStatus")) {
        const char *sender = dbus_message_get_sender(msg);
        if (sender) {
            for (int i = 0; i < s_item_count; i++) {
                if (strcmp(s_items[i].service, sender) == 0) {
                    query_item_properties(&s_items[i]);
                    notify_update();
                    break;
                }
            }
        }
        return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
    }

    return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
}

int mizu_tray_dbus_init(MizuTrayUpdateCallback cb, void *userdata) {
    if (s_tray_conn) return 0;

    DBusError err;
    dbus_error_init(&err);

    s_tray_conn = dbus_bus_get_private(DBUS_BUS_SESSION, &err);
    if (dbus_error_is_set(&err) || !s_tray_conn) {
        dbus_error_free(&err);
        return -1;
    }

    s_update_cb = cb;
    s_update_userdata = userdata;

    int ret = dbus_bus_request_name(
        s_tray_conn,
        "org.kde.StatusNotifierWatcher",
        DBUS_NAME_FLAG_REPLACE_EXISTING | DBUS_NAME_FLAG_DO_NOT_QUEUE,
        &err
    );
    if (dbus_error_is_set(&err)) {
        dbus_error_free(&err);
        dbus_connection_close(s_tray_conn);
        dbus_connection_unref(s_tray_conn);
        s_tray_conn = NULL;
        return -2;
    }

    if (ret != DBUS_REQUEST_NAME_REPLY_PRIMARY_OWNER &&
        ret != DBUS_REQUEST_NAME_REPLY_ALREADY_OWNER) {
        // Someone else is already watcher, continue listening as host if possible
    }

    DBusObjectPathVTable vtable;
    memset(&vtable, 0, sizeof(vtable));
    vtable.message_function = handle_watcher_message;

    dbus_connection_register_object_path(s_tray_conn, "/StatusNotifierWatcher", &vtable, userdata);

    dbus_bus_add_match(s_tray_conn, "type='signal',sender='org.freedesktop.DBus',interface='org.freedesktop.DBus',member='NameOwnerChanged'", NULL);
    dbus_bus_add_match(s_tray_conn, "type='signal',interface='org.kde.StatusNotifierItem'", NULL);
    dbus_connection_add_filter(s_tray_conn, filter_signals, NULL, NULL);

    return 0;
}

int mizu_tray_dbus_dispatch(int timeout_ms) {
    if (!s_tray_conn) return -1;
    if (dbus_connection_read_write(s_tray_conn, timeout_ms)) {
        while (dbus_connection_dispatch(s_tray_conn) == DBUS_DISPATCH_DATA_REMAINS) {
        }
        return 0;
    }
    return -1;
}

int mizu_tray_get_items(MizuTrayItem *out_items, int max_items) {
    if (!out_items || max_items <= 0) return s_item_count;
    int count = s_item_count < max_items ? s_item_count : max_items;
    for (int i = 0; i < count; i++) {
        out_items[i] = s_items[i];
    }
    return s_item_count;
}

void mizu_tray_item_activate(const char *service, const char *path, int32_t x, int32_t y) {
    if (!s_tray_conn || !service || !path) return;
    DBusMessage *msg = dbus_message_new_method_call(service, path, "org.kde.StatusNotifierItem", "Activate");
    if (!msg) return;
    dbus_message_append_args(msg, DBUS_TYPE_INT32, &x, DBUS_TYPE_INT32, &y, DBUS_TYPE_INVALID);
    dbus_connection_send(s_tray_conn, msg, NULL);
    dbus_connection_flush(s_tray_conn);
    dbus_message_unref(msg);
}

void mizu_tray_item_context_menu(const char *service, const char *path, int32_t x, int32_t y) {
    if (!s_tray_conn || !service || !path) return;
    DBusMessage *msg = dbus_message_new_method_call(service, path, "org.kde.StatusNotifierItem", "ContextMenu");
    if (!msg) return;
    dbus_message_append_args(msg, DBUS_TYPE_INT32, &x, DBUS_TYPE_INT32, &y, DBUS_TYPE_INVALID);
    dbus_connection_send(s_tray_conn, msg, NULL);
    dbus_connection_flush(s_tray_conn);
    dbus_message_unref(msg);
}

void mizu_tray_item_secondary_activate(const char *service, const char *path, int32_t x, int32_t y) {
    if (!s_tray_conn || !service || !path) return;
    DBusMessage *msg = dbus_message_new_method_call(service, path, "org.kde.StatusNotifierItem", "SecondaryActivate");
    if (!msg) return;
    dbus_message_append_args(msg, DBUS_TYPE_INT32, &x, DBUS_TYPE_INT32, &y, DBUS_TYPE_INVALID);
    dbus_connection_send(s_tray_conn, msg, NULL);
    dbus_connection_flush(s_tray_conn);
    dbus_message_unref(msg);
}

void mizu_tray_item_scroll(const char *service, const char *path, int32_t delta, bool horizontal) {
    if (!s_tray_conn || !service || !path) return;
    DBusMessage *msg = dbus_message_new_method_call(service, path, "org.kde.StatusNotifierItem", "Scroll");
    if (!msg) return;
    const char *dir = horizontal ? "horizontal" : "vertical";
    dbus_message_append_args(msg, DBUS_TYPE_INT32, &delta, DBUS_TYPE_STRING, &dir, DBUS_TYPE_INVALID);
    dbus_connection_send(s_tray_conn, msg, NULL);
    dbus_connection_flush(s_tray_conn);
    dbus_message_unref(msg);
}

void mizu_tray_dbus_deinit(void) {
    if (!s_tray_conn) return;
    dbus_connection_unregister_object_path(s_tray_conn, "/StatusNotifierWatcher");
    dbus_connection_close(s_tray_conn);
    dbus_connection_unref(s_tray_conn);
    s_tray_conn = NULL;
    s_item_count = 0;
}
