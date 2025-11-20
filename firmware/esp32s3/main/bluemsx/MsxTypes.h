/*****************************************************************************
** File:        msxTypes.h
**
** Author:      Daniel Vik
**
** Description: Type definitions
**
** More info:   www.bluemsx.com
**
** Copyright (C) 2003-2006 Daniel Vik
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
******************************************************************************
*/
#ifndef BLUEMSX_TYPES
#define BLUEMSX_TYPES

#ifdef __cplusplus
extern "C" {
#endif


#ifdef __GNUC__
#define __int64 long long
#endif

#ifdef _WIN32
#define DIR_SEPARATOR "\\"
#else
#define DIR_SEPARATOR "/"
#endif

#include <stdbool.h>
#include <stdint.h>
#include "esp_attr.h"

typedef uint8_t    UInt8;
typedef uint16_t   UInt16;
typedef uint32_t   UInt32;
typedef uint64_t   UInt64;
typedef int8_t     Int8;
typedef int16_t    Int16;
typedef int32_t    Int32;

// Define color stuff

#if PIXEL_WIDTH==32

#define COLSHIFT_R  16
#define COLMASK_R   0xff
#define COLSHIFT_G  8
#define COLMASK_G   0xff
#define COLSHIFT_B  0
#define COLMASK_B   0xff

typedef UInt32 Pixel;

#elif PIXEL_WIDTH==8

#define COLSHIFT_R  10
#define COLMASK_R   0x1f
#define COLSHIFT_G  5
#define COLMASK_G   0x1f
#define COLSHIFT_B  0
#define COLMASK_B   0x1f

typedef UInt8 Pixel;

#else

#define COLSHIFT_R  5
#define COLMASK_R   0x07
#define COLSHIFT_G  2
#define COLMASK_G   0x03
#define COLSHIFT_B  0
#define COLMASK_B   0x07

typedef UInt16 Pixel;

#endif

#define dbgEnable()
#define dbgDisable()
#define dbgPrint()

#ifdef __cplusplus
}
#endif

#endif
