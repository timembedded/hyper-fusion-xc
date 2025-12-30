// This file is taken from the openMSX project. 
// The file has been modified to be built in the blueMSX environment.
//
// The file was originally written by Mitsutaka Okazaki.
//
#include "OpenMsxYM2413_2.h"
#include <esp_heap_caps.h>

#ifdef assert
#undef assert
#endif
#define assert(x)

#include <cmath>
#include <algorithm>

using std::string;

#define MIN(a,b) (((a)<(b))?(a):(b))

static const int CLOCK_FREQ = 3579545;
static const double PI = 3.14159265358979323846;

OpenYM2413_2::tables_t *OpenYM2413_2::tables;
unsigned int OpenYM2413_2::pm_dphase;
unsigned int OpenYM2413_2::am_dphase;

//***************************************************//
//                                                   //
//  Helper functions                                 //
//                                                   //
//***************************************************//

int OpenYM2413_2::Slot::EG2DB(int d) 
{
    return d * (int)(EG_STEP / DB_STEP);
}
int OpenYM2413_2::TL2EG(int d)
{ 
    return d * (int)(TL_STEP / EG_STEP);
}

unsigned int OpenYM2413_2::DB_POS(double x)
{
    return (unsigned int)(x / DB_STEP);
}
unsigned int OpenYM2413_2::DB_NEG(double x)
{
    return (unsigned int)(2 * DB_MUTE + x / DB_STEP);
}

// Cut the lower b bit off
template <typename T>
static inline T HIGHBITS(T c, int b)
{
    return c >> b;
}
// Expand x which is s bits to d bits
static inline unsigned EXPAND_BITS(unsigned x, int s, int d)
{
    return x << (d - s);
}
// Adjust envelope speed which depends on sampling rate
static inline unsigned int rate_adjust(double x, int rate)
{
    double tmp = x * CLOCK_FREQ / 72 / rate + 0.5; // +0.5 to round
    assert (tmp <= 4294967295U);
    return (unsigned int)tmp;
}

static inline bool BIT(int s, int b)
{
    return (s >> b) & 1;
}


//***************************************************//
//                                                   //
//                  Create tables                    //
//                                                   //
//***************************************************//

// Table for AR to LogCurve.
void OpenYM2413_2::makeAdjustTable()
{
    tables->AR_ADJUST_TABLE[0] = (1 << EG_BITS) - 1;
    for (int i = 1; i < (1 << EG_BITS); ++i) {
        tables->AR_ADJUST_TABLE[i] = (unsigned short)((double)(1 << EG_BITS) - 1 -
                             ((1 << EG_BITS) - 1) * ::log((double)i) / ::log(127.0));
    }
}

// Table for dB(0 .. (1<<DB_BITS)-1) to lin(0 .. DB2LIN_AMP_WIDTH)
void OpenYM2413_2::makeDB2LinTable()
{
    for (int i = 0; i < 2 * DB_MUTE; ++i) {
        tables->dB2LinTab[i] = (i < DB_MUTE)
                     ?  (short)((double)((1 << DB2LIN_AMP_BITS) - 1) *
                            pow(10.0, -(double)i * DB_STEP / 20))
                     : 0;
        tables->dB2LinTab[i + 2 * DB_MUTE] = -tables->dB2LinTab[i];
    }
}

// lin(+0.0 .. +1.0) to  dB((1<<DB_BITS)-1 .. 0)
int OpenYM2413_2::lin2db(double d)
{
    return (d == 0)
        ? DB_MUTE - 1
        : MIN(-(int)(20.0 * log10(d) / DB_STEP), DB_MUTE - 1); // 0 - 127
}

// Sin Table
void OpenYM2413_2::makeSinTable()
{
    for (int i = 0; i < PG_WIDTH / 4; ++i)
        tables->fullsintable[i] = lin2db(sin(2.0 * PI * i / PG_WIDTH));
    for (int i = 0; i < PG_WIDTH / 4; ++i)
        tables->fullsintable[PG_WIDTH / 2 - 1 - i] = tables->fullsintable[i];
    for (int i = 0; i < PG_WIDTH / 2; ++i)
        tables->fullsintable[PG_WIDTH / 2 + i] = 2 * DB_MUTE + tables->fullsintable[i];

    for (int i = 0; i < PG_WIDTH / 2; ++i)
        tables->halfsintable[i] = tables->fullsintable[i];
    for (int i = PG_WIDTH / 2; i < PG_WIDTH; ++i)
        tables->halfsintable[i] = tables->fullsintable[0];

  tables->waveform[0] = tables->fullsintable;
  tables->waveform[1] = tables->halfsintable;
}

static inline double saw(double phase)
{
  if (phase <= (PI / 2)) {
    return phase * 2 / PI;
  } else if (phase <= (PI * 3 / 2)) {
    return 2.0 - (phase * 2 / PI);
  } else {
    return -4.0 + phase * 2 / PI;
  }
}

// Table for Pitch Modulator
void OpenYM2413_2::makePmTable()
{
    for (int i = 0; i < PM_PG_WIDTH; ++i) {
         tables->pmtable[i] = (int)((double)PM_AMP * 
             pow(2.0, (double)PM_DEPTH * 
                    saw(2.0 * PI * i / PM_PG_WIDTH) / 1200));
    }
}

