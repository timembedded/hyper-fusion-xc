/*****************************************************************************
** $Source: /cvsroot/bluemsx/blueMSX/Src/SoundChips/Y8950.c,v $
**
** $Revision: 1.21 $
**
** $Date: 2008/03/31 19:42:23 $
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
#include "Y8950.h"
#include "Fmopl.h"
#include "Board.h"
#include "IoPort.h"
#include "MidiIO.h"
#include <stdlib.h>
#include <string.h>

#define FREQUENCY        3579545
#define SAMPLERATE       (FREQUENCY / 72)
#define TIMER_FREQUENCY  (4 * boardFrequency() / SAMPLERATE)


struct Y8950 {
    Mixer* mixer;
    Int32  handle;

    FM_OPL* opl;
    MidiIO* ykIo; 
#if 0
    BoardTimer* timer1;
    BoardTimer* timer2;
#endif
    UInt32 timerValue1;
    UInt32 timerValue2;
    UInt32 timeout1;
    UInt32 timeout2;
    UInt32 timerRunning1;
    UInt32 timerRunning2;
    UInt8  address;
    // Variables used for resampling
    Int32  off;
    Int32  s1;
    Int32  s2;
    Int32  buffer[AUDIO_MONO_BUFFER_SIZE];
};

extern INT32 outd;
extern INT32 ams;
extern INT32 vib;
extern INT32 feedback2;

#if 0
void y8950TimerStart(void* ptr, int timer, int start);

static void onTimeout1(void* ptr, UInt32 time)
{
    Y8950* y8950 = (Y8950*)ptr;

    y8950->timerRunning1 = 0;
    if (OPLTimerOver(y8950->opl, 0)) {
        y8950TimerStart(y8950, 0, 1);
    }
}

static void onTimeout2(void* ptr, UInt32 time)
{
    Y8950* y8950 = (Y8950*)ptr;

    y8950->timerRunning2 = 0;
    if (OPLTimerOver(y8950->opl, 1)) {
        y8950TimerStart(y8950, 1, 1);
    }
}

void y8950TimerStart(void* ptr, int timer, int start)
{
    Y8950* y8950 = (Y8950*)ptr;

    if (timer == 0) {
        if (start != 0) {
            if (!y8950->timerRunning1) {
                UInt32 systemTime = boardSystemTime();
                UInt32 adjust = systemTime % TIMER_FREQUENCY;
                y8950->timeout1 = systemTime + TIMER_FREQUENCY * y8950->timerValue1 - adjust;
                boardTimerAdd(y8950->timer1, y8950->timeout1);
                y8950->timerRunning1 = 1;
            }
        }
        else {
            if (y8950->timerRunning1) {
                boardTimerRemove(y8950->timer1);
                y8950->timerRunning1 = 0;
            }
        }
    }
    else {
        if (start != 0) {
            if (!y8950->timerRunning2) {
                UInt32 systemTime = boardSystemTime();
                UInt32 adjust = systemTime % (4 * TIMER_FREQUENCY);
                y8950->timeout2 = systemTime + TIMER_FREQUENCY * y8950->timerValue2 - adjust;
                boardTimerAdd(y8950->timer2, y8950->timeout2);
                y8950->timerRunning2 = 1;
            }
        }
        else {
            if (y8950->timerRunning2) {
                boardTimerRemove(y8950->timer2);
                y8950->timerRunning2 = 0;
            }
        }
    }
}
#endif

#define Y8950_KEY_START 36

int y8950GetNoteOn(void* ref, int kbdLatch)
{
    Y8950* y8950 = (Y8950*)ref;
    UInt8 val = 0xff;
    int row;

    for (row = 0; row < 8; row++) {
        if ((1 << row) & kbdLatch) {
            val &= ykIoGetKeyState(y8950->ykIo, Y8950_KEY_START + row * 8 + 0) ? ~0x01 : 0xff;
            val &= ykIoGetKeyState(y8950->ykIo, Y8950_KEY_START + row * 8 + 1) ? ~0x02 : 0xff;
            val &= ykIoGetKeyState(y8950->ykIo, Y8950_KEY_START + row * 8 + 2) ? ~0x04 : 0xff;
            val &= ykIoGetKeyState(y8950->ykIo, Y8950_KEY_START + row * 8 + 3) ? ~0x08 : 0xff;
            val &= ykIoGetKeyState(y8950->ykIo, Y8950_KEY_START + row * 8 + 4) ? ~0x10 : 0xff;
            val &= ykIoGetKeyState(y8950->ykIo, Y8950_KEY_START + row * 8 + 5) ? ~0x20 : 0xff;
            val &= ykIoGetKeyState(y8950->ykIo, Y8950_KEY_START + row * 8 + 6) ? ~0x40 : 0xff;
            val &= ykIoGetKeyState(y8950->ykIo, Y8950_KEY_START + row * 8 + 7) ? ~0x80 : 0xff;
        }
    }

    return val;
}

UInt8 y8950Peek(Y8950* y8950, UInt16 ioPort)
{
    if (y8950 != NULL) {
        switch (ioPort & 1) {
        case 0:
            return (UInt8)OPLPeek(y8950->opl, 0);
        case 1:
            return (UInt8)OPLPeek(y8950->opl, 1);
            break;
        }
    }
    return  0xff;
}

UInt8 y8950Read(Y8950* y8950, UInt16 ioPort)
{
    switch (ioPort & 1) {
    case 0:
        return (UInt8)OPLRead(y8950->opl, 0);
    case 1:
        if (y8950->opl->address == 0x14) {
            mixerSync(y8950->mixer);
        }
        return (UInt8)OPLRead(y8950->opl, 1);
        break;
    }
    return  0xff;
}

void y8950Write(Y8950* y8950, UInt16 ioPort, UInt8 value)
{
    switch (ioPort & 1) {
    case 0:
        OPLWrite(y8950->opl, 0, value);
        break;
    case 1:
        mixerSync(y8950->mixer);
        OPLWrite(y8950->opl, 1, value);
        break;
    }
}

static Int32* y8950Sync(void* ref, UInt32 count) 
{
    Y8950* y8950 = (Y8950*)ref;
    UInt32 i;

    for (i = 0; i < count; i++) {
        y8950->buffer[i] = Y8950UpdateOne(y8950->opl);
    }

    return y8950->buffer;
}

void y8950Destroy(Y8950* y8950) 
{
    mixerUnregisterChannel(y8950->mixer, y8950->handle);
#if 0
    boardTimerDestroy(y8950->timer1);
    boardTimerDestroy(y8950->timer2);
#endif
    OPLDestroy(y8950->opl);

    if (y8950->ykIo != NULL) {
        ykIoDestroy(y8950->ykIo);
    }

    free(y8950);
}

void y8950Reset(Y8950* y8950)
{
#if 0
    y8950TimerStart(y8950, 0, 0);
    y8950TimerStart(y8950, 1, 0);
#endif
    OPLResetChip(y8950->opl);
    y8950->off = 0;
    y8950->s1 = 0;
    y8950->s2 = 0;
}

Y8950* y8950Create(Mixer* mixer)
{
    Y8950* y8950;
    
    y8950 = (Y8950*)calloc(1, sizeof(Y8950));

    y8950->mixer = mixer;
    y8950->timerRunning1 = 0;
    y8950->timerRunning2 = 0;

#if 0
    y8950->timer1 = boardTimerCreate(onTimeout1, y8950);
    y8950->timer2 = boardTimerCreate(onTimeout2, y8950);
#endif

    y8950->ykIo = ykIoCreate();

    y8950->handle = mixerRegisterChannel(mixer, MIXER_CHANNEL_MSXAUDIO, 0, y8950Sync, y8950);

    y8950->opl = OPLCreate(OPL_TYPE_Y8950, FREQUENCY, SAMPLERATE, 256, y8950);
    OPLSetOversampling(y8950->opl, boardGetY8950Oversampling);
    OPLResetChip(y8950->opl);

    return y8950;
}

void y8950TimerSet(void* ref, int timer, int count)
{
    Y8950* y8950 = (Y8950*)ref;

    if (timer == 0) {
        y8950->timerValue1 = count;
    }
    else {
        y8950->timerValue2 = count;
    }
}
