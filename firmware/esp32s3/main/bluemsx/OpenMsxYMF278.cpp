// This file is taken from the openMSX project.
// The file has been modified to be built in the blueMSX environment.

// $Id: OpenMsxYMF278.cpp,v 1.6 2008/03/31 22:07:05 hap-hap Exp $

#include "OpenMsxYMF278.h"
#include <cmath>
#include <cstring>
#include <stdlib.h>
#include <esp_heap_caps.h>

#include "Board.h"

// envelope output entries
#define ENV_BITS      10
#define ENV_LEN       (1 << ENV_BITS)
#define ENV_STEP      (128.0 / ENV_LEN)
#define MAX_ATT_INDEX ((1 << (ENV_BITS - 1)) - 1) //511
#define MIN_ATT_INDEX 0

// Envelope Generator phases
#define EG_ATT  4
#define EG_DEC  3
#define EG_SUS  2
#define EG_REL  1
#define EG_OFF  0

#define EG_REV  5   //pseudo reverb
#define EG_DMP  6   //damp

// Pan values, units are -3dB, i.e. 8.
const static DRAM_ATTR int pan_left[16]  = {
    0, 8, 16, 24, 32, 40, 48, 256, 256,   0,  0,  0,  0,  0,  0, 0
};
const static DRAM_ATTR int pan_right[16] = {
    0, 0,  0,  0,  0,  0,  0,   0, 256, 256, 48, 40, 32, 24, 16, 8
};

// Mixing levels, units are -3dB, and add some marging to avoid clipping
const static DRAM_ATTR int mix_level[8] = {
    8, 16, 24, 32, 40, 48, 56, 256
};

// decay level table (3dB per step)
// 0 - 15: 0, 3, 6, 9,12,15,18,21,24,27,30,33,36,39,42,93 (dB)
#define SC(db) (unsigned int)(db * (2.0 / ENV_STEP))
const static DRAM_ATTR unsigned int dl_tab[16] = {
 SC( 0), SC( 1), SC( 2), SC(3 ), SC(4 ), SC(5 ), SC(6 ), SC( 7),
 SC( 8), SC( 9), SC(10), SC(11), SC(12), SC(13), SC(14), SC(31)
};
#undef SC

#define RATE_STEPS 8
const static DRAM_ATTR uint8_t eg_inc[15 * RATE_STEPS] = {
//cycle:0 1  2 3  4 5  6 7
    0, 1,  0, 1,  0, 1,  0, 1, //  0  rates 00..12 0 (increment by 0 or 1)
    0, 1,  0, 1,  1, 1,  0, 1, //  1  rates 00..12 1
    0, 1,  1, 1,  0, 1,  1, 1, //  2  rates 00..12 2
    0, 1,  1, 1,  1, 1,  1, 1, //  3  rates 00..12 3

    1, 1,  1, 1,  1, 1,  1, 1, //  4  rate 13 0 (increment by 1)
    1, 1,  1, 2,  1, 1,  1, 2, //  5  rate 13 1
    1, 2,  1, 2,  1, 2,  1, 2, //  6  rate 13 2
    1, 2,  2, 2,  1, 2,  2, 2, //  7  rate 13 3

    2, 2,  2, 2,  2, 2,  2, 2, //  8  rate 14 0 (increment by 2)
    2, 2,  2, 4,  2, 2,  2, 4, //  9  rate 14 1
    2, 4,  2, 4,  2, 4,  2, 4, // 10  rate 14 2
    2, 4,  4, 4,  2, 4,  4, 4, // 11  rate 14 3

    4, 4,  4, 4,  4, 4,  4, 4, // 12  rates 15 0, 15 1, 15 2, 15 3 for decay
    8, 8,  8, 8,  8, 8,  8, 8, // 13  rates 15 0, 15 1, 15 2, 15 3 for attack (zero time)
    0, 0,  0, 0,  0, 0,  0, 0, // 14  infinity rates for attack and decay(s)
};

