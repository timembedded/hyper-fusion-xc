/*****************************************************************************
**
** Copyright (C) 2025 Tim Brugman
**
** This program is free software; you can redistribute it and/or modify
** it under the terms of the GNU General Public License as published by
** the Free Software Foundation; either version 2 of the License, or
** (at your option) any later version.
** 
** This program is distributed in the hope that it will be useful,
** but WITHOUT ANY WARRANTY; without even the implied warranty of
** MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
** GNU General Public License for more details.
**
** You should have received a copy of the GNU General Public License
** along with this program; if not, write to the Free Software
** Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.
**
******************************************************************************/
#include "Board.h"

#ifdef __cplusplus
extern "C" {
#endif

static uint32_t s_pending_irq;
static void* irq_callback_ref;
static void (*irq_set_callback)(void* ref);
static void (*irq_clear_callback)(void* ref);

void boardSetIrqCallbacks(void (*set_callback)(void* ref), void (*clear_callback)(void* ref), void* ref)
{
    irq_set_callback = set_callback;
    irq_clear_callback = clear_callback;
    irq_callback_ref = ref;
}

void boardSetInt(uint32_t irq)
{
    bool was_pending = (s_pending_irq != 0);

    s_pending_irq |= irq;

    if (s_pending_irq != 0 && !was_pending) {
        irq_set_callback(irq_callback_ref);
    }
}

void boardClearInt(uint32_t irq)
{
    bool was_pending = (s_pending_irq != 0);

    s_pending_irq &= ~irq;

    if (s_pending_irq == 0 && was_pending) {
        irq_clear_callback(irq_callback_ref);
    }
}

#ifdef __cplusplus
}
#endif
