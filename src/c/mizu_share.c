#define _GNU_SOURCE
#include "mizu_share.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>
#include <fcntl.h>
#include <poll.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <errno.h>
#include <ctype.h>

#include <signal.h>

static volatile int s_running = 0;
static pid_t s_daemon_pid = 0;
static int s_port = 0;
static char s_lan_ip[64] = { 0 };
static char s_session_token[33] = { 0 };
static char s_url[160] = { 0 };
static int s_wake_fd = -1;
static pthread_mutex_t s_lock = PTHREAD_MUTEX_INITIALIZER;
static volatile sig_atomic_t s_daemon_stop = 0;

static void get_info_path(char *buf, size_t sz) {
    snprintf(buf, sz, "/tmp/mizu-share-%u.info", (unsigned int)getuid());
}

static void sigterm_handler(int sig) {
    (void)sig;
    s_daemon_stop = 1;
}

static const char s_html[] =
"<!DOCTYPE html>\n"
"<html lang=\"en\">\n"
"<head>\n"
"<meta charset=\"utf-8\">\n"
"<meta name=\"viewport\" content=\"width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no\">\n"
"<title>Mizu Share</title>\n"
"<style>\n"
"* { box-sizing: border-box; margin: 0; padding: 0; }\n"
"body {\n"
"  font-family: -apple-system, BlinkMacSystemFont, \"Segoe UI\", Roboto, Helvetica, Arial, sans-serif;\n"
"  background: #090a0f;\n"
"  color: #e2e8f0;\n"
"  padding: 16px;\n"
"  max-width: 480px;\n"
"  margin: 0 auto;\n"
"  line-height: 1.5;\n"
"}\n"
"header {\n"
"  display: flex;\n"
"  align-items: center;\n"
"  justify-content: space-between;\n"
"  padding: 8px 0 16px;\n"
"}\n"
".brand {\n"
"  display: flex;\n"
"  align-items: center;\n"
"  gap: 8px;\n"
"  font-size: 18px;\n"
"  font-weight: 700;\n"
"  color: #fff;\n"
"  letter-spacing: -0.02em;\n"
"}\n"
".brand svg { color: #818cf8; }\n"
".badge {\n"
"  font-size: 11px;\n"
"  padding: 3px 10px;\n"
"  border-radius: 999px;\n"
"  background: rgba(16, 185, 129, 0.15);\n"
"  color: #34d399;\n"
"  font-weight: 600;\n"
"  display: inline-flex;\n"
"  align-items: center;\n"
"  gap: 5px;\n"
"}\n"
".badge::before {\n"
"  content: \"\";\n"
"  width: 6px;\n"
"  height: 6px;\n"
"  border-radius: 50%;\n"
"  background: #10b981;\n"
"}\n"
".card {\n"
"  background: #131620;\n"
"  border: 1px solid #1f2434;\n"
"  border-radius: 14px;\n"
"  padding: 14px;\n"
"  margin-bottom: 12px;\n"
"}\n"
".card-head {\n"
"  display: flex;\n"
"  align-items: center;\n"
"  justify-content: space-between;\n"
"  margin-bottom: 10px;\n"
"}\n"
".card-title {\n"
"  font-size: 13px;\n"
"  font-weight: 600;\n"
"  color: #94a3b8;\n"
"  text-transform: uppercase;\n"
"  letter-spacing: 0.04em;\n"
"}\n"
"textarea {\n"
"  width: 100%;\n"
"  background: #0a0c13;\n"
"  border: 1px solid #23293d;\n"
"  border-radius: 10px;\n"
"  color: #f1f5f9;\n"
"  padding: 10px 12px;\n"
"  font-size: 14px;\n"
"  line-height: 1.5;\n"
"  resize: none;\n"
"  outline: none;\n"
"  font-family: inherit;\n"
"  transition: border-color 0.15s;\n"
"}\n"
"textarea:focus { border-color: #6366f1; }\n"
".btn-row {\n"
"  display: flex;\n"
"  gap: 8px;\n"
"  margin-top: 10px;\n"
"}\n"
".btn {\n"
"  display: inline-flex;\n"
"  align-items: center;\n"
"  justify-content: center;\n"
"  gap: 6px;\n"
"  padding: 10px 14px;\n"
"  font-size: 13px;\n"
"  font-weight: 600;\n"
"  border-radius: 8px;\n"
"  border: none;\n"
"  cursor: pointer;\n"
"  transition: background 0.15s;\n"
"  text-decoration: none;\n"
"  font-family: inherit;\n"
"}\n"
".btn-primary {\n"
"  background: #6366f1;\n"
"  color: #fff;\n"
"  flex: 1;\n"
"}\n"
".btn-primary:active { background: #4f46e5; }\n"
".btn-secondary {\n"
"  background: #1e2333;\n"
"  color: #cbd5e1;\n"
"}\n"
".btn-secondary:active { background: #2b3248; }\n"
".btn-full { width: 100%; margin-top: 10px; }\n"
".btn:disabled {\n"
"  opacity: 0.5;\n"
"  cursor: not-allowed;\n"
"}\n"
".file-box {\n"
"  border: 1.5px dashed #2b3248;\n"
"  border-radius: 10px;\n"
"  padding: 16px;\n"
"  text-align: center;\n"
"  cursor: pointer;\n"
"  background: #0a0c13;\n"
"  transition: border-color 0.15s;\n"
"}\n"
".file-box:active { border-color: #6366f1; }\n"
".file-hint {\n"
"  font-size: 13px;\n"
"  color: #cbd5e1;\n"
"  display: flex;\n"
"  align-items: center;\n"
"  justify-content: center;\n"
"  gap: 6px;\n"
"}\n"
".file-selected {\n"
"  font-size: 12px;\n"
"  color: #818cf8;\n"
"  margin-top: 6px;\n"
"  word-break: break-all;\n"
"  font-weight: 500;\n"
"}\n"
".path-info {\n"
"  margin-top: 10px;\n"
"  font-size: 11px;\n"
"  color: #64748b;\n"
"  display: flex;\n"
"  align-items: center;\n"
"  gap: 5px;\n"
"}\n"
".path-info code {\n"
"  color: #94a3b8;\n"
"  background: #0a0c13;\n"
"  padding: 2px 6px;\n"
"  border-radius: 4px;\n"
"  border: 1px solid #1e2333;\n"
"  font-family: monospace;\n"
"}\n"
"#clipImg {\n"
"  max-width: 100%;\n"
"  border-radius: 8px;\n"
"  margin-top: 10px;\n"
"  border: 1px solid #1f2434;\n"
"  display: block;\n"
"}\n"
"progress {\n"
"  width: 100%;\n"
"  height: 6px;\n"
"  border-radius: 4px;\n"
"  overflow: hidden;\n"
"  border: none;\n"
"  background: #0a0c13;\n"
"  accent-color: #6366f1;\n"
"}\n"
"progress::-webkit-progress-bar { background: #0a0c13; border-radius: 4px; }\n"
"progress::-webkit-progress-value { background: #6366f1; border-radius: 4px; }\n"
"progress::-moz-progress-bar { background: #6366f1; border-radius: 4px; }\n"
".toast {\n"
"  position: fixed;\n"
"  bottom: 24px;\n"
"  left: 50%;\n"
"  transform: translateX(-50%);\n"
"  background: #181d2c;\n"
"  color: #f8fafc;\n"
"  padding: 10px 18px;\n"
"  border-radius: 999px;\n"
"  font-size: 12px;\n"
"  font-weight: 500;\n"
"  box-shadow: 0 8px 30px rgba(0,0,0,0.6);\n"
"  border: 1px solid #2d344a;\n"
"  opacity: 0;\n"
"  pointer-events: none;\n"
"  transition: opacity 0.2s ease;\n"
"  z-index: 999;\n"
"  max-width: 90%;\n"
"  text-align: center;\n"
"}\n"
".toast.show { opacity: 1; }\n"
"</style>\n"
"</head>\n"
"<body>\n"
"<header>\n"
"  <div class=\"brand\">\n"
"    <svg width=\"20\" height=\"20\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2.5\"><path d=\"M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71\"/><path d=\"M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71\"/></svg>\n"
"    <span>Mizu Share</span>\n"
"  </div>\n"
"  <span class=\"badge\" id=\"statusBadge\">Connected</span>\n"
"</header>\n"
"\n"
"<div class=\"card\">\n"
"  <div class=\"card-head\">\n"
"    <span class=\"card-title\">Desktop Clipboard</span>\n"
"    <button class=\"btn btn-secondary\" style=\"padding:4px 10px;font-size:11px;\" id=\"refreshBtn\">Refresh</button>\n"
"  </div>\n"
"  <textarea id=\"clipText\" rows=\"3\" readonly placeholder=\"Desktop clipboard is empty...\"></textarea>\n"
"  <div class=\"btn-row\">\n"
"    <button class=\"btn btn-primary\" id=\"copyBtn\">Copy to Phone</button>\n"
"  </div>\n"
"  <div id=\"imgContainer\" style=\"display:none;margin-top:10px;\">\n"
"    <img id=\"clipImg\" alt=\"Desktop Image\">\n"
"    <a id=\"downloadImgBtn\" class=\"btn btn-secondary btn-full\" href=\"#\" download=\"mizu_clipboard.png\">Download Image</a>\n"
"  </div>\n"
"</div>\n"
"\n"
"<div class=\"card\">\n"
"  <div class=\"card-head\">\n"
"    <span class=\"card-title\">Send Text</span>\n"
"  </div>\n"
"  <textarea id=\"sendText\" rows=\"2\" placeholder=\"Type or paste to send to desktop clipboard...\"></textarea>\n"
"  <button class=\"btn btn-primary btn-full\" id=\"sendTextBtn\">Send to Clipboard</button>\n"
"</div>\n"
"\n"
"<div class=\"card\">\n"
"  <div class=\"card-head\">\n"
"    <span class=\"card-title\">Send Files &amp; Photos</span>\n"
"  </div>\n"
"  <div class=\"file-box\" id=\"fileDrop\">\n"
"    <div class=\"file-hint\">\n"
"      <svg width=\"16\" height=\"16\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\"><path d=\"M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4\"/><polyline points=\"17 8 12 3 7 8\"/><line x1=\"12\" y1=\"3\" x2=\"12\" y2=\"15\"/></svg>\n"
"      <span>Tap to choose file or photo</span>\n"
"    </div>\n"
"    <div class=\"file-selected\" id=\"fileName\">No file selected</div>\n"
"  </div>\n"
"  <input type=\"file\" id=\"fileInput\" style=\"display:none\">\n"
"  <div id=\"progWrap\" style=\"display:none;margin-top:10px;\">\n"
"    <progress id=\"uploadBar\" value=\"0\" max=\"100\"></progress>\n"
"    <div id=\"uploadPct\" style=\"font-size:11px;color:#818cf8;text-align:right;margin-top:2px;\">0%</div>\n"
"  </div>\n"
"  <button class=\"btn btn-primary btn-full\" id=\"uploadBtn\" disabled>Upload to Desktop</button>\n"
"  <div class=\"path-info\">\n"
"    <span>📁 Downloads to:</span>\n"
"    <code>~/Downloads/MizuShare/</code>\n"
"  </div>\n"
"</div>\n"
"\n"
"<div class=\"toast\" id=\"toast\"></div>\n"
"\n"
"<script>\n"
"const token = new URLSearchParams(window.location.search).get('token') || '';\n"
"function apiUrl(path) {\n"
"  return token ? path + (path.includes('?') ? '&' : '?') + 'token=' + encodeURIComponent(token) : path;\n"
"}\n"
"function showToast(msg) {\n"
"  const t = document.getElementById('toast');\n"
"  t.textContent = msg;\n"
"  t.classList.add('show');\n"
"  setTimeout(() => t.classList.remove('show'), 3000);\n"
"}\n"
"async function loadClipboard() {\n"
"  try {\n"
"    const res = await fetch(apiUrl('/api/clip'));\n"
"    if (res.status === 403) {\n"
"      document.getElementById('statusBadge').textContent = 'Disconnected';\n"
"      document.getElementById('statusBadge').style.background = 'rgba(239, 68, 68, 0.15)';\n"
"      document.getElementById('statusBadge').style.color = '#f87171';\n"
"      showToast('Session expired');\n"
"      return;\n"
"    }\n"
"    const data = await res.json();\n"
"    document.getElementById('clipText').value = data.text || '';\n"
"    const imgContainer = document.getElementById('imgContainer');\n"
"    if (data.has_image) {\n"
"      const imgUrl = apiUrl('/api/image?t=' + Date.now());\n"
"      document.getElementById('clipImg').src = imgUrl;\n"
"      document.getElementById('downloadImgBtn').href = imgUrl;\n"
"      imgContainer.style.display = 'block';\n"
"    } else {\n"
"      imgContainer.style.display = 'none';\n"
"    }\n"
"  } catch (e) {}\n"
"}\n"
"document.getElementById('refreshBtn').onclick = () => { loadClipboard(); showToast('Refreshed'); };\n"
"document.getElementById('copyBtn').onclick = async () => {\n"
"  const val = document.getElementById('clipText').value;\n"
"  if (!val) { showToast('Nothing to copy'); return; }\n"
"  try {\n"
"    await navigator.clipboard.writeText(val);\n"
"    showToast('Copied to phone clipboard!');\n"
"  } catch (e) {\n"
"    document.getElementById('clipText').select();\n"
"    document.execCommand('copy');\n"
"    showToast('Copied to phone clipboard!');\n"
"  }\n"
"};\n"
"document.getElementById('sendTextBtn').onclick = async () => {\n"
"  const val = document.getElementById('sendText').value;\n"
"  if (!val) { showToast('Enter some text first'); return; }\n"
"  try {\n"
"    const res = await fetch(apiUrl('/api/text'), {\n"
"      method: 'POST',\n"
"      headers: { 'Content-Type': 'text/plain; charset=utf-8' },\n"
"      body: val\n"
"    });\n"
"    if (res.ok) {\n"
"      document.getElementById('sendText').value = '';\n"
"      showToast('Copied to desktop clipboard!');\n"
"      setTimeout(loadClipboard, 400);\n"
"    } else {\n"
"      showToast('Error: ' + res.status);\n"
"    }\n"
"  } catch (e) {\n"
"    showToast('Copied to desktop clipboard!');\n"
"    setTimeout(loadClipboard, 400);\n"
"  }\n"
"};\n"
"const fileInput = document.getElementById('fileInput');\n"
"const fileDrop = document.getElementById('fileDrop');\n"
"const fileName = document.getElementById('fileName');\n"
"const uploadBtn = document.getElementById('uploadBtn');\n"
"fileDrop.onclick = () => fileInput.click();\n"
"fileInput.onchange = () => {\n"
"  if (fileInput.files.length > 0) {\n"
"    const f = fileInput.files[0];\n"
"    const size = f.size > 1048576 ? (f.size / 1048576).toFixed(1) + ' MB' : (f.size / 1024).toFixed(1) + ' KB';\n"
"    fileName.textContent = `${f.name} (${size})`;\n"
"    uploadBtn.disabled = false;\n"
"  } else {\n"
"    fileName.textContent = 'No file selected';\n"
"    uploadBtn.disabled = true;\n"
"  }\n"
"};\n"
"uploadBtn.onclick = () => {\n"
"  if (!fileInput.files.length) return;\n"
"  const f = fileInput.files[0];\n"
"  uploadBtn.disabled = true;\n"
"  uploadBtn.textContent = 'Uploading...';\n"
"  const progWrap = document.getElementById('progWrap');\n"
"  const bar = document.getElementById('uploadBar');\n"
"  const pct = document.getElementById('uploadPct');\n"
"  bar.value = 0;\n"
"  pct.textContent = '0%';\n"
"  progWrap.style.display = 'block';\n"
"  const xhr = new XMLHttpRequest();\n"
"  xhr.open('POST', apiUrl('/api/upload'), true);\n"
"  xhr.setRequestHeader('X-Filename', encodeURIComponent(f.name));\n"
"  xhr.setRequestHeader('Content-Type', f.type || 'application/octet-stream');\n"
"  xhr.upload.onprogress = (e) => {\n"
"    if (e.lengthComputable) {\n"
"      const p = Math.round((e.loaded / e.total) * 100);\n"
"      bar.value = p;\n"
"      pct.textContent = p + '%';\n"
"    }\n"
"  };\n"
"  const done = (ok, msg) => {\n"
"    uploadBtn.disabled = false;\n"
"    uploadBtn.textContent = 'Upload to Desktop';\n"
"    setTimeout(() => { progWrap.style.display = 'none'; }, 1200);\n"
"    showToast(msg);\n"
"    if (ok) {\n"
"      fileName.textContent = 'No file selected';\n"
"      fileInput.value = '';\n"
"      setTimeout(loadClipboard, 600);\n"
"    }\n"
"  };\n"
"  xhr.onload = () => {\n"
"    if (xhr.status >= 200 && xhr.status < 300) {\n"
"      let d = {};\n"
"      try { d = JSON.parse(xhr.responseText); } catch(err) {}\n"
"      done(true, `Saved to ~/Downloads/MizuShare/${d.filename || f.name}`);\n"
"    } else {\n"
"      done(false, 'Upload failed: ' + xhr.status);\n"
"    }\n"
"  };\n"
"  xhr.onerror = () => {\n"
"    done(true, `Saved to ~/Downloads/MizuShare/${f.name}`);\n"
"  };\n"
"  xhr.send(f);\n"
"};\n"
"loadClipboard();\n"
"</script>\n"
"</body>\n"
"</html>\n";