#define O(a) (a * RATE_STEPS)
const static DRAM_ATTR uint8_t eg_rate_select[64] = {
    O( 0),O( 1),O( 2),O( 3),
    O( 0),O( 1),O( 2),O( 3),
    O( 0),O( 1),O( 2),O( 3),
    O( 0),O( 1),O( 2),O( 3),
    O( 0),O( 1),O( 2),O( 3),
    O( 0),O( 1),O( 2),O( 3),
    O( 0),O( 1),O( 2),O( 3),
    O( 0),O( 1),O( 2),O( 3),
    O( 0),O( 1),O( 2),O( 3),
    O( 0),O( 1),O( 2),O( 3),
    O( 0),O( 1),O( 2),O( 3),
    O( 0),O( 1),O( 2),O( 3),
    O( 0),O( 1),O( 2),O( 3),
    O( 4),O( 5),O( 6),O( 7),
    O( 8),O( 9),O(10),O(11),
    O(12),O(12),O(12),O(12),
};
#undef O

//rate  0,    1,    2,    3,   4,   5,   6,  7,  8,  9,  10, 11, 12, 13, 14, 15
//shift 12,   11,   10,   9,   8,   7,   6,  5,  4,  3,  2,  1,  0,  0,  0,  0
//mask  4095, 2047, 1023, 511, 255, 127, 63, 31, 15, 7,  3,  1,  0,  0,  0,  0
#define O(a) (a)
const static DRAM_ATTR uint8_t eg_rate_shift[64] = {
    O(12),O(12),O(12),O(12),
    O(11),O(11),O(11),O(11),
    O(10),O(10),O(10),O(10),
    O( 9),O( 9),O( 9),O( 9),
    O( 8),O( 8),O( 8),O( 8),
    O( 7),O( 7),O( 7),O( 7),
    O( 6),O( 6),O( 6),O( 6),
    O( 5),O( 5),O( 5),O( 5),
    O( 4),O( 4),O( 4),O( 4),
    O( 3),O( 3),O( 3),O( 3),
    O( 2),O( 2),O( 2),O( 2),
    O( 1),O( 1),O( 1),O( 1),
    O( 0),O( 0),O( 0),O( 0),
    O( 0),O( 0),O( 0),O( 0),
    O( 0),O( 0),O( 0),O( 0),
    O( 0),O( 0),O( 0),O( 0),
};
#undef O


//number of steps to take in quarter of lfo frequency
//TODO check if frequency matches real chip
#define O(a) ((int)((65536 / a) / 6))
const static DRAM_ATTR int lfo_period[8] = {
    O(0.168), O(2.019), O(3.196), O(4.206),
    O(5.215), O(5.888), O(6.224), O(7.066)
};
#undef O


#define O(a) ((int)(a * 65536))
const static DRAM_ATTR int vib_depth[8] = {
    O(0),      O(3.378),  O(5.065),  O(6.750),
    O(10.114), O(20.170), O(40.106), O(79.307)
};
#undef O

#define SC(db) (unsigned int) (db * (2.0 / ENV_STEP))
const static DRAM_ATTR int am_depth[8] = {
    SC(0),     SC(1.781), SC(2.906), SC(3.656),
    SC(4.406), SC(5.906), SC(7.406), SC(11.91)
};
#undef SC

const static DRAM_ATTR uint8_t dmp_rate = 56;
const static DRAM_ATTR uint8_t dmp_shift = eg_rate_shift[dmp_rate];
const static DRAM_ATTR uint16_t dmp_mask = (1 << dmp_shift) - 1;
const static DRAM_ATTR uint8_t dmp_select = eg_rate_select[dmp_rate];

static DRAM_ATTR uint8_t* lfo_lookup;

YMF278Slot::YMF278Slot()
{
    reset();
}

void YMF278Slot::reset()
{
    wave = FN = OCT = PRVB = LD = TL = pan = lfo = vib = AM = 0;
    AR = D1R = DL = D2R = RC = RR = 0;
    step = stepptr = 0;
    bits = loopaddr = endaddr = 0;
    env_vol = MAX_ATT_INDEX;
    //env_vol_step = env_vol_lim = 0;

    lfo_active = false;
    lfo_cnt = lfo_step = lfo_idx = 0;
    lfo_max = lfo_period[0];

    lfo_lookup = (uint8_t*)malloc(1024);
    for(int i = 0; i < 1024; i++) {
        if (i < 256) {
            lfo_lookup[i] = i;
        } else if (i < 768) {
            lfo_lookup[i] = 255 - (i - 256);
        } else {
            lfo_lookup[i] = i - 768;
        }
    }

    update_AR();
    update_D1R();
    update_D2R();
    update_RR();
    update_C5();

    state = EG_OFF;
    active = false;
}

