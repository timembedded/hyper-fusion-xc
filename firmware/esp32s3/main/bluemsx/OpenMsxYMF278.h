// This file is taken from the openMSX project. 
// The file has been modified to be built in the blueMSX environment.

#ifndef __YMF278_HH__
#define __YMF278_HH__

#include <stdint.h>
#include <string>

using namespace std;

typedef unsigned long  EmuTime;

#ifndef OPENMSX_SOUNDDEVICE
#define OPENMSX_SOUNDDEVICE

#include "AudioMixer.h"

class SoundDevice
{
    public:
        SoundDevice() : internalMuted(true) {}
        void setVolume(int16_t newVolume) {
            setInternalVolume(newVolume);
        }

    protected:
        virtual void setInternalVolume(int16_t newVolume) = 0;
        void setInternalMute(bool muted) { internalMuted = muted; }
        bool isInternalMuted() const { return internalMuted; }
    public:
        virtual void setSampleRate(int newSampleRate, int Oversampling) = 0;
        virtual int* updateBuffer(int *buffer, int length) = 0;

    private:
        bool internalMuted;
};

#endif


class YMF278Slot
{
    public:
        YMF278Slot();
        void reset();
        int compute_rate(int val);
        unsigned int decay_rate(int num, int sample_rate);
        void envelope_next(int sample_rate);
        inline int compute_vib();
        inline int compute_am();
        void set_lfo(int newlfo);

        int16_t wave;     // wavetable number
        int16_t FN;       // f-number
        char OCT;       // octave
        char PRVB;      // pseudo-reverb
        char LD;        // level direct
        char TL;        // total level
        char pan;       // panpot
        char lfo;       // LFO
        char vib;       // vibrato
        char AM;        // AM level

        char AR;
        uint8_t AR_rate;
        uint8_t AR_shift;
        uint16_t AR_mask;
        uint8_t AR_select;
        char D1R;
        uint8_t D1R_rate;
        uint8_t D1R_shift;
        uint16_t D1R_mask;
        uint8_t D1R_select;
        int  DL;
        char D2R;
        uint8_t D2R_rate;
        uint8_t D2R_shift;
        uint16_t D2R_mask;
        uint8_t D2R_select;
        char RC;        // rate correction
        char RR;
        uint8_t RR_rate;
        uint8_t RR_shift;
        uint16_t RR_mask;
        uint8_t RR_select;
        uint8_t C5_rate;
        uint8_t C5_shift;
        uint16_t C5_mask;
        uint8_t C5_select;

        void update_AR();
        void update_D1R();
        void update_D2R();
        void update_RR();
        void update_C5();

        int step;               // fixed-point frequency step
        int stepptr;        // fixed-point pointer into the sample
        int pos;
        int16_t sample1, sample2;

        bool active;        // slot keyed on
        uint8_t bits;       // width of the samples
        union {
            uint8_t *sampleptr;
            uint16_t *sampleptr16;
        };
        int loopaddr;
        int endaddr;

        uint8_t state;
        int16_t env_vol;
        uint16_t env_vol_step;
        uint16_t env_vol_lim;

        bool lfo_active;
        int lfo_cnt;
        int lfo_idx;
        int lfo_step;
        int lfo_max;
};

static const int MASTER_CLK = 33868800;

class YMF278 : public SoundDevice
{
    public:
        YMF278(int ramSize, void* romData, int romSize);
        virtual ~YMF278();
        void reset();
        void writeRegOPL4(uint8_t reg, uint8_t data);
        uint8_t readRegOPL4(uint8_t reg);
        virtual void setSampleRate(int sampleRate, int Oversampling);
        virtual void setInternalVolume(int16_t newVolume);
        virtual int* updateBuffer(int *buffer, int length);

    private:
        uint8_t readMem(unsigned int address);
        void writeMem(unsigned int address, uint8_t value);
        int16_t getSample(YMF278Slot &op);
        void advance();
        void checkMute();
        bool anyActive();
        void keyOnHelper(YMF278Slot& slot);

        uint8_t* rom;
        uint8_t* ram;
        uint8_t* ram12bit;
        uint8_t* rom12bit;

        YMF278Slot slots[24];

        int ramSize;
        
        uint16_t eg_cnt;    // global envelope generator counter
        
        char wavetblhdr;
        char memmode;
        int memadr;

        int fm_l, fm_r;
        int pcm_l, pcm_r;

        uint32_t endRom;
        uint32_t endRam;

        // precalculated attenuation values with some marging for
        // enveloppe and pan levels
        int16_t volume[256 * 4];

        uint8_t regs[256];

        int vold[24];
};

#endif