static void notify_wake(void) {
    if (s_wake_fd >= 0) {
        uint64_t val = 1;
        (void)write(s_wake_fd, &val, sizeof(val));
    }
}

static void get_lan_ip(char *buf, size_t max_len) {
    int sock = socket(AF_INET, SOCK_DGRAM, 0);
    if (sock >= 0) {
        struct sockaddr_in serv;
        memset(&serv, 0, sizeof(serv));
        serv.sin_family = AF_INET;
        serv.sin_addr.s_addr = inet_addr("8.8.8.8");
        serv.sin_port = htons(53);
        if (connect(sock, (const struct sockaddr*)&serv, sizeof(serv)) == 0) {
            struct sockaddr_in name;
            socklen_t namelen = sizeof(name);
            if (getsockname(sock, (struct sockaddr*)&name, &namelen) == 0) {
                const char *p = inet_ntop(AF_INET, &name.sin_addr, buf, max_len);
                close(sock);
                if (p && strcmp(buf, "0.0.0.0") != 0 && strcmp(buf, "127.0.0.1") != 0) {
                    return;
                }
            }
        }
        close(sock);
    }

    struct ifaddrs *ifaddr = NULL;
    if (getifaddrs(&ifaddr) == 0 && ifaddr != NULL) {
        for (struct ifaddrs *ifa = ifaddr; ifa != NULL; ifa = ifa->ifa_next) {
            if (!ifa->ifa_addr || ifa->ifa_addr->sa_family != AF_INET) continue;
            if (ifa->ifa_flags & IFF_LOOPBACK) continue;
            if (!(ifa->ifa_flags & IFF_UP)) continue;

            const char *name = ifa->ifa_name;
            if (strncmp(name, "docker", 6) == 0 || strncmp(name, "virbr", 5) == 0 ||
                strncmp(name, "br-", 3) == 0 || strncmp(name, "veth", 4) == 0) {
                continue;
            }

            struct sockaddr_in *p_in = (struct sockaddr_in *)ifa->ifa_addr;
            inet_ntop(AF_INET, &p_in->sin_addr, buf, max_len);
            freeifaddrs(ifaddr);
            return;
        }
        freeifaddrs(ifaddr);
    }

    snprintf(buf, max_len, "127.0.0.1");
}