void IRAM_ATTR YMF278Slot::update_AR()
{
    AR_rate = compute_rate(AR);
    if (AR_rate >= 4) {
        AR_shift = eg_rate_shift[AR_rate];
        AR_mask = (1 << AR_shift) - 1;
        AR_select = eg_rate_select[AR_rate];
    }
}

void IRAM_ATTR YMF278Slot::update_D1R()
{
    D1R_rate = compute_rate(D1R);
    if (D1R_rate >= 4) {
        D1R_shift = eg_rate_shift[D1R_rate];
        D1R_mask = (1 << D1R_shift) - 1;
        D1R_select = eg_rate_select[D1R_rate];
    }
}

void IRAM_ATTR YMF278Slot::update_D2R()
{
    D2R_rate = compute_rate(D2R);
    if (D2R_rate >= 4) {
        D2R_shift = eg_rate_shift[D2R_rate];
        D2R_mask = (1 << D2R_shift) - 1;
        D2R_select = eg_rate_select[D2R_rate];
    }
}

void IRAM_ATTR YMF278Slot::update_RR()
{
    RR_rate = compute_rate(RR);
    if (RR_rate >= 4) {
        RR_shift = eg_rate_shift[RR_rate];
        RR_mask = (1 << RR_shift) - 1;
        RR_select = eg_rate_select[RR_rate];
    }
}

void IRAM_ATTR YMF278Slot::update_C5()
{
    C5_rate = compute_rate(5);
}

int IRAM_ATTR YMF278Slot::compute_rate(int val)
{
    if (val == 0) {
        return 0;
    } else if (val == 15) {
        return 63;
    }
    int res;
    if (RC != 15) {
        int oct = OCT;
        if (oct & 8) {
            oct |= -8;
        }
        res = (oct + RC) * 2 + (FN & 0x200 ? 1 : 0) + val * 4;
    } else {
        res = val * 4;
    }
    if (res < 0) {
        res = 0;
    } else if (res > 63) {
        res = 63;
    }
    return res;
}

int IRAM_ATTR YMF278Slot::compute_vib()
{
    return (lfo_step * vib_depth[(int)vib]) >> 24;
}

int IRAM_ATTR YMF278Slot::compute_am()
{
    if (lfo_active && AM) {
        return (lfo_step * am_depth[(int)AM]) >> 12;
    } else {
        return 0;
    }
}

void IRAM_ATTR YMF278Slot::set_lfo(int newlfo)
{
    lfo_cnt  = (((lfo_cnt  << 8) / lfo_max) * newlfo) >> 8;

    lfo = newlfo;
    lfo_max = lfo_period[(int)lfo];
}

