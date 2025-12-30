/*****************************************************************************
** $Source: /cvsroot/bluemsx/blueMSX/Src/SoundChips/AY8910.c,v $
**
** $Revision: 1.26 $
**
** $Date: 2008/11/23 20:26:12 $
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
#include "AY8910.h"
#include "IoPort.h"
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <math.h>

#define BASE_PHASE_STEP 0x28959becUL  /* = (1 << 28) * 3579545 / 32 / 44100 */

static Int16 voltTable[16];
static Int16 voltEnvTable[32];

static const UInt8 regMask[16] = {
    0xff, 0x0f, 0xff, 0x0f, 0xff, 0x0f, 0x1f, 0x3f,
    0x1f, 0x1f, 0x1f, 0xff, 0xff, 0x0f, 0xff, 0xff
};

static Int32* ay8910Sync(void* ref, Int32 *buffer, UInt32 count);
static void updateRegister(AY8910* ay8910, UInt8 address, UInt8 data);

struct AY8910 {
    Mixer* mixer;
    Int32  handle;
    Int32  debugHandle;

    AY8910ReadCb    ioPortReadCb;
    AY8910ReadCb    ioPortPollCb;
    AY8910WriteCb   ioPortWriteCb;
    void*           ioPortArg;
    Ay8910Connector connector;

    UInt8  address;
    UInt8  regs[16];

    UInt32 tonePhase[3];
    UInt32 toneStep[3];

    UInt32 noisePhase;
    UInt32 noiseStep;
    UInt32 noiseRand;
    Int16  noiseVolume;

    UInt8  envShape;
    UInt32 envStep;
    UInt32 envPhase;

    UInt8  enable;
    UInt8  ampVolume[3];
    Int32  ctrlVolume;
    Int32  oldSampleVolume;
    Int32  daVolume;
};

AY8910* ay8910Create(Mixer* mixer, Ay8910Connector connector, PsgType type)
{
    AY8910* ay8910 = (AY8910*)calloc(1, sizeof(AY8910));
    int i;

    double v = 0x26a9;
    for (i = 15; i >= 0; i--) {
        voltTable[i] = (Int16)v;
        voltEnvTable[2 * i + 0] = (Int16)v;
        voltEnvTable[2 * i + 1] = (Int16)v;
        v *= 0.70794578438413791080221494218943;
    }

    if ( type == PSGTYPE_YM2149) {
        double v = 0x26a9;
        for (i = 31; i >= 0; i--) {
            voltEnvTable[i] = (Int16)v;
            v *= 0.84139514164519509115274189380029;
        }
    }

    for (i = 0; i < 16; i++) {
        voltTable[i] -= voltTable[0];
    }
    for (i = 0; i < 32; i++) {
        voltEnvTable[i] -= voltEnvTable[0];
    }

    ay8910->mixer = mixer;
    ay8910->connector = connector;
    ay8910->noiseRand = 1;
    ay8910->noiseVolume = 1;

    ay8910->handle = mixerRegisterChannel(mixer, 0, MIXER_CHANNEL_PSG, 0, false, ay8910Sync, ay8910);

    ay8910Reset(ay8910);
    for (i = 0; i < 16; i++) {
        ay8910WriteAddress(ay8910, 0xa0, i);
        ay8910WriteData(ay8910, 0xa1, 0);
    }

    switch (ay8910->connector) {
    case AY8910_MSX:
        ioPortRegister(0xa0, NULL,           (IoPortWrite)ay8910WriteAddress, ay8910);
        ioPortRegister(0xa1, NULL,           (IoPortWrite)ay8910WriteData,    ay8910);
        break;

    case AY8910_SVI:
        ioPortRegister(0x88, NULL,           (IoPortWrite)ay8910WriteAddress, ay8910);
        ioPortRegister(0x8c, NULL,           (IoPortWrite)ay8910WriteData,    ay8910);
        break;
    }

    return ay8910;
}

void ay8910Reset(AY8910* ay8910)
{
    if (ay8910 != NULL) {
        int i;

        for (i = 0; i < 16; i++) {
            ay8910WriteAddress(ay8910, 0xa0, i);
            ay8910WriteData(ay8910, 0xa1, 0);
        }
    }
}

void ay8910Destroy(AY8910* ay8910)
{
    switch (ay8910->connector) {
    case AY8910_MSX:
        ioPortUnregister(0xa0);
        ioPortUnregister(0xa1);
        break;

    case AY8910_SVI:
        ioPortUnregister(0x88);
        ioPortUnregister(0x8c);
        break;
    }

    mixerUnregisterChannel(ay8910->mixer, ay8910->handle);
    free(ay8910);
}

void ay8910SetIoPort(AY8910* ay8910, AY8910ReadCb readCb, AY8910ReadCb pollCb, AY8910WriteCb writeCb, void* arg)
{
    ay8910->ioPortReadCb  = readCb;
    ay8910->ioPortPollCb  = pollCb;
    ay8910->ioPortWriteCb = writeCb;
    ay8910->ioPortArg     = arg;
}

void ay8910WriteAddress(AY8910* ay8910, UInt16 ioPort, UInt8 address)
{
    ay8910->address = address & 0xf;
}