static int copy_text_to_clipboard(const char *text, size_t len) {
    char tmppath[64] = "/tmp/mizu_clip_XXXXXX";
    int fd = mkstemp(tmppath);
    if (fd < 0) return -1;
    (void)write(fd, text, len);
    close(fd);

    pid_t pid = fork();
    if (pid == 0) {
        setsid();
        int in_fd = open(tmppath, O_RDONLY);
        if (in_fd >= 0) {
            dup2(in_fd, STDIN_FILENO);
            close(in_fd);
        }
        unlink(tmppath);
        int devnull = open("/dev/null", O_WRONLY);
        if (devnull >= 0) {
            dup2(devnull, STDOUT_FILENO);
            dup2(devnull, STDERR_FILENO);
            close(devnull);
        }
        int max_fd = (int)sysconf(_SC_OPEN_MAX);
        if (max_fd < 0 || max_fd > 4096) max_fd = 1024;
        for (int i = 3; i < max_fd; i++) close(i);
        const char *path = getenv("PATH");
        char new_path[1024];
        snprintf(new_path, sizeof(new_path), "%s:/usr/sbin:/usr/bin:/usr/local/bin", path ? path : "");
        setenv("PATH", new_path, 1);
        char *args[] = { "wl-copy", NULL };
        execvp("wl-copy", args);
        _exit(127);
    }
    return 0;
}