// Table for Amp Modulator
void OpenYM2413_2::makeAmTable()
{
    for (int i = 0; i < AM_PG_WIDTH; ++i) {
        tables->amtable[i] = (int)((double)AM_DEPTH / 2 / DB_STEP *
                           (1.0 + saw(2.0 * PI * i / PM_PG_WIDTH)));
    }
}

// Phase increment counter table
void OpenYM2413_2::makeDphaseTable(int sampleRate)
{
    unsigned int mltable[16] = {
        1,   1*2,  2*2,  3*2,  4*2,  5*2,  6*2,  7*2,
        8*2, 9*2, 10*2, 10*2, 12*2, 12*2, 15*2, 15*2
    };

    for (unsigned fnum = 0; fnum < 512; ++fnum) {
        for (unsigned block = 0; block < 8; ++block) {
            for (unsigned ML = 0; ML < 16; ++ML) {
                tables->dphaseTable[fnum][block][ML] = 
                    rate_adjust(((fnum * mltable[ML]) << block) >>
                                (20 - DP_BITS),
                                sampleRate);
            }
        }
    }
}

void OpenYM2413_2::makeTllTable()
{
    double kltable[16] = {
        ( 0.000 * 2), ( 9.000 * 2), (12.000 * 2), (13.875 * 2),
        (15.000 * 2), (16.125 * 2), (16.875 * 2), (17.625 * 2),
        (18.000 * 2), (18.750 * 2), (19.125 * 2), (19.500 * 2),
        (19.875 * 2), (20.250 * 2), (20.625 * 2), (21.000 * 2)
    };
  
    for (int fnum = 0; fnum < 16; ++fnum) {
        for (int block = 0; block < 8; ++block) {
            for (int TL = 0; TL < 64; ++TL) {
                for (int KL = 0; KL < 4; ++KL) {
                    if (KL == 0) {
                        tables->tllTable[fnum][block][TL][KL] = TL2EG(TL);
                    } else {
                        int tmp = (int)(kltable[fnum] - (3.000 * 2) * (7 - block));
                        tables->tllTable[fnum][block][TL][KL] =
                            (tmp <= 0) ?
                            TL2EG(TL) :
                            (unsigned int)((tmp >> (3 - KL)) / EG_STEP) + TL2EG(TL);
                    }
                }
            }
        }
    }
}

// Rate Table for Attack
void OpenYM2413_2::makeDphaseARTable(int sampleRate)
{
    for (int AR = 0; AR < 16; ++AR) {
        for (int Rks = 0; Rks < 16; ++Rks) {
            int RM = AR + (Rks >> 2);
            int RL = Rks & 3;
            if (RM > 15) RM = 15;
            switch (AR) { 
            case 0:
                tables->dphaseARTable[AR][Rks] = 0;
                break;
            case 15:
                tables->dphaseARTable[AR][Rks] = 0; // EG_DP_WIDTH
                break;
            default:
                tables->dphaseARTable[AR][Rks] = rate_adjust(3 * (RL + 4) << (RM + 1), sampleRate);
                break;
            }
        }
    }
}

// Rate Table for Decay
void OpenYM2413_2::makeDphaseDRTable(int sampleRate)
{
    for (int DR = 0; DR < 16; ++DR) {
        for (int Rks = 0; Rks < 16; ++Rks) {
            int RM = DR + (Rks >> 2);
            int RL = Rks & 3;
            if (RM > 15) RM = 15;
            switch(DR) { 
            case 0:
                tables->dphaseDRTable[DR][Rks] = 0;
                break;
            default:
                tables->dphaseDRTable[DR][Rks] = rate_adjust((RL + 4) << (RM - 1), sampleRate);
                break;
            }
        }
    }
}

void OpenYM2413_2::makeRksTable()
{
    for (int fnum8 = 0; fnum8 < 2; ++fnum8) {
        for (int block = 0; block < 8; ++block) {
            for (int KR = 0; KR < 2; ++KR) {
                tables->rksTable[fnum8][block][KR] = (KR != 0)
                    ? (block << 1) + fnum8
                    :  block >> 1;
            }
        }
    }
}

//************************************************************//
//                                                            //
//                      Patch                                 //
//                                                            //
//************************************************************//

OpenYM2413_2::Patch::Patch()
    : AM(false), PM(false), EG(false)
    , KR(0), ML(0), KL(0), TL(0), FB(0)
    , WF(0), AR(0), DR(0), SL(0), RR(0)
{
}

OpenYM2413_2::Patch::Patch(int n, const uint8_t* data)
{
    if (n == 0) {
        AM = (data[0] >> 7) & 1;
        PM = (data[0] >> 6) & 1;
        EG = (data[0] >> 5) & 1;
        KR = (data[0] >> 4) & 1;
        ML = (data[0] >> 0) & 15;
        KL = (data[2] >> 6) & 3;
        TL = (data[2] >> 0) & 63;
        FB = (data[3] >> 0) & 7;
        WF = (data[3] >> 3) & 1;
        AR = (data[4] >> 4) & 15;
        DR = (data[4] >> 0) & 15;
        SL = (data[6] >> 4) & 15;
        RR = (data[6] >> 0) & 15;
    } else {
        AM = (data[1] >> 7) & 1;
        PM = (data[1] >> 6) & 1;
        EG = (data[1] >> 5) & 1;
        KR = (data[1] >> 4) & 1;
        ML = (data[1] >> 0) & 15;
        KL = (data[3] >> 6) & 3;
        TL = 0;
        FB = 0;
        WF = (data[3] >> 4) & 1;
        AR = (data[5] >> 4) & 15;
        DR = (data[5] >> 0) & 15;
        SL = (data[7] >> 4) & 15;
        RR = (data[7] >> 0) & 15;
    }
}

