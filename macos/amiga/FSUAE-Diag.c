#include <exec/types.h>
#include <exec/io.h>
#include <exec/ports.h>
#include <proto/exec.h>
#include <clib/alib_protos.h>
#include <ctype.h>
#include <stdio.h>
#include <string.h>

#define FSUAEDEV_QUERY     0x8001
#define FSUAEDEV_PING      0x8002
#define FSUAEDEV_READ_LOG  0x8003
#define FSUAEDEV_CLEAR_LOG 0x8004
#define FSUAE_MAGIC        0x46535545UL

struct FSUAEStatus {
    ULONG magic;
    UWORD major;
    UWORD minor;
    ULONG flags;
    ULONG kickstart;
    ULONG opens;
    ULONG requests;
    ULONG last_command;
    LONG last_error;
    ULONG heartbeats;
    ULONG log_size;
};

static char log_buffer[4097];

static LONG issue(struct IOStdReq *io, UWORD command, APTR data,
                  ULONG length, ULONG offset)
{
    io->io_Command = command;
    io->io_Data = data;
    io->io_Length = length;
    io->io_Offset = offset;
    DoIO((struct IORequest *)io);
    return io->io_Error;
}

static int status(struct IOStdReq *io)
{
    struct FSUAEStatus value;

    memset(&value, 0, sizeof(value));
    if (issue(io, FSUAEDEV_QUERY, (APTR)&value, sizeof(value), 0) ||
        value.magic != FSUAE_MAGIC) {
        puts("fsuae.device status failed");
        return 10;
    }
    printf("fsuae.device %lu.%lu\n", (ULONG)value.major, (ULONG)value.minor);
    printf("Host: %s\n", value.flags & 1 ? "connected" : "disconnected");
    printf("Control: %s\n", value.flags & 2 ? "ready" : "starting");
    printf("Kickstart: %lu\n", value.kickstart);
    printf("Opens: %lu  Requests: %lu  Heartbeats: %lu\n",
           value.opens, value.requests, value.heartbeats);
    printf("Last command: $%04lx  Last error: %ld  Log bytes: %lu\n",
           value.last_command, value.last_error, value.log_size);
    return 0;
}

static int ping(struct IOStdReq *io)
{
    const ULONG cookie = 0x13579BDFUL;

    if (issue(io, FSUAEDEV_PING, NULL, 0, cookie) || io->io_Actual != cookie) {
        puts("PING failed");
        return 10;
    }
    puts("PING ok");
    return 0;
}

static int log_output(struct IOStdReq *io)
{
    if (issue(io, FSUAEDEV_READ_LOG, (APTR)log_buffer,
              sizeof(log_buffer) - 1, 0)) {
        puts("LOG failed");
        return 10;
    }
    log_buffer[io->io_Actual] = 0;
    fputs(log_buffer, stdout);
    return 0;
}

int main(int argc, char **argv)
{
    struct MsgPort *port;
    struct IOStdReq *io;
    char *command = argc > 1 ? argv[1] : "STATUS";
    char *cursor;
    int result = 10;

    port = CreatePort(NULL, 0);
    io = port ? (struct IOStdReq *)CreateExtIO(port, sizeof(*io)) : NULL;
    if (!io || OpenDevice("fsuae.device", 0, (struct IORequest *)io, 0)) {
        puts("fsuae.device is not available");
        if (io) DeleteExtIO((struct IORequest *)io);
        if (port) DeletePort(port);
        return 10;
    }

    for (cursor = command; *cursor; cursor++) *cursor = toupper(*cursor);
    if (!strcmp(command, "STATUS")) result = status(io);
    else if (!strcmp(command, "PING")) result = ping(io);
    else if (!strcmp(command, "LOG")) result = log_output(io);
    else if (!strcmp(command, "CLEARLOG")) {
        result = issue(io, FSUAEDEV_CLEAR_LOG, NULL, 0, 0) ? 10 : 0;
    } else if (!strcmp(command, "SELFTEST")) {
        result = status(io) || ping(io) || log_output(io) ? 10 : 0;
    } else {
        puts("Usage: FSUAE-Diag [STATUS|PING|LOG|CLEARLOG|SELFTEST]");
    }

    CloseDevice((struct IORequest *)io);
    DeleteExtIO((struct IORequest *)io);
    DeletePort(port);
    return result;
}