static int copy_image_to_clipboard(const char *filepath, const char *mime) {
    pid_t pid = fork();
    if (pid == 0) {
        setsid();
        int fd = open(filepath, O_RDONLY);
        if (fd >= 0) {
            dup2(fd, STDIN_FILENO);
            close(fd);
        }
        int devnull = open("/dev/null", O_WRONLY);
        if (devnull >= 0) {
            dup2(devnull, STDOUT_FILENO);
            dup2(devnull, STDERR_FILENO);
            close(devnull);
        }
        int max_fd = (int)sysconf(_SC_OPEN_MAX);
        if (max_fd < 0 || max_fd > 4096) max_fd = 1024;
        for (int i = 3; i < max_fd; i++) close(i);
        const char *path = getenv("PATH");
        char new_path[1024];
        snprintf(new_path, sizeof(new_path), "%s:/usr/sbin:/usr/bin:/usr/local/bin", path ? path : "");
        setenv("PATH", new_path, 1);
        char *args[] = { "wl-copy", "--type", (char*)mime, NULL };
        execvp("wl-copy", args);
        _exit(127);
    }
    return 0;
}

static char* get_clipboard_text(size_t *out_len) {
    int pfd[2];
    if (pipe(pfd) < 0) return NULL;
    pid_t pid = fork();
    if (pid < 0) {
        close(pfd[0]);
        close(pfd[1]);
        return NULL;
    }
    if (pid == 0) {
        close(pfd[0]);
        dup2(pfd[1], STDOUT_FILENO);
        close(pfd[1]);
        int null_fd = open("/dev/null", O_WRONLY);
        if (null_fd >= 0) {
            dup2(null_fd, STDERR_FILENO);
            close(null_fd);
        }
        const char *path = getenv("PATH");
        char new_path[1024];
        snprintf(new_path, sizeof(new_path), "%s:/usr/sbin:/usr/bin:/usr/local/bin", path ? path : "");
        setenv("PATH", new_path, 1);
        char *args[] = { "wl-paste", "--no-newline", NULL };
        execvp("wl-paste", args);
        _exit(127);
    }
    close(pfd[1]);
    size_t cap = 32768;
    size_t len = 0;
    char *buf = (char*)malloc(cap);
    if (!buf) {
        close(pfd[0]);
        waitpid(pid, NULL, 0);
        return NULL;
    }
    while (len + 1 < 1048576) {
        if (len + 4096 >= cap) {
            cap *= 2;
            char *nb = (char*)realloc(buf, cap);
            if (!nb) break;
            buf = nb;
        }
        ssize_t n = read(pfd[0], buf + len, cap - 1 - len);
        if (n <= 0) break;
        len += n;
    }
    close(pfd[0]);
    buf[len] = '\0';
    waitpid(pid, NULL, 0);
    *out_len = len;
    return buf;
}

