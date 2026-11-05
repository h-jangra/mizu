#ifndef MIZU_SHARE_H
#define MIZU_SHARE_H

#ifdef __cplusplus
extern "C" {
#endif

int mizu_share_start(void);
void mizu_share_stop(void);
int mizu_share_is_running(void);
const char* mizu_share_get_url(void);
const char* mizu_share_get_token(void);
void mizu_share_set_wake_fd(int fd);

#ifdef __cplusplus
}
#endif

#endif // MIZU_SHARE_H
