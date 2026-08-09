#include <fs/filesys.h>
#include "sysconfig.h"
#include "sysdeps.h"

#include "driveclick.h"
#include "uae/fs.h"
#include "uae/glib.h"

#include <fs/data.h>

static const char *g_driveclick_path = "";
//static char *g_driveclick_name = NULL;

extern "C" {

void amiga_set_builtin_driveclick_path(const char *path)
{
    g_driveclick_path = g_strdup(path);
}

#if 0
void amiga_set_drive_sound_name(const char *name)
{
    g_driveclick_name = g_strdup(name);
}
#endif

} // extern C

#ifdef DRIVESOUND

int driveclick_loadresource (struct drvsample *sp, int drivetype)
{
    static const char *files[DS_END] = {
        "drive_click.wav",
        "drive_spin.wav",
        "drive_spinnd.wav",
        "drive_startup.wav",
        "drive_snatch.wav",
    };
    int loaded = 0;

    for (int type = 0; type < DS_END; type++) {
        char *data = NULL;
        int size = 0;
        char *path = g_build_filename(g_driveclick_path, files[type], NULL);
        gsize file_size = 0;
        if (!g_file_get_contents(path, &data, &file_size, NULL)) {
            char *name = g_build_filename("share", "fs-uae", "floppy_sounds",
                                          files[type], NULL);
            fs_data_file_content(name, &data, &size);
            g_free(name);
        } else {
            size = (int) file_size;
        }
        g_free(path);
        if (data) {
            int len = (int) size;
            struct drvsample* s = sp + type;
            s->p = decodewav((uae_u8*) data, &len);
            s->len = len;
            loaded += s->p != NULL;
            g_free(data);
        }
    }
    return loaded != 0;
}

void driveclick_fdrawcmd_close(int drive)
{

}

int driveclick_fdrawcmd_open(int drive)
{
    return 0;
}

void driveclick_fdrawcmd_detect(void)
{

}

void driveclick_fdrawcmd_seek(int drive, int cyl)
{

}

void driveclick_fdrawcmd_motor (int drive, int running)
{

}

void driveclick_fdrawcmd_vsync(void)
{

}

#endif /* DRIVESOUND */