UInt8 ay8910PeekData(AY8910* ay8910, UInt16 ioPort)
{
    UInt8  address = ay8910->address;
    UInt8  value = ay8910->regs[address];

    if (address >= 14) {
        int port = address - 14;
        if (ay8910->ioPortPollCb != NULL){// && !(ay8910->regs[7] & (1 << (port + 6)))) {
            value = ay8910->ioPortPollCb(ay8910->ioPortArg, port);
        }
    }
    return value;
}

static void updateRegister(AY8910* ay8910, UInt8 regIndex, UInt8 data)
{
    UInt32 period;
    int port;

    if (regIndex < 14) {
        mixerSync(ay8910->mixer);
    }

    data &= regMask[regIndex];

    ay8910->regs[regIndex] = data;

    switch (regIndex) {
    case 0:
    case 1:
    case 2:
    case 3:
    case 4:
    case 5:
        period = ay8910->regs[regIndex & 6] | ((Int32)(ay8910->regs[regIndex | 1]) << 8);
//        period *= (~ay8910->enable >> (address >> 1)) & 1;
        ay8910->toneStep[regIndex >> 1] = period > 0 ? BASE_PHASE_STEP / period : 1 << 31;
        break;

    case 6:
        period = data ? data : 1;
        ay8910->noiseStep = period > 0 ? BASE_PHASE_STEP / period : 1 << 31;
        break;

    case 7:
        ay8910->enable = data;
        break;

    case 8:
    case 9:
    case 10:
        ay8910->ampVolume[regIndex - 8] = data;
        break;

    case 11:
    case 12:
        period = 16 * (ay8910->regs[11] | ((UInt32)ay8910->regs[12] << 8));
        ay8910->envStep = BASE_PHASE_STEP / (period ? period : 8);
        break;

    case 13:
        if (data < 4) data = 0x09;
        if (data < 8) data = 0x0f;
        ay8910->envShape = data;
        ay8910->envPhase = 0;
        break;

    case 14:
    case 15:
        port = regIndex - 14;
        if (ay8910->ioPortWriteCb != NULL){// && (ay8910->regs[7] & (1 << (port + 6)))) {
            ay8910->ioPortWriteCb(ay8910->ioPortArg, port, data);
        }
    }
}

void ay8910WriteData(AY8910* ay8910, UInt16 ioPort, UInt8 data)
{
    updateRegister(ay8910, ay8910->address, data);
}

static Int32* ay8910Sync(void* ref, Int32 *buffer, UInt32 count)
{
    AY8910* ay8910 = (AY8910*)ref;
    Int32   channel;
    UInt32  index;

    for (index = 0; index < count; index++) {
        Int32 sampleVolume = 0;
        Int16 envVolume;

        /* Update noise generator */
        ay8910->noisePhase += ay8910->noiseStep;
        while (ay8910->noisePhase >> 28) {
            ay8910->noisePhase  -= 0x10000000;
            ay8910->noiseVolume ^= ((ay8910->noiseRand + 1) >> 1) & 1;
            ay8910->noiseRand    = (ay8910->noiseRand ^ (0x28000 * (ay8910->noiseRand & 1))) >> 1;
        }

        /* Update envelope phase */
        ay8910->envPhase += ay8910->envStep;
        if ((ay8910->envShape & 1) && (ay8910->envPhase >> 28)) {
            ay8910->envPhase = 0x10000000;
        }

        /* Calculate envelope volume */
        envVolume = (Int16)((ay8910->envPhase >> 23) & 0x1f);
        if ((((ay8910->envPhase >> 27) & (ay8910->envShape + 1)) ^ ((~ay8910->envShape >> 1) & 2))) {
            envVolume ^= 0x1f;
        }

        /* Calculate and add channel samples to buffer */
        for (channel = 0; channel < 3; channel++) {
            UInt32 enable = ay8910->enable >> channel;
            UInt32 noiseEnable = ((enable >> 3) | ay8910->noiseVolume) & 1;
            UInt32 phaseStep = (~enable & 1) * ay8910->toneStep[channel];
            UInt32 tonePhase = ay8910->tonePhase[channel];
            UInt32 tone = 0;
            Int32  count = 16;

            /* Perform 16x oversampling */
            while (count--) {
                /* Update phase of tone */
                tonePhase += phaseStep;

                /* Calculate if tone is on or off */
                tone += (enable | (tonePhase >> 31)) & noiseEnable;
            }

            /* Store phase */
            ay8910->tonePhase[channel] = tonePhase;

            /* Amplify sample using either envelope volume or channel volume */
            if (ay8910->ampVolume[channel] & 0x10) {
                sampleVolume += (Int16)tone * voltEnvTable[envVolume] / 16;
            }
            else {
                sampleVolume += (Int16)tone * voltTable[ay8910->ampVolume[channel]] / 16;
            }
        }

        /* Perform DC offset filtering */
        ay8910->ctrlVolume = sampleVolume - ay8910->oldSampleVolume + 0x3fe7 * ay8910->ctrlVolume / 0x4000;
        ay8910->oldSampleVolume = sampleVolume;

        /* Perform simple 1 pole low pass IIR filtering */
        ay8910->daVolume += 2 * (ay8910->ctrlVolume - ay8910->daVolume) / 3;

        /* Store calclulated sample value */
        buffer[index] = 9 * ay8910->daVolume;
    }

    return buffer;
}
