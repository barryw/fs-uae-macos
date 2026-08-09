#include "../include/fsuaemac.h"

#include <dlfcn.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>

static atomic_uint video_frames;
static atomic_uint audio_buffers;
static atomic_uint drive_mask;
static atomic_ullong first_video_ns;
static atomic_ullong last_video_ns;

static unsigned long long monotonic_ns(void)
{
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (unsigned long long) now.tv_sec * 1000000000ULL + now.tv_nsec;
}

static void timed_out(int signal_number)
{
    (void) signal_number;
    _exit(124);
}

static void video(const fsuaemac_video_frame *frame, void *context)
{
    (void) context;
    if (frame && frame->pixels && frame->width && frame->height &&
        frame->stride >= frame->width * 4) {
        unsigned previous = atomic_fetch_add(&video_frames, 1);
        unsigned long long now = monotonic_ns();
        if (previous == 0) {
            atomic_store(&first_video_ns, now);
        }
        atomic_store(&last_video_ns, now);
    }
}

static void audio(const fsuaemac_audio_samples *samples, void *context)
{
    (void) context;
    if (samples && samples->samples && samples->frame_count &&
        samples->channel_count == 2 && samples->sample_rate == 44100) {
        atomic_fetch_add(&audio_buffers, 1);
    }
}

static void drive_status(const fsuaemac_drive_status *status, void *context)
{
    (void) context;
    if (status && status->kind == FSUAE_MAC_DRIVE_FLOPPY &&
        status->index >= 0 && status->index < 4) {
        atomic_fetch_or(&drive_mask, 1u << status->index);
    }
}

#define LOAD(NAME)                                                            \
    __typeof__(&NAME) NAME##_fn = (__typeof__(&NAME)) dlsym(runtime, #NAME);   \
    if (!NAME##_fn) {                                                          \
        fprintf(stderr, "Missing %s: %s\n", #NAME, dlerror());                \
        return 1;                                                              \
    }

int main(int argc, char **argv)
{
    if (argc != 3) {
        fprintf(stderr, "usage: %s libfsuaemac.dylib configuration.fs-uae\n", argv[0]);
        return 2;
    }

    signal(SIGALRM, timed_out);
    static const uint16_t keys[] = {
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17,
        18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33,
        34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49,
        50, 51, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 65, 67, 69, 75,
        76, 78, 82, 83, 84, 85, 86, 87, 88, 89, 91, 92, 96, 97, 98, 99,
        100, 101, 109, 114, 115, 116, 117, 118, 119, 120, 121, 122, 123,
        124, 125, 126,
    };
    for (int session = 1; session <= 2; ++session) {
        atomic_store(&video_frames, 0);
        atomic_store(&audio_buffers, 0);
        atomic_store(&drive_mask, 0);
        atomic_store(&first_video_ns, 0);
        atomic_store(&last_video_ns, 0);

        void *runtime = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
        if (!runtime) {
            fprintf(stderr, "%s\n", dlerror());
            return 1;
        }
        LOAD(fsuaemac_set_video_callback);
        LOAD(fsuaemac_set_audio_callback);
        LOAD(fsuaemac_set_drive_status_callback);
        LOAD(fsuaemac_start);
        LOAD(fsuaemac_is_running);
        LOAD(fsuaemac_stop);
        LOAD(fsuaemac_queue_key);
        LOAD(fsuaemac_queue_mouse_move);
        LOAD(fsuaemac_queue_mouse_button);
        LOAD(fsuaemac_queue_pause);
        LOAD(fsuaemac_set_speed);
        LOAD(fsuaemac_last_error);

        alarm(20);
        fsuaemac_set_video_callback_fn(video, NULL);
        fsuaemac_set_audio_callback_fn(audio, NULL);
        fsuaemac_set_drive_status_callback_fn(drive_status, NULL);
        fsuaemac_configuration configuration = {argv[2]};
        if (!fsuaemac_start_fn(&configuration)) {
            fprintf(stderr, "%s\n", fsuaemac_last_error_fn());
            return 1;
        }
        fsuaemac_set_speed_fn(1.0);
        int keys_ok = 1;
        for (unsigned i = 0; i < sizeof(keys) / sizeof(keys[0]); ++i) {
            keys_ok &= fsuaemac_queue_key_fn(keys[i], 1);
            keys_ok &= fsuaemac_queue_key_fn(keys[i], 0);
        }
        fsuaemac_queue_mouse_move_fn(4, -3);
        fsuaemac_queue_mouse_button_fn(0, 1);
        fsuaemac_queue_mouse_button_fn(0, 0);

        const struct timespec interval = {.tv_nsec = 50 * 1000 * 1000};
        for (int attempt = 0; attempt < 300; ++attempt) {
            if (atomic_load(&video_frames) >= 10 && atomic_load(&audio_buffers)) {
                break;
            }
            if (!fsuaemac_is_running_fn()) {
                break;
            }
            nanosleep(&interval, NULL);
        }

        unsigned before_pause = atomic_load(&video_frames);
        fsuaemac_queue_pause_fn(1);
        struct timespec pause_interval = {.tv_nsec = 250 * 1000 * 1000};
        nanosleep(&pause_interval, NULL);
        unsigned paused_at = atomic_load(&video_frames);
        fsuaemac_queue_pause_fn(0);
        for (int attempt = 0; attempt < 40 &&
             atomic_load(&video_frames) < paused_at + 3; ++attempt) {
            nanosleep(&interval, NULL);
        }
        int pause_ok = paused_at <= before_pause + 2 &&
            atomic_load(&video_frames) >= paused_at + 3;

        unsigned frames = atomic_load(&video_frames);
        unsigned buffers = atomic_load(&audio_buffers);
        unsigned drives = atomic_load(&drive_mask);
        unsigned long long elapsed_ms =
            (atomic_load(&last_video_ns) - atomic_load(&first_video_ns)) / 1000000ULL;
        if (session == 2) {
            fsuaemac_queue_pause_fn(1);
            nanosleep(&pause_interval, NULL);
        }
        fsuaemac_stop_fn();
        alarm(0);
        dlclose(runtime);
        printf("session=%d video=%u audio=%u drives=0x%x keys=%s pause=%s elapsed=%llums\n",
               session, frames, buffers, drives, keys_ok ? "ok" : "failed",
               pause_ok ? "ok" : "failed", elapsed_ms);
        if (frames < 10 || !buffers || !drives || !keys_ok || !pause_ok || elapsed_ms < 120) {
            return 1;
        }
    }
    return 0;
}