//************************************************************//
//                                                            //
//                      Slot                                  //
//                                                            //
//************************************************************//

OpenYM2413_2::Slot::Slot(bool type)
{
    reset(type);
}

void OpenYM2413_2::Slot::reset(bool type_)
{
    if (tables == nullptr) {
        tables = (tables_t*)heap_caps_malloc(sizeof(tables_t), MALLOC_CAP_SPIRAM);
    }
    type = type_;
    sintblIdx = 0;
    sintbl = tables->waveform[sintblIdx];
    phase = 0;
    dphase = 0;
    output[0] = 0;
    output[1] = 0;
    feedback = 0;
    eg_mode = FINISH;
    eg_phase = EG_DP_WIDTH;
    eg_dphase = 0;
    rks = 0;
    tll = 0;
    sustine = false;
    fnum = 0;
    block = 0;
    volume = 0;
    pgout = 0;
    egout = 0;
    slot_on_flag = false;

    setPatch(NULL_PATCH_IDX);
}


void OpenYM2413_2::Slot::updatePG()
{
    dphase = tables->dphaseTable[fnum][block][patches[patchIdx].ML];
}

void OpenYM2413_2::Slot::updateTLL()
{
    tll = type ? tables->tllTable[fnum >> 5][block][volume]   [patches[patchIdx].KL]:
                 tables->tllTable[fnum >> 5][block][patches[patchIdx].TL][patches[patchIdx].KL];
}

void OpenYM2413_2::Slot::updateRKS()
{
    rks = tables->rksTable[fnum >> 8][block][patches[patchIdx].KR];
}

void OpenYM2413_2::Slot::updateWF()
{
    sintblIdx = patches[patchIdx].WF;
    sintbl = tables->waveform[sintblIdx];
}

void OpenYM2413_2::Slot::updateEG()
{
    switch (eg_mode) {
    case ATTACK:
        eg_dphase = tables->dphaseARTable[patches[patchIdx].AR][rks];
        break;
    case DECAY:
        eg_dphase = tables->dphaseDRTable[patches[patchIdx].DR][rks];
        break;
    case SUSTINE:
        eg_dphase = tables->dphaseDRTable[patches[patchIdx].RR][rks];
        break;
    case RELEASE:
        if (sustine) {
            eg_dphase = tables->dphaseDRTable[5][rks];
        } else if (patches[patchIdx].EG) {
            eg_dphase = tables->dphaseDRTable[patches[patchIdx].RR][rks];
        } else {
            eg_dphase = tables->dphaseDRTable[7][rks];
        }
        break;
    case SETTLE:
        eg_dphase = tables->dphaseDRTable[15][0];
        break;
    case SUSHOLD:
    case FINISH:
    default:
        eg_dphase = 0;
        break;
    }
}

void OpenYM2413_2::Slot::updateAll()
{
    updatePG();
    updateTLL();
    updateRKS();
    updateWF();
    updateEG(); // EG should be updated last
}


// Slot key on
void OpenYM2413_2::Slot::slotOn()
{
    eg_mode = ATTACK;
    eg_phase = 0;
    phase = 0;
    updateEG();
}

// Slot key on, without resetting the phase
void OpenYM2413_2::Slot::slotOn2()
{
    eg_mode = ATTACK;
    eg_phase = 0;
    updateEG();
}

// Slot key off
void OpenYM2413_2::Slot::slotOff()
{
    if (eg_mode == ATTACK) {
        eg_phase = EXPAND_BITS(
            tables->AR_ADJUST_TABLE[HIGHBITS(
                eg_phase, EG_DP_BITS - EG_BITS)],
            EG_BITS, EG_DP_BITS);
    }
    eg_mode = RELEASE;
    updateEG();
}


// Change a rhythm voice
void OpenYM2413_2::Slot::setPatch(int idx)
{
    patchIdx = idx;
}

void OpenYM2413_2::Slot::setVolume(int newVolume)
{
    volume = newVolume;
}



//***********************************************************//
//                                                           //
//               Channel                                     //
//                                                           //
//***********************************************************//


OpenYM2413_2::Channel::Channel()
    : mod(false), car(true)
{
    reset();
}

// reset channel
void OpenYM2413_2::Channel::reset()
{
    mod.reset(false);
    car.reset(true);
    setPatch(0);
}

// Change a voice
void OpenYM2413_2::Channel::setPatch(int num)
{
    patch_number = num;
    mod.setPatch(2 * num + 0);
    car.setPatch(2 * num + 1);
}

// Set sustine parameter
void OpenYM2413_2::Channel::setSustine(bool sustine)
{
    car.sustine = sustine;
    if (mod.type) {
        mod.sustine = sustine;
    }
}

