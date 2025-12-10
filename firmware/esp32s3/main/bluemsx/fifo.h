/*
  FIFO implementation
*/
#pragma once

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    uint8_t *data;
    int size;
    uint8_t *rdp;
    uint8_t *wrp;
    uint8_t *endp;
} fifo_t;

void fifo_init(fifo_t *fifo, uint8_t *buffer, int size);
bool fifo_push(fifo_t *fifo, uint8_t *data, int len);
bool fifo_pop_byte(fifo_t *fifo, uint8_t *bt);

#ifdef __cplusplus
}
#endif
