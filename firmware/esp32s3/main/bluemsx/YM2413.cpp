/*****************************************************************************
** $Source: /cvsroot/bluemsx/blueMSX/Src/SoundChips/YM2413.cpp,v $
**
** $Revision: 1.19 $
**
** $Date: 2007/05/23 09:41:56 $
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
#include "YM2413.h"
#include "OpenMsxYM2413.h"
#include "OpenMsxYM2413_2.h"
#include <cstring>
#include "IoPort.h"

#define FREQUENCY        3579545
 
struct YM_2413 {
    YM_2413() : address(0) {
        if (0) {
             ym2413 = new OpenYM2413(100);
        }
        else {
             ym2413 = new OpenYM2413_2(100);
        }
        memset(defaultBuffer, 0, sizeof(defaultBuffer));
    }

    ~YM_2413() {
        delete ym2413;
    }

    Mixer* mixer;
    Int32  handle;

    OpenYM2413Base* ym2413;
    UInt8  address;
    UInt8  registers[256];
    Int32  buffer[AUDIO_MONO_BUFFER_SIZE];
    Int32  defaultBuffer[AUDIO_MONO_BUFFER_SIZE];
};

void ym2413Reset(YM_2413* ref)
{
    YM_2413* ym2413 = (YM_2413*)ref;

    ym2413->ym2413->reset();
}

void ym2413WriteAddress(YM_2413* ym2413, UInt8 address)
{
    ym2413->address = address & 0x3f;
}

void ym2413WriteData(YM_2413* ym2413, UInt8 data)
{
    mixerSync(ym2413->mixer);
    ym2413->registers[ym2413->address & 0xff] = data;
    ym2413->ym2413->writeReg(ym2413->address, data);
}

static Int32* ym2413Sync(void* ref, UInt32 count) 
{
    YM_2413* ym2413 = (YM_2413*)ref;
    int* genBuf;
    UInt32 i;

    genBuf = ym2413->ym2413->updateBuffer(count);

    if (genBuf == NULL) {
        return ym2413->defaultBuffer;
    }

    for (i = 0; i < count; i++) {
        ym2413->buffer[i] = genBuf[i];
    }

    return ym2413->buffer;
}

static void writeAddr(void *ym, UInt16 port, UInt8 data)
{
    YM_2413* ym2413 = (YM_2413*)ym;
    ym2413WriteAddress(ym2413, data);
}

static void writeData(void *ym, UInt16 port, UInt8 data)
{
    YM_2413* ym2413 = (YM_2413*)ym;
    ym2413WriteData(ym2413, data);
}

YM_2413* ym2413Create(Mixer* mixer)
{
    YM_2413* ym2413;

    ym2413 = new YM_2413;

    ym2413->mixer = mixer;

    ym2413->handle = mixerRegisterChannel(mixer, MIXER_CHANNEL_MSXMUSIC, 0, ym2413Sync, ym2413);

    ym2413->ym2413->setSampleRate(AUDIO_SAMPLERATE, oversamplingYM2413);
    ym2413->ym2413->setVolume(32767 * 9 / 10);

    ym2413->ym2413->reset();

    ioPortRegister(0x7c, NULL, writeAddr, ym2413);
    ioPortRegister(0x7d, NULL, writeData, ym2413);

    return ym2413;
}

void ym2413Destroy(YM_2413* ym2413) 
{
    ioPortUnregister(0x7c);
    ioPortUnregister(0x7d);
    mixerUnregisterChannel(ym2413->mixer, ym2413->handle);
    delete ym2413;
}