// Volume : 6bit ( Volume register << 2 )
void OpenYM2413_2::Channel::setVol(int volume)
{
    car.volume = volume;
}

// Set F-Number (fnum : 9bit)
void OpenYM2413_2::Channel::setFnumber(int fnum)
{
    car.fnum = fnum;
    mod.fnum = fnum;
}

// Set Block data (block : 3bit)
void OpenYM2413_2::Channel::setBlock(int block)
{
    car.block = block;
    mod.block = block;
}

// Channel key on
void OpenYM2413_2::Channel::keyOn()
{
    if (!mod.slot_on_flag) mod.slotOn();
    if (!car.slot_on_flag) car.slotOn();
}

// Channel key off
void OpenYM2413_2::Channel::keyOff()
{
    // Note: no mod.slotOff() in original code!!!
    if (car.slot_on_flag) car.slotOff();
}



//***********************************************************//
//                                                           //
//               OpenYM2413_2                                      //
//                                                           //
//***********************************************************//

static uint8_t inst_data[16 + 3][8] = {
    { 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00 }, // user instrument
    { 0x61,0x61,0x1e,0x17,0xf0,0x7f,0x00,0x17 }, // violin
    { 0x13,0x41,0x16,0x0e,0xfd,0xf4,0x23,0x23 }, // guitar
    { 0x03,0x01,0x9a,0x04,0xf3,0xf3,0x13,0xf3 }, // piano
    { 0x11,0x61,0x0e,0x07,0xfa,0x64,0x70,0x17 }, // flute
    { 0x22,0x21,0x1e,0x06,0xf0,0x76,0x00,0x28 }, // clarinet
    { 0x21,0x22,0x16,0x05,0xf0,0x71,0x00,0x18 }, // oboe
    { 0x21,0x61,0x1d,0x07,0x82,0x80,0x17,0x17 }, // trumpet
    { 0x23,0x21,0x2d,0x16,0x90,0x90,0x00,0x07 }, // organ
    { 0x21,0x21,0x1b,0x06,0x64,0x65,0x10,0x17 }, // horn
    { 0x21,0x21,0x0b,0x1a,0x85,0xa0,0x70,0x07 }, // synthesizer
    { 0x23,0x01,0x83,0x10,0xff,0xb4,0x10,0xf4 }, // harpsichord
    { 0x97,0xc1,0x20,0x07,0xff,0xf4,0x22,0x22 }, // vibraphone
    { 0x61,0x00,0x0c,0x05,0xc2,0xf6,0x40,0x44 }, // synthesizer bass
    { 0x01,0x01,0x56,0x03,0x94,0xc2,0x03,0x12 }, // acoustic bass
    { 0x21,0x01,0x89,0x03,0xf1,0xe4,0xf0,0x23 }, // electric guitar
    { 0x07,0x21,0x14,0x00,0xee,0xf8,0xff,0xf8 },
    { 0x01,0x31,0x00,0x00,0xf8,0xf7,0xf8,0xf7 },
    { 0x25,0x11,0x00,0x00,0xf8,0xfa,0xf8,0x55 }
};

OpenYM2413_2::OpenYM2413_2(short volume)
{
    for (int i = 0; i < 16 + 3; ++i) {
        patches[2 * i + 0] = Patch(0, inst_data[i]);
        patches[2 * i + 1] = Patch(1, inst_data[i]);
    }

    for (int i = 0; i < 0x40; ++i) {
        reg[i] = 0; // avoid UMR
    }

    for (int i = 0; i < 9; ++i) {
        // TODO cleanup
        ch[i].patches = patches;
        ch[i].mod.patches = patches;
        ch[i].car.patches = patches;
    }

    makePmTable();
    makeAmTable();
    makeDB2LinTable();
    makeAdjustTable();
    makeTllTable();
    makeRksTable();
    makeSinTable();

    reset();
}

OpenYM2413_2::~OpenYM2413_2()
{
}

// Reset whole of OPLL except patch datas
void OpenYM2413_2::reset()
{
    pm_phase = 0;
    am_phase = 0;
    noise_seed = 0xFFFF;

    for(int i = 0; i < 9; i++) {
        ch[i].reset();
    }
    for (int i = 0; i < 0x40; i++) {
        writeReg(i, 0);
    }
    setInternalMute(true);  // set muted
}

void OpenYM2413_2::setSampleRate(int sampleRate, int Oversampling)
{
    makeDphaseTable(sampleRate);
    makeDphaseARTable(sampleRate);
    makeDphaseDRTable(sampleRate);
    pm_dphase = rate_adjust(PM_SPEED * PM_DP_WIDTH / (CLOCK_FREQ / 72), sampleRate);
    am_dphase = rate_adjust(AM_SPEED * AM_DP_WIDTH / (CLOCK_FREQ / 72), sampleRate);
}


// Drum key on
void OpenYM2413_2::keyOn_BD()  { ch[6].keyOn(); }
void OpenYM2413_2::keyOn_HH()  { if (!ch[7].mod.slot_on_flag) ch[7].mod.slotOn2(); }
void OpenYM2413_2::keyOn_SD()  { if (!ch[7].car.slot_on_flag) ch[7].car.slotOn (); }
void OpenYM2413_2::keyOn_TOM() { if (!ch[8].mod.slot_on_flag) ch[8].mod.slotOn (); }
void OpenYM2413_2::keyOn_CYM() { if (!ch[8].car.slot_on_flag) ch[8].car.slotOn2(); }