void IRAM_ATTR YMF278::advance()
{
    eg_cnt++;

    for (int i = 0; i < 24; i++) {
        YMF278Slot &op = slots[i];

        if (op.lfo_active) {
            op.lfo_cnt += 256;
            if (op.lfo_cnt > op.lfo_max) {
                op.lfo_cnt -= op.lfo_max;
                op.lfo_idx = (op.lfo_idx + 1) & 1023;
                op.lfo_step = lfo_lookup[op.lfo_idx];
            }
        }

        // Notes:
        // op.env_vol is in the range 0 .. MAX_ATT_INDEX (511)
        // higher values mean more attenuation (lower volume)

        // Envelope Generator
        switch(op.state) {
        case EG_ATT: {  // attack phase
            if (op.AR_rate < 4 || (eg_cnt & op.AR_mask)) {
                break;
            }
            op.env_vol += (~op.env_vol * eg_inc[op.AR_select + ((eg_cnt >> op.AR_shift) & 7)]) >> 3;
            if (op.env_vol <= MIN_ATT_INDEX) {
                op.env_vol = MIN_ATT_INDEX;
                if (op.DL == 0) {
                    op.state = EG_SUS;
                }
                else {
                    op.state = EG_DEC;
                }
            }
            break;
        }
        case EG_DEC: {  // decay phase
            if (op.D1R_rate < 4 || (eg_cnt & op.D1R_mask)) {
                break;
            }
            op.env_vol += eg_inc[op.D1R_select + ((eg_cnt >> op.D1R_shift) & 7)];

            if (((unsigned int)op.env_vol > dl_tab[6]) && op.PRVB) {
                op.state = EG_REV;
            } else {
                if (op.env_vol >= op.DL) {
                    op.state = EG_SUS;
                }
            }
            break;
        }
        case EG_SUS: {  // sustain phase
            if (op.D2R_rate < 4 || (eg_cnt & op.D2R_mask)) {
                break;
            }
            op.env_vol += eg_inc[op.D2R_select + ((eg_cnt >> op.D2R_shift) & 7)];
            if (((unsigned int)op.env_vol > dl_tab[6]) && op.PRVB) {
                op.state = EG_REV;
            } else {
                if (op.env_vol >= MAX_ATT_INDEX) {
                    op.env_vol = MAX_ATT_INDEX;
                    op.active = false;
                    checkMute();
                }
            }
            break;
        }
        case EG_REL: {  // release phase
            if (op.RR_rate < 4 || (eg_cnt & op.RR_mask)) {
                break;
            }
            op.env_vol += eg_inc[op.RR_select + ((eg_cnt >> op.RR_shift) & 7)];
            if (((unsigned int)op.env_vol > dl_tab[6]) && op.PRVB) {
                op.state = EG_REV;
            } else {
                if (op.env_vol >= MAX_ATT_INDEX) {
                    op.env_vol = MAX_ATT_INDEX;
                    op.active = false;
                    checkMute();
                }
            }
            break;
        }
        case EG_REV: {  //pseudo reverb
            //TODO improve env_vol update
            //if (op.C5_rate < 4) {
            //  break;
            //}
            if (eg_cnt & op.C5_mask) {
                break;
            }
            op.env_vol += eg_inc[op.C5_select + ((eg_cnt >> op.C5_shift) & 7)];
            if (op.env_vol >= MAX_ATT_INDEX) {
                op.env_vol = MAX_ATT_INDEX;
                op.active = false;
                checkMute();
            }
            break;
        }
        case EG_DMP: {  //damping
            //TODO improve env_vol update, damp is just fastest decay now
            if (eg_cnt & dmp_mask) {
                break;
            }
            op.env_vol += eg_inc[dmp_select + ((eg_cnt >> dmp_shift) & 7)];

            if (op.env_vol >= MAX_ATT_INDEX) {
                op.env_vol = MAX_ATT_INDEX;
                op.active = false;
                checkMute();
            }
            break;
        }
        case EG_OFF:
            // nothing
            break;

        default:
            break;
        }
    }
}

int16_t IRAM_ATTR YMF278::getSample(YMF278Slot &op)
{
    int16_t sample;
    switch (op.bits) {
    case 0: // 8 bit
        sample = op.sampleptr[op.pos] << 8;
        break;

    case 1: // 12 bit
    case 2: // 16 bit
        sample = op.sampleptr16[op.pos];
        break;

    default:
        // TODO unspecified
        sample = 0;
    }
    return sample;
}

void IRAM_ATTR YMF278::checkMute()
{
    setInternalMute(!anyActive());
}

bool YMF278::anyActive()
{
    for (int i = 0; i < 24; i++) {
        if (slots[i].active) {
            return true;
        }
    }
    return false;
}

