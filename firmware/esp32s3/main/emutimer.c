/*****************************************************************************
**  Emulation timer functionality
**
**  Copyright (C) 2025 Tim Brugman
**
**  This program is free software; you can redistribute it and/or modify
**  it under the terms of the GNU General Public License as published by
**  the Free Software Foundation; either version 2 of the License, or
**  (at your option) any later version.
** 
**  This program is distributed in the hope that it will be useful,
**  but WITHOUT ANY WARRANTY; without even the implied warranty of
**  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
**  GNU General Public License for more details.
**
**  You should have received a copy of the GNU General Public License
**  along with this program; if not, write to the Free Software
**  Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.
**
******************************************************************************/
#include "emutimer.h"

#include <string.h>
#include <freertos/FreeRTOS.h>

//static const char TAG[] = "timer";

/// Timer data
struct emutimer_t {
    uint32_t frequency;
    uint32_t prev_tick;
    uint32_t remainder;
};
typedef struct emutimer_t emutimer_t;

emutimer_handle_t timer_create(uint32_t frequency)
{
    emutimer_t *timer = (emutimer_t *)malloc(sizeof(emutimer_t));
    timer->frequency = frequency;
    timer_reset(timer);
    return timer;
}

void timer_destroy(emutimer_handle_t timer)
{
    free(timer);
}

void timer_reset(emutimer_handle_t timer)
{
    timer->prev_tick = xTaskGetTickCount();
    timer->remainder = 0;
}

uint32_t timer_get_duration(emutimer_handle_t timer)
{
    uint32_t cur_tick = xTaskGetTickCount();
    uint32_t count = pdTICKS_TO_MS((cur_tick - timer->prev_tick) * timer->frequency) + timer->remainder;
    timer->prev_tick = cur_tick;
    timer->remainder = count % 1000;
    return count /= 1000;
}
