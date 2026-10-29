/* SPDX-License-Identifier: GPL-3.0-or-later */
#include <pthread.h>
#include <stdlib.h>
#include <stdio.h>
#include <unistd.h>
#include <signal.h>

/* A force-quit of the UI must not leave an invisible AirPlay receiver running. */
static void *watch_parent(void *unused) {
    (void)unused;
    const pid_t expected = (pid_t)atoi(getenv("AIRPLAYER_PARENT_PID"));
    for (;;) {
        sleep(1);
        if (getppid() != expected) {
            kill(getpid(), SIGTERM);
            sleep(3);
            _exit(0);
        }
    }
    return NULL;
}

__attribute__((constructor)) static void airplayer_initialize(void) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    const char *parent = getenv("AIRPLAYER_PARENT_PID");
    if (parent && atoi(parent) > 1) {
        pthread_t thread;
        if (pthread_create(&thread, NULL, watch_parent, NULL) == 0)
            pthread_detach(thread);
    }
}
