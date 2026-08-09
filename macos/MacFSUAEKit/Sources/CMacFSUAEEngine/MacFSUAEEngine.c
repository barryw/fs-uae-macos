#include "MacFSUAEEngine.h"

#include <dlfcn.h>
#include <stdio.h>
#include <string.h>

typedef struct Symbols {
    void (*setVideo)(fsuaemac_video_callback, void *);
    void (*setAudio)(fsuaemac_audio_callback, void *);
    void (*setLog)(fsuaemac_log_callback, void *);
    void (*setDriveStatus)(fsuaemac_drive_status_callback, void *);
    int (*start)(const fsuaemac_configuration *);
    int (*isRunning)(void);
    int (*getHealth)(fsuaemac_health *);
    void (*clearException)(void);
    void (*stop)(void);
    int (*queueKey)(uint16_t, int32_t);
    int (*queueMouseMove)(int32_t, int32_t);
    int (*queueMouseButton)(uint32_t, int32_t);
    int (*debugCommand)(const char *, char *, uint32_t, uint32_t);
    int (*setSpeed)(double);
    int (*queuePause)(int32_t);
    int (*queueReset)(int32_t);
    int (*queueFloppy)(int32_t, const char *);
    const char *(*lastError)(void);
} Symbols;

static void *runtime;
static Symbols symbols;
static char lastError[512];

#define LOAD(FIELD, NAME)                                                     \
    do {                                                                      \
        *(void **)(&symbols.FIELD) = dlsym(runtime, NAME);                    \
        if (!symbols.FIELD) {                                                 \
            snprintf(lastError, sizeof(lastError), "Missing runtime symbol %s", NAME); \
            MacFSUAEEngineUnload();                                           \
            return 0;                                                         \
        }                                                                     \
    } while (0)

int MacFSUAEEngineLoad(const char *path)
{
    if (runtime || !path) {
        return runtime != NULL;
    }
    runtime = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!runtime) {
        snprintf(lastError, sizeof(lastError), "%s", dlerror());
        return 0;
    }
    LOAD(setVideo, "fsuaemac_set_video_callback");
    LOAD(setAudio, "fsuaemac_set_audio_callback");
    LOAD(setLog, "fsuaemac_set_log_callback");
    LOAD(setDriveStatus, "fsuaemac_set_drive_status_callback");
    LOAD(start, "fsuaemac_start");
    LOAD(isRunning, "fsuaemac_is_running");
    LOAD(getHealth, "fsuaemac_get_health");
    LOAD(clearException, "fsuaemac_clear_exception");
    LOAD(stop, "fsuaemac_stop");
    LOAD(queueKey, "fsuaemac_queue_key");
    LOAD(queueMouseMove, "fsuaemac_queue_mouse_move");
    LOAD(queueMouseButton, "fsuaemac_queue_mouse_button");
    LOAD(debugCommand, "fsuaemac_debug_command");
    LOAD(setSpeed, "fsuaemac_set_speed");
    LOAD(queuePause, "fsuaemac_queue_pause");
    LOAD(queueReset, "fsuaemac_queue_reset");
    LOAD(queueFloppy, "fsuaemac_queue_floppy");
    LOAD(lastError, "fsuaemac_last_error");
    lastError[0] = '\0';
    return 1;
}

void MacFSUAEEngineUnload(void)
{
    if (runtime) {
        dlclose(runtime);
    }
    runtime = NULL;
    memset(&symbols, 0, sizeof(symbols));
}

const char *MacFSUAEEngineLastError(void)
{
    return lastError[0] ? lastError : (symbols.lastError ? symbols.lastError() : "Runtime not loaded");
}

void MacFSUAEEngineSetVideoCallback(fsuaemac_video_callback callback, void *context)
{
    if (symbols.setVideo) symbols.setVideo(callback, context);
}

void MacFSUAEEngineSetAudioCallback(fsuaemac_audio_callback callback, void *context)
{
    if (symbols.setAudio) symbols.setAudio(callback, context);
}

void MacFSUAEEngineSetLogCallback(fsuaemac_log_callback callback, void *context)
{
    if (symbols.setLog) symbols.setLog(callback, context);
}

void MacFSUAEEngineSetDriveStatusCallback(fsuaemac_drive_status_callback callback,
                                          void *context)
{
    if (symbols.setDriveStatus) symbols.setDriveStatus(callback, context);
}

int MacFSUAEEngineStart(const fsuaemac_configuration *configuration)
{
    return symbols.start ? symbols.start(configuration) : 0;
}

int MacFSUAEEngineIsRunning(void) { return symbols.isRunning ? symbols.isRunning() : 0; }
int MacFSUAEEngineGetHealth(fsuaemac_health *health) { return symbols.getHealth ? symbols.getHealth(health) : 0; }
void MacFSUAEEngineClearException(void) { if (symbols.clearException) symbols.clearException(); }
void MacFSUAEEngineStop(void) { if (symbols.stop) symbols.stop(); }
int MacFSUAEEngineQueueKey(uint16_t key, int32_t pressed) { return symbols.queueKey ? symbols.queueKey(key, pressed) : 0; }
int MacFSUAEEngineQueueMouseMove(int32_t deltaX, int32_t deltaY) { return symbols.queueMouseMove ? symbols.queueMouseMove(deltaX, deltaY) : 0; }
int MacFSUAEEngineQueueMouseButton(uint32_t button, int32_t pressed) { return symbols.queueMouseButton ? symbols.queueMouseButton(button, pressed) : 0; }
int MacFSUAEEngineDebugCommand(const char *command, char *output, uint32_t outputSize, uint32_t timeoutMilliseconds) { return symbols.debugCommand ? symbols.debugCommand(command, output, outputSize, timeoutMilliseconds) : 0; }
int MacFSUAEEngineSetSpeed(double multiplier) { return symbols.setSpeed ? symbols.setSpeed(multiplier) : 0; }
int MacFSUAEEngineQueuePause(int32_t paused) { return symbols.queuePause ? symbols.queuePause(paused) : 0; }
int MacFSUAEEngineQueueReset(int32_t hard) { return symbols.queueReset ? symbols.queueReset(hard) : 0; }
int MacFSUAEEngineQueueFloppy(int32_t drive, const char *path) { return symbols.queueFloppy ? symbols.queueFloppy(drive, path) : 0; }