int* IRAM_ATTR YMF278::updateBuffer(int *buffer, int length)
{
    if (isInternalMuted()) {
        return NULL;
    }

    int vl = mix_level[pcm_l];
    int vr = mix_level[pcm_r];
    int *buf = buffer;
    while (length--) {
        int left = 0;
        int right = 0;
        for (int i = 0; i < 24; i++) {
            YMF278Slot &sl = slots[i];
            if (!sl.active) {
                continue;
            }

            int16_t sample = sl.sample;
            int vol = sl.TL + (sl.env_vol >> 2) + sl.compute_am();

            int volLeft  = vol + pan_left [(int)sl.pan] + vl;
            int volRight = vol + pan_right[(int)sl.pan] + vr;

            // TODO prob doesn't happen in real chip
            if (volLeft < 0) {
                volLeft = 0;
            }
            if (volRight < 0) {
                volRight = 0;
            }

            left  += (sample * volume[volLeft] ) >> 10;
            right += (sample * volume[volRight]) >> 10;

            if (sl.lfo_active && sl.vib) {
                int oct = sl.OCT;
                if (oct & 8) {
                    oct |= -8;
                }
                oct += 5;
                int v = sl.compute_vib();
                sl.stepptr += (oct >= 0 ? ((sl.FN | 1024) + v) << oct
                                : ((sl.FN | 1024) + v) >> -oct);
            } else {
                sl.stepptr += sl.step;
            }

            int count = (sl.stepptr >> 16) & 0x0f;
            sl.stepptr &= 0xffff;
            sl.pos += count;
            if (sl.pos >= sl.endaddr) {
                sl.pos = sl.loopaddr + (sl.pos - sl.endaddr);
            }
            sl.sample = getSample(sl);
        }
        advance();
        *buf++ += left;
        *buf++ += right;
    }
    return buffer;
}

void IRAM_ATTR YMF278::keyOnHelper(YMF278Slot& slot)
{
    slot.active = true;
    setInternalMute(false);

    int oct = slot.OCT;
    if (oct & 8) {
        oct |= -8;
    }
    oct += 5;
    slot.step = oct >= 0 ? (slot.FN | 1024) << oct : (slot.FN | 1024) >> -oct;
    slot.state = EG_ATT;
    slot.stepptr = 0;
    slot.pos = 0;
    slot.sample = getSample(slot);
    slot.pos = 1;
}