// Drum key off
void OpenYM2413_2::keyOff_BD() { ch[6].keyOff(); }
void OpenYM2413_2::keyOff_HH() { if (ch[7].mod.slot_on_flag) ch[7].mod.slotOff(); }
void OpenYM2413_2::keyOff_SD() { if (ch[7].car.slot_on_flag) ch[7].car.slotOff(); }
void OpenYM2413_2::keyOff_TOM(){ if (ch[8].mod.slot_on_flag) ch[8].mod.slotOff(); }
void OpenYM2413_2::keyOff_CYM(){ if (ch[8].car.slot_on_flag) ch[8].car.slotOff(); }

void OpenYM2413_2::update_rhythm_mode()
{
    if (ch[6].patch_number & 0x10) {
        if (!(ch[6].car.slot_on_flag ||
              (reg[0x0e] & 0x20))) {
            ch[6].mod.eg_mode = FINISH;
            ch[6].car.eg_mode = FINISH;
            ch[6].setPatch(reg[0x36] >> 4);
        }
    } else if (reg[0x0e] & 0x20) {
        ch[6].mod.eg_mode = FINISH;
        ch[6].car.eg_mode = FINISH;
        ch[6].setPatch(16);
    }

    if (ch[7].patch_number & 0x10) {
        if (!((ch[7].mod.slot_on_flag && ch[7].car.slot_on_flag) ||
              (reg[0x0e] & 0x20))) {
            ch[7].mod.type = false;
            ch[7].mod.eg_mode = FINISH;
            ch[7].car.eg_mode = FINISH;
            ch[7].setPatch(reg[0x37] >> 4);
        }
    } else if (reg[0x0e] & 0x20) {
        ch[7].mod.type = true;
        ch[7].mod.eg_mode = FINISH;
        ch[7].car.eg_mode = FINISH;
        ch[7].setPatch(17);
    }

    if (ch[8].patch_number & 0x10) {
        if (!((ch[8].mod.slot_on_flag && ch[8].car.slot_on_flag) ||
              (reg[0x0e] & 0x20))) {
            ch[8].mod.type = false;
            ch[8].mod.eg_mode = FINISH;
            ch[8].car.eg_mode = FINISH;
            ch[8].setPatch(reg[0x38] >> 4);
        }
    } else if (reg[0x0e] & 0x20) {
        ch[8].mod.type = true;
        ch[8].mod.eg_mode = FINISH;
        ch[8].car.eg_mode = FINISH;
        ch[8].setPatch(18);
    }
}

void OpenYM2413_2::update_key_status()
{
    for (int i = 0; i < 9; ++i) {
        ch[i].mod.slot_on_flag = ch[i].car.slot_on_flag =
            (reg[0x20 + i] & 0x10) != 0;
    }
    if (reg[0x0e] & 0x20) {
        ch[6].mod.slot_on_flag |= 0 != (reg[0x0e] & 0x10); // BD1
        ch[6].car.slot_on_flag |= 0 != (reg[0x0e] & 0x10); // BD2
        ch[7].mod.slot_on_flag |= 0 != (reg[0x0e] & 0x01); // HH
        ch[7].car.slot_on_flag |= 0 != (reg[0x0e] & 0x08); // SD
        ch[8].mod.slot_on_flag |= 0 != (reg[0x0e] & 0x04); // TOM
        ch[8].car.slot_on_flag |= 0 != (reg[0x0e] & 0x02); // SYM
    }
}


//******************************************************//
//                                                      //
//                 Generate wave data                   //
//                                                      //
//******************************************************//

// Convert Amp(0 to EG_HEIGHT) to Phase(0 to 4PI)
int OpenYM2413_2::Slot::wave2_4pi(int e) 
{
    int shift =  SLOT_AMP_BITS - PG_BITS - 1;
    if (shift > 0) {
        return e >> shift;
    } else {
        return e << -shift;
    }
}

// Convert Amp(0 to EG_HEIGHT) to Phase(0 to 8PI)
int OpenYM2413_2::Slot::wave2_8pi(int e) 
{
    int shift = SLOT_AMP_BITS - PG_BITS - 2;
    if (shift > 0) {
        return e >> shift;
    } else {
        return e << -shift;
    }
}

// Update AM, PM unit
inline void OpenYM2413_2::update_ampm()
{
    pm_phase = (pm_phase + pm_dphase) & (PM_DP_WIDTH - 1);
    am_phase = (am_phase + am_dphase) & (AM_DP_WIDTH - 1);
    lfo_am = tables->amtable[HIGHBITS(am_phase, AM_DP_BITS - AM_PG_BITS)];
    lfo_pm = tables->pmtable[HIGHBITS(pm_phase, PM_DP_BITS - PM_PG_BITS)];
}

// PG
void OpenYM2413_2::Slot::calc_phase(int lfo_pm)
{
    if (patches[patchIdx].PM) {
        phase += (dphase * lfo_pm) >> PM_AMP_BITS;
    } else {
        phase += dphase;
    }
    phase &= (DP_WIDTH - 1);
    pgout = HIGHBITS(phase, DP_BASE_BITS);
}

