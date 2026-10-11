#include <stdlib.h>

const char *dyld_get_mmap_sandbox_map_exec_allowed_path(void)
{
    const char *home = getenv("HOME");
    return home != NULL ? home : "";
}