void IRAM_ATTR YMF278::writeRegOPL4(uint8_t reg, uint8_t data)
{
    // Handle slot registers specifically
    if (reg >= 0x08 && reg <= 0xF7) {
        int snum = (reg - 8) % 24;
        YMF278Slot& slot = slots[snum];
        switch ((reg - 8) / 24) {
        case 0: {
            slot.wave = (slot.wave & 0x100) | data;
            int base = (slot.wave < 384 || !wavetblhdr) ?
                       (slot.wave * 12) :
                       (wavetblhdr * 0x80000 + ((slot.wave - 384) * 12));
            uint8_t buf[12];
            for (int i = 0; i < 12; i++) {
                buf[i] = readMem(base + i);
            }
            slot.bits = (buf[0] & 0xC0) >> 6;
            slot.set_lfo((buf[7] >> 3) & 7);
            slot.vib  = buf[7] & 7;
            slot.AR   = buf[8] >> 4;
            slot.D1R  = buf[8] & 0xF;
            slot.DL   = dl_tab[buf[9] >> 4];
            slot.D2R  = buf[9] & 0xF;
            slot.RC   = buf[10] >> 4;
            slot.RR   = buf[10] & 0xF;
            slot.AM   = buf[11] & 7;
            uint32_t startaddr = buf[2] | (buf[1] << 8) |
                                 ((buf[0] & 0x3F) << 16);
            while (startaddr >= endRam) {
                startaddr -= (endRam - endRom); // Wrap-around RAM, TODO check
            }
            if (slot.bits == 1) {
                if (startaddr < endRom) {
                    slot.sampleptr = rom12bit + (startaddr * 4) / 3;
                }else{
                    slot.sampleptr = ram12bit + ((startaddr - endRom) * 4) / 3;
                }
            }else{
                if (startaddr < endRom) {
                    slot.sampleptr = rom + startaddr;
                } else {
                    slot.sampleptr = ram + (startaddr - endRom);
                }
            }
            slot.loopaddr = buf[4] + (buf[3] << 8);
            slot.endaddr  = (((buf[6] + (buf[5] << 8)) ^ 0xFFFF) + 1);

            slot.update_AR();
            slot.update_D1R();
            slot.update_D2R();
            slot.update_RR();
            slot.update_C5();

            if ((regs[reg + 4] & 0x080)) {
                keyOnHelper(slot);
            }
            break;
        }
        case 1: {
            slot.wave = (slot.wave & 0xFF) | ((data & 0x1) << 8);
            slot.FN = (slot.FN & 0x380) | (data >> 1);
            int oct = slot.OCT;
            if (oct & 8) {
                oct |= -8;
            }
            oct += 5;
            slot.step = oct >= 0 ? (slot.FN | 1024) << oct : (slot.FN | 1024) >> -oct;
            break;
        }
        case 2: {
            slot.FN = (slot.FN & 0x07F) | ((data & 0x07) << 7);
            slot.PRVB = ((data & 0x08) >> 3);
            slot.OCT =  ((data & 0xF0) >> 4);
            int oct = slot.OCT;
            if (oct & 8) {
                oct |= -8;
            }
            oct += 5;
            slot.step = oct >= 0 ? (slot.FN | 1024) << oct : (slot.FN | 1024) >> -oct;
            slot.update_AR();
            slot.update_D1R();
            slot.update_D2R();
            slot.update_RR();
            slot.update_C5();
            break;
        }
        case 3:
            slot.TL = data >> 1;
            slot.LD = data & 0x1;

            // TODO
            if (slot.LD) {
                // directly change volume
            } else {
                // interpolate volume
            }
            break;
        case 4:
            if (data & 0x10) {
                // output to DO1 pin:
                // this pin is not used in moonsound
                // we emulate this by muting the sound
                slot.pan = 8; // both left/right -inf dB
            } else {
                slot.pan = data & 0x0F;
            }

            if (data & 0x020) {
                // LFO reset
                slot.lfo_active = false;
                slot.lfo_cnt = 0;
                slot.lfo_idx = 0;
                slot.lfo_max = lfo_period[(int)slot.vib];
                slot.lfo_step = 0;
            } else {
                // LFO activate
                slot.lfo_active = true;
            }

            switch (data >> 6) {
            case 0: //tone off, no damp
                if (slot.active && (slot.state != EG_REV) ) {
                    slot.state = EG_REL;
                }
                break;
            case 2: //tone on, no damp
                if (!(regs[reg] & 0x080)) {
                    keyOnHelper(slot);
                }
                break;
            case 1: //tone off, damp
            case 3: //tone on, damp
                slot.state = EG_DMP;
                break;
            }
            break;
        case 5:
            slot.vib = data & 0x7;
            slot.set_lfo((data >> 3) & 0x7);
            break;
        case 6:
            slot.AR  = data >> 4;
            slot.D1R = data & 0xF;
            slot.update_AR();
            slot.update_D1R();
            break;
        case 7:
            slot.DL  = dl_tab[data >> 4];
            slot.D2R = data & 0xF;
            slot.update_D2R();
            break;
        case 8:
            slot.RC = data >> 4;
            slot.RR = data & 0xF;
            slot.update_AR();
            slot.update_D1R();
            slot.update_D2R();
            slot.update_RR();
            slot.update_C5();
            break;
        case 9:
            slot.AM = data & 0x7;
            break;
        }
    } else {
        // All non-slot registers
        switch (reg) {
        case 0x00:      // TEST
        case 0x01:
            break;

        case 0x02:
            wavetblhdr = (data >> 2) & 0x7;
            memmode = data & 1;
            break;

        case 0x03:
            memadr = (memadr & 0x00FFFF) | (data << 16);
            break;

        case 0x04:
            memadr = (memadr & 0xFF00FF) | (data << 8);
            break;

        case 0x05:
            memadr = (memadr & 0xFFFF00) | data;
            break;

        case 0x06:  // memory data
            writeMem(memadr, data);
            memadr = (memadr + 1) & 0xFFFFFF;
            break;

        case 0xF8:
            // TODO use these
            fm_l = data & 0x7;
            fm_r = (data >> 3) & 0x7;
            break;

        case 0xF9:
            pcm_l = data & 0x7;
            pcm_r = (data >> 3) & 0x7;
            break;
        }
    }

    regs[reg] = data;
}

