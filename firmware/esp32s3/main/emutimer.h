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
#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

struct emutimer_t;
typedef struct emutimer_t* emutimer_handle_t;

emutimer_handle_t timer_create(uint32_t frequency);
void timer_destroy(emutimer_handle_t timer);

void timer_reset(emutimer_handle_t timer);
uint32_t timer_get_duration(emutimer_handle_t timer);

#ifdef __cplusplus
}
#endif