// Update Noise unit
inline void OpenYM2413_2::update_noise()
{
   if (noise_seed & 1) noise_seed ^= 0x8003020;
   noise_seed >>= 1;
}

#define SL2EG(d) (d * (int)(SL_STEP / EG_STEP))
#define S2E(x) (SL2EG((int)(x / SL_STEP)) << (EG_DP_BITS - EG_BITS)) 
static unsigned int SL[16] = {
    S2E( 0.0), S2E( 3.0), S2E( 6.0), S2E( 9.0),
    S2E(12.0), S2E(15.0), S2E(18.0), S2E(21.0),
    S2E(24.0), S2E(27.0), S2E(30.0), S2E(33.0),
    S2E(36.0), S2E(39.0), S2E(42.0), S2E(48.0)
};

// EG
void OpenYM2413_2::Slot::calc_envelope(int lfo_am)
{
    unsigned out;
    switch (eg_mode) {
    case ATTACK:
        out = tables->AR_ADJUST_TABLE[HIGHBITS(eg_phase, EG_DP_BITS - EG_BITS)];
        eg_phase += eg_dphase;
        if ((EG_DP_WIDTH & eg_phase) || (patches[patchIdx].AR == 15)) {
            out = 0;
            eg_phase = 0;
            eg_mode = DECAY;
            updateEG();
        }
        break;
    case DECAY:
        out = HIGHBITS(eg_phase, EG_DP_BITS - EG_BITS);
        eg_phase += eg_dphase;
        if (eg_phase >= SL[patches[patchIdx].SL]) {
            eg_phase = SL[patches[patchIdx].SL];
            if (patches[patchIdx].EG) {
                eg_mode = SUSHOLD;
            } else {
                eg_mode = SUSTINE;
            }
            updateEG();
        }
        break;
    case SUSHOLD:
        out = HIGHBITS(eg_phase, EG_DP_BITS - EG_BITS);
        if (patches[patchIdx].EG == 0) {
            eg_mode = SUSTINE;
            updateEG();
        }
        break;
    case SUSTINE:
    case RELEASE:
        out = HIGHBITS(eg_phase, EG_DP_BITS - EG_BITS);
        eg_phase += eg_dphase;
        if (out >= (1 << EG_BITS)) {
            eg_mode = FINISH;
            out = (1 << EG_BITS) - 1;
        }
        break;
    case SETTLE:
        out = HIGHBITS(eg_phase, EG_DP_BITS - EG_BITS);
        eg_phase += eg_dphase;
        if (out >= (1 << EG_BITS)) {
            eg_mode = ATTACK;
            out = (1 << EG_BITS) - 1;
            updateEG();
        }
        break;
    case FINISH:
    default:
        out = (1 << EG_BITS) - 1;
        break;
    }
    if (patches[patchIdx].AM) {
        out = EG2DB(out + tll) + lfo_am;
    } else {
        out = EG2DB(out + tll);
    }
    if (out >= (unsigned)DB_MUTE) {
        out = DB_MUTE - 1;
    }
    
    egout = out | 3;
}

// CARRIOR
int OpenYM2413_2::Slot::calc_slot_car(int fm)
{
    if (egout >= (DB_MUTE - 1)) {
        output[0] = 0;
    } else {
        output[0] = tables->dB2LinTab[sintbl[(pgout + wave2_8pi(fm)) & (PG_WIDTH - 1)]
                               + egout];
    }
    output[1] = (output[1] + output[0]) >> 1;
    return output[1];
}

// MODULATOR
int OpenYM2413_2::Slot::calc_slot_mod()
{
    output[1] = output[0];

    if (egout >= (DB_MUTE - 1)) {
        output[0] = 0;
    } else if (patches[patchIdx].FB != 0) {
        int fm = wave2_4pi(feedback) >> (7 - patches[patchIdx].FB);
        output[0] = tables->dB2LinTab[sintbl[(pgout + fm) & (PG_WIDTH - 1)] + egout];
    } else {
        output[0] = tables->dB2LinTab[sintbl[pgout] + egout];
    }
    feedback = (output[1] + output[0]) >> 1;
    return feedback;
}

// TOM
int OpenYM2413_2::Slot::calc_slot_tom()
{
    return (egout >= (DB_MUTE - 1))
         ? 0
         : tables->dB2LinTab[sintbl[pgout] + egout];
}

// SNARE
int OpenYM2413_2::Slot::calc_slot_snare(bool noise)
{
    if (egout >= (DB_MUTE - 1)) {
        return 0;
    } 
    if (BIT(pgout, 7)) {
        return tables->dB2LinTab[(noise ? DB_POS(0.0) : DB_POS(15.0)) + egout];
    } else {
        return tables->dB2LinTab[(noise ? DB_NEG(0.0) : DB_NEG(15.0)) + egout];
    }
}

// TOP-CYM
int OpenYM2413_2::Slot::calc_slot_cym(unsigned int pgout_hh)
{
    if (egout >= (DB_MUTE - 1)) {
        return 0;
    }
    unsigned int dbout
        = (((BIT(pgout_hh, PG_BITS - 8) ^ BIT(pgout_hh, PG_BITS - 1)) |
            BIT(pgout_hh, PG_BITS - 7)) ^
           (BIT(pgout, PG_BITS - 7) & !BIT(pgout, PG_BITS - 5)))
        ? DB_NEG(3.0)
        : DB_POS(3.0);
    return tables->dB2LinTab[dbout + egout];
}

