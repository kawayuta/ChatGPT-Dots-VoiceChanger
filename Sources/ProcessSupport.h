#pragma once
#include <stdint.h>
#include <stddef.h>
int cvp_process_path(int32_t pid, char *buffer, uint32_t size);
int cvp_process_identity(int32_t pid, int32_t *parent, uint64_t *start_seconds, uint64_t *start_microseconds);
