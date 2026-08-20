#ifndef MAC_FSUAE_ENGINE_H
#define MAC_FSUAE_ENGINE_H

#include "../../../../include/fsuaemac.h"

#ifdef __cplusplus
extern "C" {
#endif

int MacFSUAEEngineLoad(const char *path);
void MacFSUAEEngineUnload(void);
const char *MacFSUAEEngineLastError(void);
void MacFSUAEEngineSetVideoCallback(fsuaemac_video_callback callback,
                                    void *context);
void MacFSUAEEngineSetAudioCallback(fsuaemac_audio_callback callback,
                                    void *context);
void MacFSUAEEngineSetLogCallback(fsuaemac_log_callback callback,
                                  void *context);
void MacFSUAEEngineSetDriveStatusCallback(fsuaemac_drive_status_callback callback,
                                          void *context);
int MacFSUAEEngineStart(const fsuaemac_configuration *configuration);
int MacFSUAEEngineIsRunning(void);
int MacFSUAEEngineGetHealth(fsuaemac_health *health);
void MacFSUAEEngineClearException(const char *taskName);
void MacFSUAEEngineStop(void);
int MacFSUAEEngineQueueKey(uint16_t key, int32_t pressed);
int MacFSUAEEngineQueueMouseMove(int32_t deltaX, int32_t deltaY);
int MacFSUAEEngineQueueMousePosition(int32_t x, int32_t y);
int MacFSUAEEngineQueueMouseButton(uint32_t button, int32_t pressed);
int MacFSUAEEngineDebugCommand(const char *command, char *output,
                               uint32_t outputSize, uint32_t timeoutMilliseconds);
int MacFSUAEEngineSetSpeed(double multiplier);
int MacFSUAEEngineQueuePause(int32_t paused);
int MacFSUAEEngineQueueReset(int32_t hard);
int MacFSUAEEngineQueueFloppy(int32_t drive, const char *path);

typedef struct MacFSUAEFrameTransport MacFSUAEFrameTransport;

MacFSUAEFrameTransport *MacFSUAEFrameTransportCreate(const char *path);
MacFSUAEFrameTransport *MacFSUAEFrameTransportOpen(const char *path);
void MacFSUAEFrameTransportClose(MacFSUAEFrameTransport *transport);
int MacFSUAEFrameTransportPublish(MacFSUAEFrameTransport *transport,
                                  const fsuaemac_video_frame *frame);
int MacFSUAEFrameTransportCopyLatest(MacFSUAEFrameTransport *transport,
                                     uint64_t after_sequence,
                                     fsuaemac_video_frame *frame,
                                     void **pixels);

#ifdef __cplusplus
}
#endif

#endif
