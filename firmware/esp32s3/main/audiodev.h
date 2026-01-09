/*****************************************************************************
**  MSX Audio Device Emulation
**
**    AY8910 - PSG
**    YM2413 - MSX-MUSIC
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

#include "fpga.h"

#ifdef __cplusplus
extern "C" {
#endif

struct audiodev_t;
typedef struct audiodev_t* audiodev_handle_t;

typedef uint32_t (*write_output_callback_t)(void* arg, int16_t* buffer, uint32_t count);
typedef void (*read_input_callback_t)(void* arg, int16_t* buffer, uint32_t count);

audiodev_handle_t audiodev_create(fpga_handle_t fpga_handle, read_input_callback_t read_callback, write_output_callback_t write_callback);
void audiodev_destroy(audiodev_handle_t timer);

void audiodev_stop(audiodev_handle_t fpga_handle);
void audiodev_start(audiodev_handle_t fpga_handle);

#ifdef __cplusplus
}
#endif
