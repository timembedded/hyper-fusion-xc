/*****************************************************************************
** $Source: /cvsroot/bluemsx/blueMSX/Src/SoundChips/Moonsound.cpp,v $
**
** $Revision: 1.22 $
**
** $Date: 2008/03/30 18:38:45 $
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
#include "Moonsound.h"

#include <string.h>
#include <esp_heap_caps.h>

#include "Board.h"
#include "IoPort.h"
#include "OpenMsxYMF262.h"
#include "OpenMsxYMF278.h"

#define FREQUENCY        3579545
 
struct Moonsound {
    Moonsound() : opl3latch(0), opl4latch(0) {
    }
    ~Moonsound() {
    }

    Mixer* mixer;
    Int32 handle;

    YMF278* ymf278;
    YMF262* ymf262;
    int opl3latch;
    UInt8 opl4latch;
};

extern "C" {

void moonsoundDestroy(Moonsound* moonsound) 
{
    ioPortUnregister(0x7e);
    ioPortUnregister(0x7f);
    ioPortUnregister(0xc4);
    ioPortUnregister(0xc5);
    ioPortUnregister(0xc6);
    ioPortUnregister(0xc7);

    mixerUnregisterChannel(moonsound->mixer, moonsound->handle);

    delete moonsound->ymf262;
    delete moonsound->ymf278;
    delete moonsound;
}

void moonsoundReset(Moonsound* moonsound)
{
    moonsound->ymf262->reset();
    moonsound->ymf278->reset();
}

static Int32* moonsoundSyncYMF262(void* ref, Int32 *buffer, UInt32 count) 
{
    Moonsound* moonsound = (Moonsound*)ref;
    return (Int32*)moonsound->ymf262->updateBuffer((int*)buffer, count);
}

static Int32* moonsoundSyncYMF278(void* ref, Int32 *buffer, UInt32 count) 
{
    Moonsound* moonsound = (Moonsound*)ref;
    return (Int32*)moonsound->ymf278->updateBuffer((int*)buffer, count);
}

UInt8 moonsoundReadYMF278(Moonsound* moonsound, UInt16 ioPort)
{
    mixerSync(moonsound->mixer);
    return moonsound->ymf278->readRegOPL4(moonsound->opl4latch);
}

UInt8 moonsoundReadYMF262(Moonsound* moonsound, UInt16 ioPort)
{
    mixerSync(moonsound->mixer);
    return moonsound->ymf262->readReg(moonsound->opl3latch);
}

void moonsoundWriteYMF278(Moonsound* moonsound, UInt16 ioPort, UInt8 value)
{
    switch (ioPort & 0x01) {
    case 0: // select register
        moonsound->opl4latch = value;
        break;
    case 1:
        mixerSync(moonsound->mixer);
        moonsound->ymf278->writeRegOPL4(moonsound->opl4latch, value);
        break;
    }
}

void moonsoundWriteYMF262(Moonsound* moonsound, UInt16 ioPort, UInt8 value)
{
	switch (ioPort & 0x03) {
    case 0:
        moonsound->opl3latch = value;
        break;
    case 2: // select register bank 1
        moonsound->opl3latch = value | 0x100;
        break;
    case 1:
    case 3: // write fm register
        mixerSync(moonsound->mixer);
        moonsound->ymf262->writeReg(moonsound->opl3latch, value);
        break;
    }
}

Moonsound* moonsoundCreate(Mixer* mixer, void* romData, int romSize, int sramSize)
{
    Moonsound* moonsound = new Moonsound;

    moonsound->mixer = mixer;

    moonsound->handle = mixerRegisterChannel(mixer, 0, MIXER_CHANNEL_YMF262, 0, true, moonsoundSyncYMF262, moonsound);
    moonsound->handle = mixerRegisterChannel(mixer, 1, MIXER_CHANNEL_YMF278, 0, true, moonsoundSyncYMF278, moonsound);

    moonsound->ymf262 = new YMF262();
    moonsound->ymf262->setSampleRate(AUDIO_SAMPLERATE, 1);
	moonsound->ymf262->setVolume(32767 * 9 / 10);

    moonsound->ymf278 = new YMF278(sramSize, romData, romSize);
    moonsound->ymf278->setVolume(32767 * 9 / 10);

    ioPortRegister(0x7e, NULL                           , (IoPortWrite)moonsoundWriteYMF278, moonsound);
    ioPortRegister(0x7f, (IoPortRead)moonsoundReadYMF278, (IoPortWrite)moonsoundWriteYMF278, moonsound);
    ioPortRegister(0xc4, NULL,                            (IoPortWrite)moonsoundWriteYMF262, moonsound);
    ioPortRegister(0xc5, (IoPortRead)moonsoundReadYMF262, (IoPortWrite)moonsoundWriteYMF262, moonsound);
    ioPortRegister(0xc6, NULL,                            (IoPortWrite)moonsoundWriteYMF262, moonsound);
    ioPortRegister(0xc7, (IoPortRead)moonsoundReadYMF262, (IoPortWrite)moonsoundWriteYMF262, moonsound);

    return moonsound;
}

}