static int check_clipboard_has_image(void) {
    int pfd[2];
    if (pipe(pfd) < 0) return 0;
    pid_t pid = fork();
    if (pid < 0) {
        close(pfd[0]);
        close(pfd[1]);
        return 0;
    }
    if (pid == 0) {
        close(pfd[0]);
        dup2(pfd[1], STDOUT_FILENO);
        close(pfd[1]);
        int null_fd = open("/dev/null", O_WRONLY);
        if (null_fd >= 0) {
            dup2(null_fd, STDERR_FILENO);
            close(null_fd);
        }
        const char *path = getenv("PATH");
        char new_path[1024];
        snprintf(new_path, sizeof(new_path), "%s:/usr/sbin:/usr/bin:/usr/local/bin", path ? path : "");
        setenv("PATH", new_path, 1);
        char *args[] = { "wl-paste", "--list-types", NULL };
        execvp("wl-paste", args);
        _exit(127);
    }
    close(pfd[1]);
    char buf[1024];
    ssize_t n = read(pfd[0], buf, sizeof(buf) - 1);
    close(pfd[0]);
    waitpid(pid, NULL, 0);
    if (n <= 0) return 0;
    buf[n] = '\0';
    return (strstr(buf, "image/png") || strstr(buf, "image/jpeg") || strstr(buf, "image/webp")) ? 1 : 0;
}

static void stream_clipboard_image(int client_fd) {
    int pfd[2];
    if (pipe(pfd) < 0) return;
    pid_t pid = fork();
    if (pid < 0) {
        close(pfd[0]);
        close(pfd[1]);
        return;
    }
    if (pid == 0) {
        close(pfd[0]);
        dup2(pfd[1], STDOUT_FILENO);
        close(pfd[1]);
        int null_fd = open("/dev/null", O_WRONLY);
        if (null_fd >= 0) {
            dup2(null_fd, STDERR_FILENO);
            close(null_fd);
        }
        const char *path = getenv("PATH");
        char new_path[1024];
        snprintf(new_path, sizeof(new_path), "%s:/usr/sbin:/usr/bin:/usr/local/bin", path ? path : "");
        setenv("PATH", new_path, 1);
        char *args[] = { "wl-paste", "--type", "image/png", NULL };
        execvp("wl-paste", args);
        _exit(127);
    }
    close(pfd[1]);

    const char *header = "HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nConnection: close\r\n\r\n";
    (void)write(client_fd, header, strlen(header));

    char buf[16384];
    while (1) {
        ssize_t n = read(pfd[0], buf, sizeof(buf));
        if (n <= 0) break;
        ssize_t w = write(client_fd, buf, n);
        if (w <= 0) break;
    }
    close(pfd[0]);
    waitpid(pid, NULL, 0);
}

static void url_decode(char *dst, const char *src, size_t max_len) {
    size_t d = 0;
    while (*src && d + 1 < max_len) {
        if (*src == '%' && isxdigit((unsigned char)src[1]) && isxdigit((unsigned char)src[2])) {
            char hex[3] = { src[1], src[2], 0 };
            dst[d++] = (char)strtol(hex, NULL, 16);
            src += 3;
        } else if (*src == '+') {
            dst[d++] = ' ';
            src++;
        } else {
            dst[d++] = *src++;
        }
    }
    dst[d] = '\0';
}

static void sanitize_filename(char *dst, const char *src, size_t max_len) {
    const char *slash = strrchr(src, '/');
    if (slash) src = slash + 1;
    const char *bslash = strrchr(src, '\\');
    if (bslash) src = bslash + 1;

    size_t d = 0;
    while (*src && d + 1 < max_len) {
        char c = *src++;
        if (c == '.' && *src == '.') continue;
        if (isalnum((unsigned char)c) || c == '.' || c == '-' || c == '_' || c == ' ' || c == '(' || c == ')') {
            dst[d++] = c;
        } else {
            dst[d++] = '_';
        }
    }
    dst[d] = '\0';

    if (d == 0 || dst[0] == '.') {
        snprintf(dst, max_len, "upload_%lu.dat", (unsigned long)time(NULL));
    }
}

static int is_authenticated(const char *headers, const char *path) {
    if (!s_running || s_session_token[0] == '\0') return 0;

    const char *q = strchr(path, '?');
    if (q) {
        const char *tok = strcasestr(q, "token=");
        if (tok) {
            tok += 6;
            if (strncmp(tok, s_session_token, strlen(s_session_token)) == 0) return 1;
        }
    }

    const char *hdr = strcasestr(headers, "X-Session-Token:");
    if (hdr) {
        hdr += 16;
        while (*hdr == ' ') hdr++;
        if (strncmp(hdr, s_session_token, strlen(s_session_token)) == 0) return 1;
    }

    const char *cookie = strcasestr(headers, "Cookie:");
    if (cookie) {
        const char *ms = strcasestr(cookie, "mizu_session=");
        if (ms) {
            ms += 13;
            if (strncmp(ms, s_session_token, strlen(s_session_token)) == 0) return 1;
        }
    }

    return 0;
}

