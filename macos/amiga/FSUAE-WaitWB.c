#include <exec/types.h>
#include <intuition/intuition.h>
#include <intuition/intuitionbase.h>
#include <intuition/screens.h>
#include <proto/dos.h>
#include <proto/exec.h>
#include <proto/intuition.h>
#include <stdio.h>
#include <stdlib.h>

struct IntuitionBase *IntuitionBase;

static int workbench_ready(void)
{
    struct Screen *screen;
    ULONG lock;
    int ready = 0;

    lock = LockIBase(0);
    for (screen = IntuitionBase->FirstScreen; screen; screen = screen->NextScreen) {
        if ((screen->Flags & SCREENTYPE) == WBENCHSCREEN && screen->FirstWindow) {
            ready = 1;
            break;
        }
    }
    UnlockIBase(lock);
    return ready;
}

int main(int argc, char **argv)
{
    long seconds = argc > 1 ? atol(argv[1]) : 120;
    long checks;

    if (seconds < 0 || seconds > 600) {
        puts("Usage: FSUAE-WaitWB [seconds: 0-600]");
        return 10;
    }
    IntuitionBase = (struct IntuitionBase *)OpenLibrary("intuition.library", 0);
    if (!IntuitionBase) {
        puts("INTUITION_UNAVAILABLE");
        return 10;
    }

    checks = seconds * 10;
    do {
        if (workbench_ready()) {
            puts("WORKBENCH_READY");
            CloseLibrary((struct Library *)IntuitionBase);
            return 0;
        }
        if (checks) Delay(5);
    } while (checks-- > 0);

    puts("WORKBENCH_TIMEOUT");
    CloseLibrary((struct Library *)IntuitionBase);
    return 5;
}
