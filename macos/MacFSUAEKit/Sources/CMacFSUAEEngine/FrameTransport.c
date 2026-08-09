#include "MacFSUAEEngine.h"

#include <fcntl.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#define FRAME_CAPACITY (3072u * 2048u * 4u)

typedef struct SharedFrame {
    _Atomic uint64_t version;
    fsuaemac_video_frame frame;
    uint8_t pixels[FRAME_CAPACITY];
} SharedFrame;

struct MacFSUAEFrameTransport {
    int fd;
    SharedFrame *shared;
};

static MacFSUAEFrameTransport *open_transport(const char *path, int create)
{
    int flags = create ? O_RDWR | O_CREAT | O_TRUNC : O_RDWR;
    int fd = open(path, flags, 0600);
    if (fd < 0 || (create && ftruncate(fd, sizeof(SharedFrame)) != 0)) {
        if (fd >= 0) close(fd);
        return NULL;
    }
    SharedFrame *shared = mmap(NULL, sizeof(SharedFrame), PROT_READ | PROT_WRITE,
                               MAP_SHARED, fd, 0);
    if (shared == MAP_FAILED) {
        close(fd);
        return NULL;
    }
    MacFSUAEFrameTransport *transport = calloc(1, sizeof(*transport));
    if (!transport) {
        munmap(shared, sizeof(SharedFrame));
        close(fd);
        return NULL;
    }
    transport->fd = fd;
    transport->shared = shared;
    if (create) atomic_store(&shared->version, 0);
    return transport;
}

MacFSUAEFrameTransport *MacFSUAEFrameTransportCreate(const char *path)
{
    return path ? open_transport(path, 1) : NULL;
}

MacFSUAEFrameTransport *MacFSUAEFrameTransportOpen(const char *path)
{
    return path ? open_transport(path, 0) : NULL;
}

void MacFSUAEFrameTransportClose(MacFSUAEFrameTransport *transport)
{
    if (!transport) return;
    munmap(transport->shared, sizeof(SharedFrame));
    close(transport->fd);
    free(transport);
}

int MacFSUAEFrameTransportPublish(MacFSUAEFrameTransport *transport,
                                  const fsuaemac_video_frame *frame)
{
    if (!transport || !frame || !frame->pixels) return 0;
    size_t size = (size_t)frame->stride * frame->height;
    if (size == 0 || size > FRAME_CAPACITY) return 0;
    atomic_fetch_add_explicit(&transport->shared->version, 1, memory_order_acq_rel);
    transport->shared->frame = *frame;
    transport->shared->frame.pixels = NULL;
    memcpy(transport->shared->pixels, frame->pixels, size);
    atomic_fetch_add_explicit(&transport->shared->version, 1, memory_order_release);
    return 1;
}

int MacFSUAEFrameTransportCopyLatest(MacFSUAEFrameTransport *transport,
                                     uint64_t after_sequence,
                                     fsuaemac_video_frame *frame,
                                     void **pixels)
{
    if (!transport || !frame || !pixels) return 0;
    for (int attempt = 0; attempt < 3; attempt++) {
        uint64_t before = atomic_load_explicit(&transport->shared->version,
                                               memory_order_acquire);
        if (before & 1) continue;
        fsuaemac_video_frame value = transport->shared->frame;
        size_t size = (size_t)value.stride * value.height;
        if (value.sequence == after_sequence || size == 0 || size > FRAME_CAPACITY) return 0;
        void *copy = malloc(size);
        if (!copy) return 0;
        memcpy(copy, transport->shared->pixels, size);
        uint64_t after = atomic_load_explicit(&transport->shared->version,
                                              memory_order_acquire);
        if (before == after) {
            value.pixels = copy;
            *frame = value;
            *pixels = copy;
            return 1;
        }
        free(copy);
    }
    return 0;
}
