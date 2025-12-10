/*
  FIFO implementation
*/
#include "fifo.h"

void fifo_init(fifo_t *fifo, uint8_t *buffer, int size)
{
    fifo->data = buffer;
    fifo->size = size;
    fifo->rdp = buffer;
    fifo->wrp = buffer;
    fifo->endp = buffer + size;
}

bool fifo_push(fifo_t *fifo, uint8_t *data, int len)
{
    while(len > 0) {
        uint8_t *next_wrp = fifo->wrp + 1;
        if (next_wrp == fifo->endp) {
            next_wrp = fifo->data;
        }
        if (next_wrp == fifo->rdp) { // full
            return false;
        }
        *fifo->wrp = *data;
        data++;
        fifo->wrp = next_wrp;
        len--;
    }
    return true;
}

bool fifo_pop_byte(fifo_t *fifo, uint8_t *bt)
{
    if (fifo->rdp == fifo->wrp) {
        // empty
        return false;
    }
    uint8_t *next_rdp = fifo->rdp + 1;
    if (next_rdp == fifo->endp) {
        next_rdp = fifo->data;
    }
    *bt = *fifo->rdp;
    fifo->rdp = next_rdp;
    return true;
}