// HI-HAT
int OpenYM2413_2::Slot::calc_slot_hat(int pgout_cym, bool noise)
{
    if (egout >= (DB_MUTE - 1)) {
        return 0;
    }
    unsigned int dbout;
    if (((BIT(pgout, PG_BITS - 8) ^ BIT(pgout, PG_BITS - 1)) |
         BIT(pgout, PG_BITS - 7)) ^
        (BIT(pgout_cym, PG_BITS - 7) & !BIT(pgout_cym, PG_BITS - 5))) {
        dbout = noise ? DB_NEG(12.0) : DB_NEG(24.0);
    } else {
        dbout = noise ? DB_POS(12.0) : DB_POS(24.0);
    }
    return tables->dB2LinTab[dbout + egout];
}

int OpenYM2413_2::filter(int input) {
    in[4] = in[3];
    in[3] = in[2];
    in[2] = in[1];
    in[1] = in[0];
    in[0] = input;

    return (0 * (in[0] + in[4]) + 1 * (in[3] + in[1]) + 2 * in[2]) / 4;
}

void OpenYM2413_2::calcSample(int *voice, int *drum)
{
    // while muted updated_ampm() and update_noise() aren't called, probably ok
    update_ampm();
    update_noise();

    for (int i = 0; i < 9; ++i) {
        ch[i].mod.calc_phase(lfo_pm);
        ch[i].mod.calc_envelope(lfo_am);
        ch[i].car.calc_phase(lfo_pm);
        ch[i].car.calc_envelope(lfo_am);
    }

    int channelMask = 0;
    for (int i = 0; i < 9; ++i) {
        if (ch[i].car.eg_mode != FINISH) {
            channelMask |= (1 << i);
        }
    }

    int mix_voice = 0;
    int mix_drum = 0;

    if (ch[6].patch_number & 0x10) {
        if (channelMask & (1 << 6)) {
            mix_drum += ch[6].car.calc_slot_car(ch[6].mod.calc_slot_mod());
            channelMask &= ~(1 << 6);
        }
    }
    if (ch[7].patch_number & 0x10) {
        if (ch[7].mod.eg_mode != FINISH) {
            mix_drum += ch[7].mod.calc_slot_hat(ch[8].car.pgout, noise_seed & 1);
        }
        if (channelMask & (1 << 7)) {
            mix_drum -= ch[7].car.calc_slot_snare(noise_seed & 1);
            channelMask &= ~(1 << 7);
        }
    }
    if (ch[8].patch_number & 0x10) {
        if (ch[8].mod.eg_mode != FINISH) {
            mix_drum += ch[8].mod.calc_slot_tom();
        }
        if (channelMask & (1 << 8)) {
            mix_drum -= ch[8].car.calc_slot_cym(ch[7].mod.pgout);
            channelMask &= ~(1 << 8);
        }
    }
    mix_drum *= 2;

    for (Channel* cp = ch; channelMask; channelMask >>= 1, ++cp) {
        if (channelMask & 1) {
            mix_voice += cp->car.calc_slot_car(cp->mod.calc_slot_mod());
        }
    }
    *voice = filter((maxVolume * mix_voice) >> (DB2LIN_AMP_BITS - 1));
    *drum = filter((maxVolume * mix_drum) >> (DB2LIN_AMP_BITS - 1));
}

void OpenYM2413_2::checkMute()
{
    setInternalMute(checkMuteHelper());
}

bool OpenYM2413_2::checkMuteHelper()
{
    for (int i = 0; i < 6; i++) {
        if (ch[i].car.eg_mode != FINISH) return false;
    }
    if (!(reg[0x0e] & 0x20)) {
        for(int i = 6; i < 9; i++) {
             if (ch[i].car.eg_mode != FINISH) return false;
        }
    } else {
        if (ch[6].car.eg_mode != FINISH) return false;
        if (ch[7].mod.eg_mode != FINISH) return false;
        if (ch[7].car.eg_mode != FINISH) return false;
        if (ch[8].mod.eg_mode != FINISH) return false;
        if (ch[8].car.eg_mode != FINISH) return false;
    }
    return true;    // nothing is playing, then mute
}

int* OpenYM2413_2::updateBuffer(int *buffer, int length)
{
    if (isInternalMuted()) {
        return NULL;
    }

    int* buf = buffer;
    int voice, drum;
    while (length--) {
        calcSample(&voice, &drum);
        *(buf++) = voice;
        *(buf++) = drum;
    }
    checkMute();

    return buffer;
}

void OpenYM2413_2::setInternalVolume(short newVolume)
{
    maxVolume = newVolume;
}


//**************************************************//
//                                                  //
//                       I/O Ctrl                   //
//                                                  //
//**************************************************//

