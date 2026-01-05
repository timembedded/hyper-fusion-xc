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
#include "YM2413Burczynski.hh"
#include <cstring>
#include "Board.h"
#include "IoPort.h"
#include <span>
#include "xrange.hh"

#define FREQUENCY        3579545
 
struct YM_2413 {
    YM_2413() {
        chip = new openmsx::YM2413Burczynski::YM2413();
        address = 0;
    }
    ~YM_2413() {
        delete chip;
    }

    Mixer* mixer;
    Int32  handle;
    uint8_t address;

    openmsx::YM2413Core* chip;
};

void ym2413Reset(YM_2413* ref)
{
    YM_2413* ym2413 = (YM_2413*)ref;
    ym2413->chip->reset();
}

bool ym2413IsMuted(YM_2413* ref)
{
    YM_2413* ym2413 = (YM_2413*)ref;
    return ym2413->chip->isMuted();
}

static Int32* ym2413Sync(void* ref, Int32 *buffer, UInt32 count) 
{
    YM_2413* ym2413 = (YM_2413*)ref;

    if (count == 0) return NULL;

	std::array<int32_t*, 2> bufs;

    bufs[0] = buffer;
    bufs[1] = buffer + 1;

	ym2413->chip->generateChannels(bufs, count);

    if (bufs[0] == nullptr && bufs[1] == nullptr) {
        return nullptr;
    }

    return buffer;
}

static void writeAddr(void *ym, UInt16 port, UInt8 data)
{
    YM_2413* ym2413 = (YM_2413*)ym;
    ym2413->address = data;
}

static void writeData(void *ym, UInt16 port, UInt8 data)
{
    YM_2413* ym2413 = (YM_2413*)ym;
    ym2413->chip->pokeReg(ym2413->address, data);
}

YM_2413* ym2413Create(Mixer* mixer)
{
    YM_2413* ym2413;

    ym2413 = new YM_2413;

    ym2413->mixer = mixer;

    ym2413->handle = mixerRegisterChannel(mixer, 1, MIXER_CHANNEL_MSXMUSIC_VOICE, MIXER_CHANNEL_MSXMUSIC_DRUM, false, ym2413Sync, ym2413);

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

