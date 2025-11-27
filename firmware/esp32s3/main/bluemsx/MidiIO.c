/*****************************************************************************
** $Source: /cvsroot/bluemsx/blueMSX/Src/IoDevice/MidiIO.c,v $
**
** $Revision: 1.9 $
**
** $Date: 2008/03/31 19:42:19 $
**
** More info: http://www.bluemsx.com
**
** Copyright (C) 2003-2006 Daniel Vik, Tomas Karlsson
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
#include <stdlib.h>
#include <string.h>
#include "MidiIO.h"
#include "Board.h"

struct MidiIO {
    MidiIOCb cb;
    void* ref;
};
typedef struct MidiIO MidiIO;

MidiIO* theYkIO = NULL;

void midiIoTransmit(MidiIO* midiIo, UInt8 value)
{
}

MidiIO* midiIoCreate(MidiIOCb cb, void* ref)
{
    MidiIO* midiIo = calloc(1, sizeof(MidiIO));

    midiIo->cb = cb;
    midiIo->ref = ref;

    return midiIo;
}

void midiIoDestroy(MidiIO* midiIo)
{
    free(midiIo);
}

void midiIoSetMidiOutType(MidiType type, const char* fileName)
{   
}

void midiIoSetMidiInType(MidiType type, const char* fileName)
{
}


MidiIO* ykIoCreate()
{
    MidiIO* ykIo = calloc(1, sizeof(MidiIO));

    theYkIO = ykIo;

    return ykIo;
}

void ykIoDestroy(MidiIO* ykIo)
{
    free(ykIo);
    theYkIO = NULL;
}

void ykIoSetMidiInType(MidiType type, const char* fileName)
{
}

int ykIoGetKeyState(MidiIO* midiIo, int key)
{
    return 0;
}
