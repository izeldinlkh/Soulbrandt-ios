#include <stdio.h>
#include <string.h>
#include "udfread.h"

int main(int argc, char **argv)
{
    if (argc != 2) {
        fprintf(stderr, "usage: udf-smoke IMAGE.iso\n");
        return 2;
    }

    udfread *volume = udfread_init();
    if (!volume) {
        fprintf(stderr, "udfread_init failed\n");
        return 1;
    }
    if (udfread_open(volume, argv[1]) < 0) {
        fprintf(stderr, "udfread_open failed\n");
        udfread_close(volume);
        return 1;
    }

    UDFDIR *directory = udfread_opendir(volume, "/PS3_GAME/USRDIR");
    if (!directory) {
        fprintf(stderr, "could not open /PS3_GAME/USRDIR\n");
        udfread_close(volume);
        return 1;
    }

    struct udfread_dirent storage;
    struct udfread_dirent *entry;
    int found = 0;
    while ((entry = udfread_readdir(directory, &storage)) != NULL) {
        if (entry->d_name && strcmp(entry->d_name, "EBOOT.ELF") == 0) {
            found = 1;
            break;
        }
    }
    udfread_closedir(directory);
    if (!found) {
        fprintf(stderr, "EBOOT.ELF missing from UDF directory listing\n");
        udfread_close(volume);
        return 1;
    }

    UDFFILE *file = udfread_file_open(volume, "/PS3_GAME/USRDIR/EBOOT.ELF");
    if (!file) {
        fprintf(stderr, "could not open EBOOT.ELF\n");
        udfread_close(volume);
        return 1;
    }

    char contents[13] = {0};
    ssize_t count = udfread_file_read(file, contents, 12);
    udfread_file_close(file);
    udfread_close(volume);

    if (count != 12 || memcmp(contents, "udf-smoke-ok", 12) != 0) {
        fprintf(stderr, "UDF file read returned incorrect data (%zd bytes)\n", count);
        return 1;
    }

    puts("libudfread UDF smoke test passed");
    return 0;
}