static void send_forbidden(int fd) {
    const char *body = "Session invalid or expired.";
    char msg[512];
    snprintf(msg, sizeof(msg),
        "HTTP/1.1 403 Forbidden\r\n"
        "Content-Type: text/plain; charset=utf-8\r\n"
        "Access-Control-Allow-Origin: *\r\n"
        "Content-Length: %zu\r\n"
        "Connection: close\r\n\r\n%s",
        strlen(body), body);
    (void)write(fd, msg, strlen(msg));
}

static void send_json_ok(int fd, const char *extra) {
    char body[512];
    snprintf(body, sizeof(body), "{\"ok\":true%s%s}", extra ? "," : "", extra ? extra : "");
    char resp[1024];
    snprintf(resp, sizeof(resp),
        "HTTP/1.1 200 OK\r\n"
        "Content-Type: application/json; charset=utf-8\r\n"
        "Access-Control-Allow-Origin: *\r\n"
        "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
        "Access-Control-Allow-Headers: *\r\n"
        "Content-Length: %zu\r\n"
        "Connection: close\r\n\r\n%s",
        strlen(body), body);
    (void)write(fd, resp, strlen(resp));
}

static void handle_client(int client_fd) {
    fcntl(client_fd, F_SETFD, FD_CLOEXEC);
    struct timeval tv = { .tv_sec = 10, .tv_usec = 0 };
    setsockopt(client_fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(client_fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

    char header_buf[8192];
    size_t header_len = 0;
    char *body_start = NULL;

    while (header_len + 1 < sizeof(header_buf)) {
        ssize_t n = read(client_fd, header_buf + header_len, sizeof(header_buf) - 1 - header_len);
        if (n <= 0) break;
        header_len += n;
        header_buf[header_len] = '\0';
        body_start = strstr(header_buf, "\r\n\r\n");
        if (body_start) {
            body_start += 4;
            break;
        }
    }

    if (!body_start) {
        close(client_fd);
        return;
    }

    char method[16] = { 0 };
    char path[512] = { 0 };
    sscanf(header_buf, "%15s %511s", method, path);

    if (strcmp(method, "OPTIONS") == 0) {
        const char *resp =
            "HTTP/1.1 204 No Content\r\n"
            "Access-Control-Allow-Origin: *\r\n"
            "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
            "Access-Control-Allow-Headers: *\r\n"
            "Content-Length: 0\r\n"
            "Connection: close\r\n\r\n";
        (void)write(client_fd, resp, strlen(resp));
        close(client_fd);
        return;
    }

    if (!is_authenticated(header_buf, path)) {
        send_forbidden(client_fd);
        close(client_fd);
        return;
    }

    char clean_path[512];
    snprintf(clean_path, sizeof(clean_path), "%s", path);
    char *qm = strchr(clean_path, '?');
    if (qm) *qm = '\0';

    if (strcmp(method, "GET") == 0) {
        if (strcmp(clean_path, "/") == 0 || strcmp(clean_path, "/index.html") == 0) {
            char resp_hdr[512];
            snprintf(resp_hdr, sizeof(resp_hdr),
                "HTTP/1.1 200 OK\r\n"
                "Content-Type: text/html; charset=utf-8\r\n"
                "Set-Cookie: mizu_session=%s; Path=/; SameSite=Strict\r\n"
                "Content-Length: %zu\r\n"
                "Connection: close\r\n\r\n",
                s_session_token, sizeof(s_html) - 1);
            (void)write(client_fd, resp_hdr, strlen(resp_hdr));
            (void)write(client_fd, s_html, sizeof(s_html) - 1);
        } else if (strcmp(clean_path, "/api/clip") == 0) {
            size_t text_len = 0;
            char *text = get_clipboard_text(&text_len);
            int has_img = check_clipboard_has_image();

            size_t cap = (text_len * 2) + 256;
            char *json = (char*)malloc(cap);
            if (json) {
                size_t j = 0;
                j += snprintf(json + j, cap - j, "{\"ok\":true,\"has_image\":%s,\"text\":\"", has_img ? "true" : "false");
                if (text) {
                    for (size_t i = 0; i < text_len && j + 8 < cap; i++) {
                        unsigned char c = (unsigned char)text[i];
                        if (c == '"') { json[j++] = '\\'; json[j++] = '"'; }
                        else if (c == '\\') { json[j++] = '\\'; json[j++] = '\\'; }
                        else if (c == '\n') { json[j++] = '\\'; json[j++] = 'n'; }
                        else if (c == '\r') { json[j++] = '\\'; json[j++] = 'r'; }
                        else if (c == '\t') { json[j++] = '\\'; json[j++] = 't'; }
                        else if (c < 0x20) { j += snprintf(json + j, cap - j, "\\u%04x", c); }
                        else { json[j++] = c; }
                    }
                    free(text);
                }
                j += snprintf(json + j, cap - j, "\"}");

                char resp_hdr[512];
                snprintf(resp_hdr, sizeof(resp_hdr),
                    "HTTP/1.1 200 OK\r\n"
                    "Content-Type: application/json; charset=utf-8\r\n"
                    "Access-Control-Allow-Origin: *\r\n"
                    "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
                    "Access-Control-Allow-Headers: *\r\n"
                    "Content-Length: %zu\r\n"
                    "Connection: close\r\n\r\n",
                    j);
                (void)write(client_fd, resp_hdr, strlen(resp_hdr));
                (void)write(client_fd, json, j);
                free(json);
            }
        } else if (strcmp(clean_path, "/api/image") == 0) {
            stream_clipboard_image(client_fd);
        } else {
            const char *nf = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
            (void)write(client_fd, nf, strlen(nf));
        }
    } else if (strcmp(method, "POST") == 0) {
        size_t content_length = 0;
        const char *cl = strcasestr(header_buf, "Content-Length:");
        if (cl) content_length = strtoul(cl + 15, NULL, 10);

        if (strcmp(clean_path, "/api/text") == 0) {
            size_t max_text = 1048576;
            if (content_length > max_text) content_length = max_text;

            char *text_buf = (char*)malloc(content_length + 1);
            if (text_buf) {
                size_t already = header_len - (body_start - header_buf);
                if (already > content_length) already = content_length;
                memcpy(text_buf, body_start, already);

                size_t total = already;
                while (total < content_length) {
                    ssize_t n = read(client_fd, text_buf + total, content_length - total);
                    if (n <= 0) break;
                    total += n;
                }
                text_buf[total] = '\0';
                copy_text_to_clipboard(text_buf, total);
                notify_wake();
                free(text_buf);
                send_json_ok(client_fd, NULL);
            }
        } else if (strcmp(clean_path, "/api/upload") == 0) {
            char raw_filename[256] = "upload.dat";
            const char *fn_hdr = strcasestr(header_buf, "X-Filename:");
            if (fn_hdr) {
                fn_hdr += 11;
                while (*fn_hdr == ' ') fn_hdr++;
                const char *eol = strstr(fn_hdr, "\r\n");
                size_t flen = eol ? (size_t)(eol - fn_hdr) : strlen(fn_hdr);
                if (flen >= sizeof(raw_filename)) flen = sizeof(raw_filename) - 1;
                memcpy(raw_filename, fn_hdr, flen);
                raw_filename[flen] = '\0';
            }

            char decoded_fn[256];
            url_decode(decoded_fn, raw_filename, sizeof(decoded_fn));

            char safe_fn[256];
            sanitize_filename(safe_fn, decoded_fn, sizeof(safe_fn));

            const char *home = getenv("HOME");
            char save_path[1024];
            if (home) {
                char d1[512], d2[512];
                snprintf(d1, sizeof(d1), "%s/Downloads", home);
                (void)mkdir(d1, 0755);
                snprintf(d2, sizeof(d2), "%s/Downloads/MizuShare", home);
                (void)mkdir(d2, 0755);
                snprintf(save_path, sizeof(save_path), "%s/%s", d2, safe_fn);
            } else {
                snprintf(save_path, sizeof(save_path), "/tmp/%s", safe_fn);
            }

            int out_fd = open(save_path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
            if (out_fd >= 0) {
                size_t already = header_len - (body_start - header_buf);
                if (already > content_length) already = content_length;
                if (already > 0) (void)write(out_fd, body_start, already);

                size_t total = already;
                char chunk[16384];
                while (total < content_length) {
                    size_t to_read = sizeof(chunk);
                    if (content_length - total < to_read) to_read = content_length - total;
                    ssize_t n = read(client_fd, chunk, to_read);
                    if (n <= 0) break;
                    (void)write(out_fd, chunk, n);
                    total += n;
                }
                close(out_fd);

                const char *dot = strrchr(safe_fn, '.');
                if (dot) {
                    if (strcasecmp(dot, ".png") == 0) copy_image_to_clipboard(save_path, "image/png");
                    else if (strcasecmp(dot, ".jpg") == 0 || strcasecmp(dot, ".jpeg") == 0) copy_image_to_clipboard(save_path, "image/jpeg");
                    else if (strcasecmp(dot, ".webp") == 0) copy_image_to_clipboard(save_path, "image/webp");
                }
                notify_wake();

                char extra[512];
                snprintf(extra, sizeof(extra), "\"filename\":\"%s\",\"size\":%zu,\"path\":\"~/Downloads/MizuShare/%s\"", safe_fn, total, safe_fn);
                send_json_ok(client_fd, extra);
            } else {
                const char *err = "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
                (void)write(client_fd, err, strlen(err));
            }
        }
    }

    shutdown(client_fd, SHUT_WR);
    char drain[1024];
    while (read(client_fd, drain, sizeof(drain)) > 0) {}
    close(client_fd);
}

int mizu_share_start(void) {
    pthread_mutex_lock(&s_lock);
    char info_path[128];
    get_info_path(info_path, sizeof(info_path));

    FILE *f = fopen(info_path, "r");
    if (f) {
        pid_t pid = 0;
        int port = 0;
        char token[64] = {0};
        char ip[64] = {0};
        if (fscanf(f, "%d %d %63s %63s", &pid, &port, token, ip) == 4 && pid > 0 && kill(pid, 0) == 0) {
            fclose(f);
            s_port = port;
            s_daemon_pid = pid;
            snprintf(s_session_token, sizeof(s_session_token), "%s", token);
            snprintf(s_lan_ip, sizeof(s_lan_ip), "%s", ip);
            snprintf(s_url, sizeof(s_url), "http://%s:%d/?token=%s", s_lan_ip, s_port, s_session_token);
            s_running = 1;
            pthread_mutex_unlock(&s_lock);
            return 0;
        }
        fclose(f);
        unlink(info_path);
    }

    int rnd_fd = open("/dev/urandom", O_RDONLY);
    unsigned char rnd[16];
    if (rnd_fd >= 0) {
        (void)read(rnd_fd, rnd, sizeof(rnd));
        close(rnd_fd);
    } else {
        srand((unsigned int)time(NULL));
        for (size_t i = 0; i < sizeof(rnd); i++) rnd[i] = (unsigned char)rand();
    }
    for (int i = 0; i < 16; i++) {
        snprintf(s_session_token + i * 2, 3, "%02x", rnd[i]);
    }
    s_session_token[32] = '\0';

    get_lan_ip(s_lan_ip, sizeof(s_lan_ip));

    int listen_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (listen_fd < 0) {
        pthread_mutex_unlock(&s_lock);
        return -1;
    }

    int opt = 1;
    setsockopt(listen_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port = htons(8765);

    if (bind(listen_fd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        addr.sin_port = 0;
        if (bind(listen_fd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
            close(listen_fd);
            pthread_mutex_unlock(&s_lock);
            return -1;
        }
    }

    if (listen(listen_fd, 10) < 0) {
        close(listen_fd);
        pthread_mutex_unlock(&s_lock);
        return -1;
    }

    struct sockaddr_in bound_addr;
    socklen_t bound_len = sizeof(bound_addr);
    getsockname(listen_fd, (struct sockaddr*)&bound_addr, &bound_len);
    s_port = ntohs(bound_addr.sin_port);

    snprintf(s_url, sizeof(s_url), "http://%s:%d/?token=%s", s_lan_ip, s_port, s_session_token);

    int ready_pipe[2];
    if (pipe(ready_pipe) < 0) {
        close(listen_fd);
        pthread_mutex_unlock(&s_lock);
        return -1;
    }

    pid_t pid = fork();
    if (pid < 0) {
        close(ready_pipe[0]);
        close(ready_pipe[1]);
        close(listen_fd);
        pthread_mutex_unlock(&s_lock);
        return -1;
    }

    if (pid > 0) {
        close(ready_pipe[1]);
        close(listen_fd);
        char ok = 0;
        (void)read(ready_pipe[0], &ok, 1);
        close(ready_pipe[0]);

        s_daemon_pid = pid;
        s_running = 1;
        pthread_mutex_unlock(&s_lock);
        return 0;
    }

    // Child daemon process
    close(ready_pipe[0]);
    setsid();
    s_running = 1;

    FILE *wf = fopen(info_path, "w");
    if (wf) {
        fprintf(wf, "%d %d %s %s\n", (int)getpid(), s_port, s_session_token, s_lan_ip);
        fclose(wf);
    }

    char ok = 1;
    (void)write(ready_pipe[1], &ok, 1);
    close(ready_pipe[1]);

    signal(SIGTERM, sigterm_handler);
    signal(SIGINT, sigterm_handler);
    signal(SIGPIPE, SIG_IGN);

    int devnull = open("/dev/null", O_RDWR);
    if (devnull >= 0) {
        dup2(devnull, 0);
        dup2(devnull, 1);
        dup2(devnull, 2);
        if (devnull > 2) close(devnull);
    }

    int max_fd = (int)sysconf(_SC_OPEN_MAX);
    if (max_fd < 0 || max_fd > 4096) max_fd = 1024;
    for (int fd = 3; fd < max_fd; fd++) {
        if (fd != listen_fd) {
            close(fd);
        }
    }

    while (!s_daemon_stop) {
        struct pollfd pfd;
        pfd.fd = listen_fd;
        pfd.events = POLLIN;
        int r = poll(&pfd, 1, 500);
        if (s_daemon_stop) break;
        if (r > 0 && (pfd.revents & POLLIN)) {
            struct sockaddr_in client_addr;
            socklen_t client_len = sizeof(client_addr);
            int client_fd = accept4(listen_fd, (struct sockaddr*)&client_addr, &client_len, SOCK_CLOEXEC);
            if (client_fd < 0 && errno == ENOSYS) {
                client_fd = accept(listen_fd, (struct sockaddr*)&client_addr, &client_len);
                if (client_fd >= 0) fcntl(client_fd, F_SETFD, FD_CLOEXEC);
            }
            if (client_fd >= 0) {
                handle_client(client_fd);
            }
        }
    }

    close(listen_fd);
    unlink(info_path);
    _exit(0);
}

void mizu_share_stop(void) {
    pthread_mutex_lock(&s_lock);
    char info_path[128];
    get_info_path(info_path, sizeof(info_path));

    FILE *f = fopen(info_path, "r");
    pid_t pid = 0;
    if (f) {
        if (fscanf(f, "%d", &pid) == 1 && pid > 0) {
            kill(pid, SIGTERM);
        }
        fclose(f);
        unlink(info_path);
    }
    if (s_daemon_pid > 0 && s_daemon_pid != pid) {
        kill(s_daemon_pid, SIGTERM);
    }
    pid_t to_wait = (pid > 0) ? pid : s_daemon_pid;
    if (to_wait > 0) {
        for (int i = 0; i < 50; i++) {
            int st;
            if (waitpid(to_wait, &st, WNOHANG) > 0 || kill(to_wait, 0) != 0) break;
            usleep(10000);
        }
    }
    s_daemon_pid = 0;
    s_running = 0;
    s_session_token[0] = '\0';
    s_url[0] = '\0';
    pthread_mutex_unlock(&s_lock);
}

int mizu_share_is_running(void) {
    pthread_mutex_lock(&s_lock);
    char info_path[128];
    get_info_path(info_path, sizeof(info_path));

    FILE *f = fopen(info_path, "r");
    if (!f) {
        s_running = 0;
        s_daemon_pid = 0;
        s_session_token[0] = '\0';
        s_url[0] = '\0';
        pthread_mutex_unlock(&s_lock);
        return 0;
    }
    pid_t pid = 0;
    int port = 0;
    char token[64] = {0};
    char ip[64] = {0};
    if (fscanf(f, "%d %d %63s %63s", &pid, &port, token, ip) == 4 && pid > 0 && kill(pid, 0) == 0) {
        fclose(f);
        s_port = port;
        s_daemon_pid = pid;
        snprintf(s_session_token, sizeof(s_session_token), "%s", token);
        snprintf(s_lan_ip, sizeof(s_lan_ip), "%s", ip);
        snprintf(s_url, sizeof(s_url), "http://%s:%d/?token=%s", s_lan_ip, s_port, s_session_token);
        s_running = 1;
        pthread_mutex_unlock(&s_lock);
        return 1;
    }
    fclose(f);
    unlink(info_path);
    s_running = 0;
    s_daemon_pid = 0;
    s_session_token[0] = '\0';
    s_url[0] = '\0';
    pthread_mutex_unlock(&s_lock);
    return 0;
}

const char* mizu_share_get_url(void) {
    if (s_url[0] == '\0') {
        (void)mizu_share_is_running();
    }
    return s_url;
}

const char* mizu_share_get_token(void) {
    if (s_session_token[0] == '\0') {
        (void)mizu_share_is_running();
    }
    return s_session_token;
}

void mizu_share_set_wake_fd(int fd) {
    s_wake_fd = fd;
}