void OpenYM2413_2::writeReg(uint8_t regis, uint8_t data)
{

    assert (regis < 0x40);
    reg[regis] = data;

    switch (regis) {
    case 0x00:
        patches[0].AM = (data >> 7) & 1;
        patches[0].PM = (data >> 6) & 1;
        patches[0].EG = (data >> 5) & 1;
        patches[0].KR = (data >> 4) & 1;
        patches[0].ML = (data >> 0) & 15;
        for (int i = 0; i < 9; ++i) {
            if (ch[i].patch_number == 0) {
                ch[i].mod.updatePG();
                ch[i].mod.updateRKS();
                ch[i].mod.updateEG();
            }
        }
        break;
    case 0x01:
        patches[1].AM = (data >> 7) & 1;
        patches[1].PM = (data >> 6) & 1;
        patches[1].EG = (data >> 5) & 1;
        patches[1].KR = (data >> 4) & 1;
        patches[1].ML = (data >> 0) & 15;
        for (int i = 0; i < 9; ++i) {
            if(ch[i].patch_number == 0) {
                ch[i].car.updatePG();
                ch[i].car.updateRKS();
                ch[i].car.updateEG();
            }
        }
        break;
    case 0x02:
        patches[0].KL = (data >> 6) & 3;
        patches[0].TL = (data >> 0) & 63;
        for (int i = 0; i < 9; ++i) {
            if (ch[i].patch_number == 0) {
                ch[i].mod.updateTLL();
            }
        }
        break;
    case 0x03:
        patches[1].KL = (data >> 6) & 3;
        patches[1].WF = (data >> 4) & 1;
        patches[0].WF = (data >> 3) & 1;
        patches[0].FB = (data >> 0) & 7;
        for (int i = 0; i < 9; ++i) {
            if (ch[i].patch_number == 0) {
                ch[i].mod.updateWF();
                ch[i].car.updateWF();
            }
        }
        break;
    case 0x04:
        patches[0].AR = (data >> 4) & 15;
        patches[0].DR = (data >> 0) & 15;
        for (int i = 0; i < 9; ++i) {
            if(ch[i].patch_number == 0) {
                ch[i].mod.updateEG();
            }
        }
        break;
    case 0x05:
        patches[1].AR = (data >> 4) & 15;
        patches[1].DR = (data >> 0) & 15;
        for (int i = 0; i < 9; ++i) {
            if (ch[i].patch_number == 0) {
                ch[i].car.updateEG();
            }
        }
        break;
    case 0x06:
        patches[0].SL = (data >> 4) & 15;
        patches[0].RR = (data >> 0) & 15;
        for (int i = 0; i < 9; ++i) {
            if (ch[i].patch_number == 0) {
                ch[i].mod.updateEG();
            }
        }
        break;
    case 0x07:
        patches[1].SL = (data >> 4) & 15;
        patches[1].RR = (data >> 0) & 15;
        for (int i = 0; i < 9; i++) {
            if (ch[i].patch_number == 0) {
                ch[i].car.updateEG();
            }
        }
        break;
    case 0x0e:
        update_rhythm_mode();
        if (data & 0x20) {
            if (data & 0x10) keyOn_BD();  else keyOff_BD();
            if (data & 0x08) keyOn_SD();  else keyOff_SD();
            if (data & 0x04) keyOn_TOM(); else keyOff_TOM();
            if (data & 0x02) keyOn_CYM(); else keyOff_CYM();
            if (data & 0x01) keyOn_HH();  else keyOff_HH();
        }
        update_key_status();

        ch[6].mod.updateAll();
        ch[6].car.updateAll();
        ch[7].mod.updateAll();
        ch[7].car.updateAll();
        ch[8].mod.updateAll();
        ch[8].car.updateAll();        
        break;

    case 0x10:  case 0x11:  case 0x12:  case 0x13:
    case 0x14:  case 0x15:  case 0x16:  case 0x17:
    case 0x18:
    {
        int cha = regis & 0x0F;
        ch[cha].setFnumber(data + ((reg[0x20 + cha] & 1) << 8));
        ch[cha].mod.updateAll();
        ch[cha].car.updateAll();
        break;
    }
    case 0x20:  case 0x21:  case 0x22:  case 0x23:
    case 0x24:  case 0x25:  case 0x26:  case 0x27:
    case 0x28:
    {
        int cha = regis & 0x0F;
        int fNum = ((data & 1) << 8) + reg[0x10 + cha];
        int block = (data >> 1) & 7;
        ch[cha].setFnumber(fNum);
        ch[cha].setBlock(block);
        ch[cha].setSustine((data >> 5) & 1);
        if (data & 0x10) {
            ch[cha].keyOn();
        } else {
            ch[cha].keyOff();
        }
        ch[cha].mod.updateAll();
        ch[cha].car.updateAll();
        update_key_status();
        update_rhythm_mode();
        break;
    }
    case 0x30: case 0x31: case 0x32: case 0x33: case 0x34:
    case 0x35: case 0x36: case 0x37: case 0x38: 
    {
        int cha = regis & 0x0F;
        int j = (data >> 4) & 15;
        int v = data & 15;
        if ((reg[0x0e] & 0x20) && (regis >= 0x36)) {
            switch(regis) {
            case 0x37:
                ch[7].mod.setVolume(j << 2);
                break;
            case 0x38:
                ch[8].mod.setVolume(j << 2);
                break;
            }
        } else { 
            ch[cha].setPatch(j);
        }
        ch[cha].setVol(v << 2);
        ch[cha].mod.updateAll();
        ch[cha].car.updateAll();
        break;
    }
    default:
        break;
    }
    checkMute();
}
