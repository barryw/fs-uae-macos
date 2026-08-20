#ifndef FSUAE_MAC_H
#define FSUAE_MAC_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(__GNUC__)
#define FSUAE_MAC_API __attribute__((visibility("default")))
#else
#define FSUAE_MAC_API
#endif

typedef struct fsuaemac_video_frame {
    const uint8_t *pixels;
    uint32_t width;
    uint32_t height;
    uint32_t stride;
    uint32_t crop_x;
    uint32_t crop_y;
    uint32_t crop_width;
    uint32_t crop_height;
    double refresh_rate;
    uint32_t flags;
    uint64_t sequence;
} fsuaemac_video_frame;

typedef struct fsuaemac_audio_samples {
    const int16_t *samples;
    uint32_t frame_count;
    uint32_t channel_count;
    uint32_t sample_rate;
    uint64_t sequence;
} fsuaemac_audio_samples;

enum {
    FSUAE_MAC_DRIVE_FLOPPY = 0,
    FSUAE_MAC_DRIVE_HARD_DISK = 1,
};

typedef struct fsuaemac_drive_status {
    uint32_t kind;
    int32_t index;
    int32_t active;
    const char *media_path;
} fsuaemac_drive_status;

typedef struct fsuaemac_configuration {
    const char *configuration_path;
} fsuaemac_configuration;

typedef struct fsuaemac_health {
    uint64_t frame_sequence;
    uint32_t program_counter;
    uint32_t exec_base;
    uint32_t last_alert[4];
    uint32_t guest_control_ready;
    uint32_t guest_control_heartbeat;
    uint32_t guest_control_generation;
    uint64_t exception_sequence;
    uint32_t exception_vector;
    uint32_t exception_pc;
    uint32_t exception_address;
    uint32_t exception_task;
    char exception_task_name[64];
} fsuaemac_health;

typedef void (*fsuaemac_video_callback)(const fsuaemac_video_frame *frame,
                                       void *context);
typedef void (*fsuaemac_audio_callback)(const fsuaemac_audio_samples *samples,
                                       void *context);
typedef void (*fsuaemac_log_callback)(const char *message, void *context);
typedef void (*fsuaemac_drive_status_callback)(
    const fsuaemac_drive_status *status, void *context);

FSUAE_MAC_API void fsuaemac_set_video_callback(fsuaemac_video_callback callback,
                                               void *context);
FSUAE_MAC_API void fsuaemac_set_audio_callback(fsuaemac_audio_callback callback,
                                               void *context);
FSUAE_MAC_API void fsuaemac_set_log_callback(fsuaemac_log_callback callback,
                                             void *context);
FSUAE_MAC_API void fsuaemac_set_drive_status_callback(
    fsuaemac_drive_status_callback callback, void *context);

FSUAE_MAC_API int fsuaemac_start(const fsuaemac_configuration *configuration);
FSUAE_MAC_API int fsuaemac_is_running(void);
FSUAE_MAC_API int fsuaemac_get_health(fsuaemac_health *health);
FSUAE_MAC_API void fsuaemac_clear_exception(const char *task_name);
FSUAE_MAC_API void fsuaemac_stop(void);
FSUAE_MAC_API int fsuaemac_queue_input(int32_t event, int32_t state);
FSUAE_MAC_API int fsuaemac_queue_key(uint16_t mac_key_code, int32_t pressed);
FSUAE_MAC_API int fsuaemac_queue_mouse_move(int32_t delta_x, int32_t delta_y);
FSUAE_MAC_API int fsuaemac_queue_mouse_position(int32_t x, int32_t y);
FSUAE_MAC_API int fsuaemac_queue_mouse_button(uint32_t button, int32_t pressed);
FSUAE_MAC_API int fsuaemac_debug_command(const char *command, char *output,
                                         uint32_t output_size, uint32_t timeout_ms);
FSUAE_MAC_API int fsuaemac_set_speed(double multiplier);
FSUAE_MAC_API int fsuaemac_queue_pause(int32_t paused);
FSUAE_MAC_API int fsuaemac_queue_reset(int32_t hard);
FSUAE_MAC_API int fsuaemac_queue_floppy(int32_t drive, const char *path);
FSUAE_MAC_API const char *fsuaemac_last_error(void);

#ifdef __cplusplus
}
#endif

#endif
