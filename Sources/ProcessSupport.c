#include "ProcessSupport.h"
#include <libproc.h>
#include <string.h>

int cvp_process_path(int32_t pid, char *buffer, uint32_t size) {
    return proc_pidpath(pid, buffer, size);
}

int cvp_process_identity(int32_t pid, int32_t *parent, uint64_t *seconds, uint64_t *microseconds) {
    struct proc_bsdinfo info;
    memset(&info, 0, sizeof(info));
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info)) return 0;
    *parent = (int32_t)info.pbi_ppid;
    *seconds = info.pbi_start_tvsec;
    *microseconds = info.pbi_start_tvusec;
    return 1;
}