uint8_t IRAM_ATTR YMF278::readRegOPL4(uint8_t reg)
{
    uint8_t result;
    switch(reg) {
        case 6: // Memory Data Register
            result = readMem(memadr);
            memadr = (memadr + 1) & 0xFFFFFF;
            break;

        default:
            // Are all handled in FPGA
            result = 0xff;
            break;
    }
    return result;
}

YMF278::YMF278(int16_t volume, int ramSize, void* romData, int romSize)
{
    memadr = 0; // avoid UMR
    rom = (uint8_t*)romData;
    endRom = romSize;
    ramSize *= 1024;    // in kb

    this->ramSize = ramSize;

    ram = (uint8_t*)heap_caps_malloc(ramSize, MALLOC_CAP_SPIRAM);
    assert(ram != NULL);
    memset(ram, 0, ramSize);

    ram12bit = (uint8_t*)heap_caps_malloc(ramSize * 4 / 3, MALLOC_CAP_SPIRAM);
    assert(ram12bit != NULL);
    memset(ram12bit, 0, ramSize * 4 / 3);

    endRam = endRom + ramSize;

    rom12bit = (uint8_t*)heap_caps_malloc(romSize * 4 / 3, MALLOC_CAP_SPIRAM);
    assert(rom12bit != NULL);

    uint16_t *p = (uint16_t*)rom12bit;
    for(int i = 0; i < romSize * 4 / 6; i++) {
        int addr = ((i / 2) * 3);
        if (i & 1) {
            *p++ = rom[addr + 2] << 8 |
                 ((rom[addr + 1] << 4) & 0xF0);
        } else {
            *p++ = rom[addr + 0] << 8 |
                 (rom[addr + 1] & 0xF0);
        }
    }

    reset();
}

YMF278::~YMF278()
{
    heap_caps_free(rom12bit);
    heap_caps_free(ram12bit);
    heap_caps_free(ram);
}

void YMF278::reset()
{
    eg_cnt   = 0;

    int i;
    for (i = 0; i < 24; i++) {
        slots[i].reset();
        slots[i].sampleptr = rom;
    }
    for (i = 255; i >= 0; i--) { // reverse order to avoid UMR
        writeRegOPL4(i, 0);
    }
    setInternalMute(true);
    wavetblhdr = memmode = memadr = 0;
    fm_l = fm_r = pcm_l = pcm_r = 0;
}

void YMF278::setSampleRate(int sampleRate, int Oversampling)
{
}

void YMF278::setInternalVolume(int16_t newVolume)
{
    newVolume /= 32;
    // Volume table, 1 = -0.375dB, 8 = -3dB, 256 = -96dB
    int i;
    for (i = 0; i < 256; i++) {
        volume[i] = (int)(4.0 * (double)newVolume * pow(2.0, (-0.375 / 6) * i));
    }
    for (i = 256; i < 256 * 4; i++) {
        volume[i] = 0;
    }
}

uint8_t IRAM_ATTR YMF278::readMem(unsigned int address)
{
    if (address < endRom) {
        return rom[address];
    } else
    if (address < endRam) {
        return ram[address - endRom];
    } else {
        return 0xff;
    }
}

void IRAM_ATTR YMF278::writeMem(unsigned int address, uint8_t value)
{
    if (address < endRom) {
        // can't write to ROM
    } else if (address < endRam) {
        ram[address - endRom] = value;
        // update 12-bit version
        int part = (address - endRom) % 3;
        int addr = ((address - endRom) / 3) * 4;
        switch (part) {
        case 0:
            *(uint16_t*)&ram12bit[addr] = (*(uint16_t*)&ram12bit[addr] & 0xf000) | (value << 4);
            break;
        case 1:
            ram12bit[addr + 1] = (ram12bit[addr + 1] & 0x0f) | (value << 4);
            ram12bit[addr + 2] = value & 0xf0;
            break;
        case 2:
            ram12bit[addr + 3] = value;
            break;
        }
    } else {
        // can't write to unmapped memory
    }
}
