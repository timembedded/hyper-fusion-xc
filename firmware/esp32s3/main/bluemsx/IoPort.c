/*****************************************************************************
** $Source: /cvsroot/bluemsx/blueMSX/Src/Memory/IoPort.c,v $
**
** $Revision: 1.9 $
**
** $Date: 2008/05/25 14:22:39 $
**
** More info: http://www.bluemsx.com
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
#include "IoPort.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

typedef struct IoPortInfo {
    IoPortRead  read;
    IoPortWrite write;
    void*       ref;
} IoPortInfo;

static IoPortInfo ioTable[256];
static IoPortRegister ioRegCb;
static IoPortUnregister ioUnregCb;
static void *ioRegRef;

void ioPortInit(IoPortRegister regCb, IoPortUnregister unregCb, void *ref)
{
    ioRegCb = regCb;
    ioUnregCb = unregCb;
    ioRegRef = ref;
    ioPortReset();
}

void ioPortReset()
{
    memset(ioTable, 0, sizeof(ioTable));
}

void* ioPortGetRef(int port)
{
	return ioTable[port].ref;
}

void ioPortRegister(int port, IoPortRead read, IoPortWrite write, void* ref)
{
    if (ioTable[port].read  == NULL && 
        ioTable[port].write == NULL && 
        ioTable[port].ref   == NULL)
    {
        ioTable[port].read  = read;
        ioTable[port].write = write;
        ioTable[port].ref   = ref;

        IoPortProperties_t prop = 0;
        if (read != NULL) {
            prop |= IoPropRead;
        }
        if (write != NULL) {
            prop |= IoPropWrite;
        }
        ioRegCb(port, prop, ioRegRef);
    }
}

void ioPortUnregister(int port)
{
    ioUnregCb(port, ioRegRef);
    ioTable[port].read  = NULL;
    ioTable[port].write = NULL;
    ioTable[port].ref   = NULL;
}

UInt8 ioPortReadPort(UInt16 port)
{
    port &= 0xff;

    if (ioTable[port].read == NULL) {
        return 0xff;
    }

    return ioTable[port].read(ioTable[port].ref, port);
}

void  ioPortWritePort(UInt16 port, UInt8 value)
{
    port &= 0xff;

    if (ioTable[port].write != NULL) {
        ioTable[port].write(ioTable[port].ref, port, value);
    }
}


