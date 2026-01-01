// $Id: OpenMsxY8950.h,v 1.3 2008/03/31 19:42:23 jancasper Exp $

#ifndef __Y8950_HH__
#define __Y8950_HH__

#include "Board.h"
#include "OpenMsxY8950Adpcm.h"

extern "C" {
#include "AudioMixer.h"
}

#define Y8950LogLevel_Debug    0
#define Y8950LogLevel_Info     1
#define Y8950LogLevel_Warning  2
#define Y8950LogLevel_Error    3

#define Y8950SelectedLogLevel  Y8950LogLevel_Warning

#define Y8950Log(level, ...) \
    do { \
        if (level >= Y8950SelectedLogLevel) { \
            printf(__VA_ARGS__); \
        } \
    } while (0)


#ifndef OPENMSX_SOUNDDEVICE
#define OPENMSX_SOUNDDEVICE

class SoundDevice
{
    public:
        SoundDevice() : internalMuted(true) {}
        void setVolume(short newVolume) {
            setInternalVolume(newVolume);
        }

    protected:
        virtual void setInternalVolume(short newVolume) = 0;
        void setInternalMute(bool muted) { internalMuted = muted; }
    public:
        bool isInternalMuted() const { return internalMuted; }
        virtual void setSampleRate(int newSampleRate, int Oversampling) = 0;
        virtual int* updateBuffer(int *buffer, int length) = 0;

    private:
        bool internalMuted;
};

#endif

// Dynamic range of envelope
static const double EG_STEP = 0.1875;
static const int EG_BITS = 9;
static const int EG_MUTE = 1<<EG_BITS;
// Dynamic range of sustine level
static const double SL_STEP = 3.0;
static const int SL_BITS = 4;
static const int SL_MUTE = 1<<SL_BITS;
// Size of Sintable ( 1 -- 18 can be used, but 7 -- 14 recommended.)
static const int PG_BITS = 10;
static const int PG_WIDTH = 1<<PG_BITS;
// Phase increment counter
static const int DP_BITS = 19;
static const int DP_WIDTH = 1<<DP_BITS;
static const int DP_BASE_BITS = DP_BITS - PG_BITS;
// Bits for envelope phase incremental counter
static const int EG_DP_BITS = 23;
static const int EG_DP_WIDTH = 1<<EG_DP_BITS;
// Dynamic range of total level
static const double TL_STEP = 0.75;
static const int TL_BITS = 6;
static const int TL_MUTE = 1<<TL_BITS;

static const double DB_STEP = 0.1875;
static const int DB_BITS = 9;
static const int DB_MUTE = 1<<DB_BITS;
// PM table is calcurated by PM_AMP * pow(2,PM_DEPTH*sin(x)/1200)
static const int PM_AMP_BITS = 8;
static const int PM_AMP = 1<<PM_AMP_BITS;



static const int CLK_FREQ = 3579545;
static const double PI = 3.14159265358979;
// PM speed(Hz) and depth(cent)
static const double PM_SPEED = 6.4;
static const double PM_DEPTH = (13.75/2);
static const double PM_DEPTH2 = 13.75;
// AM speed(Hz) and depth(dB)
static const double AM_SPEED = 3.7;
static const double AM_DEPTH = 1.0;
static const double AM_DEPTH2 = 4.8;
// Bits for liner value
static const int DB2LIN_AMP_BITS = 11;
static const int SLOT_AMP_BITS = DB2LIN_AMP_BITS;

// Bits for Pitch and Amp modulator
static const int PM_PG_BITS = 8;
static const int PM_PG_WIDTH = 1<<PM_PG_BITS;
static const int PM_DP_BITS = 16;
static const int PM_DP_WIDTH = 1<<PM_DP_BITS;
static const int AM_PG_BITS = 8;
static const int AM_PG_WIDTH = 1<<AM_PG_BITS;
static const int AM_DP_BITS = 16;
static const int AM_DP_WIDTH = 1<<AM_DP_BITS;

class Y8950 : public SoundDevice
{
    class Patch {
    public:
        Patch();
        void reset();

        bool AM, PM, EG;
        uint8_t KR; // 0-1
        uint8_t ML; // 0-15
        uint8_t KL; // 0-3
        uint8_t TL; // 0-63
        uint8_t FB; // 0-7
        uint8_t AR; // 0-15
        uint8_t DR; // 0-15
        uint8_t SL; // 0-15
        uint8_t RR; // 0-15
    };

    class Slot {
    public:
        Slot();
        ~Slot();
        void reset();

        static void makeSinTable();
        static void makeTllTable();
        static void makeAdjustTable();
        static void makeRksTable();
        static void makeDB2LinTable();
        static void makeDphaseARTable(int sampleRate);
        static void makeDphaseDRTable(int sampleRate);
        static void makeDphaseTable(int sampleRate);

        inline void slotOn();
        inline void slotOff();

        inline void calc_phase();
        inline void calc_envelope();
        inline int calc_slot_car(int fm);
        inline int calc_slot_mod();
        inline int calc_slot_tom();
        inline int calc_slot_snare(int whitenoise);
        inline int calc_slot_cym(int a, int b);
        inline int calc_slot_hat(int a, int b, int whitenoise);

        inline void updateAll();
        inline void updateEG();
        inline void updateRKS();
        inline void updateTLL();
        inline void updatePG();


        // OUTPUT
        int feedback;
        /** Output value of slot. */
        int output[5];

        // for Phase Generator (PG)
        /** Phase. */
        unsigned int phase;
        /** Phase increment amount. */
        unsigned int dphase;
        /** Output. */
        int pgout;

        // for Envelope Generator (EG)
        /** F-Number. */
        int fnum;
        /** Block. */
        int block;
        /** Total Level + Key scale level. */
        int tll;
        /** Key scale offset (Rks). */
        int rks;
        /** Current state. */
        int eg_mode;
        /** Phase. */
        unsigned int eg_phase;
        /** Phase increment amount. */
        unsigned int eg_dphase;
        /** Output. */
        int egout;

        bool slotStatus;
        Patch patch;

        // refer to Y8950->
        int *plfo_pm;
        int *plfo_am;

    private:
        static int lin2db(double d);
        inline static int wave2_4pi(int e);
        inline static int wave2_8pi(int e);

        #define ALIGN(d,SS,SD) ((int)d*(int)(SS/SD))

        struct slot_tables_t {
            /** WaveTable for each envelope amp. */
            int sintable[PG_WIDTH];
            /** Phase incr table for Attack. */
            unsigned int dphaseARTable[16][16];
            /** Phase incr table for Decay and Release. */
            unsigned int dphaseDRTable[16][16];
            /** KSL + TL Table. */
            int tllTable[16][8][1<<TL_BITS][4];
            int rksTable[2][8][2];
            /** Phase incr table for PG. */
            unsigned int dphaseTable[1024][8][16];
            /** Liner to Log curve conversion table (for Attack rate). */
            int AR_ADJUST_TABLE[1<<EG_BITS];
        };
        static slot_tables_t *slot_tables;
    };

    class Channel {
    public:
        Channel();
        ~Channel();
        void reset();
        inline void setFnumber(int fnum);
        inline void setBlock(int block);
        inline void keyOn();
        inline void keyOff();

        bool alg;
        Slot mod, car;
    };

public:
    Y8950(int sampleRam);
    virtual ~Y8950();

    void reset();
    void writeReg(uint8_t reg, uint8_t data);
    uint8_t readReg(uint8_t reg);
    uint8_t readStatus();
    
    virtual void setSampleRate(int sampleRate, int Oversampling);
    virtual int* updateBuffer(int *buffer, int length);
    
private:
    // SoundDevice
    virtual void setInternalVolume(short maxVolume);

    // Definition of envelope mode
    enum { ATTACK,DECAY,SUSHOLD,SUSTINE,RELEASE,FINISH };
    struct tables_t {
        // Dynamic range
        unsigned int dphaseNoiseTable[1024][8];
        // dB to Liner table
        short dB2LinTab[(2*DB_MUTE)*2];
    };
    static tables_t *tables;

    inline static int DB_POS(int x);
    inline static int DB_NEG(int x);
    inline static int HIGHBITS(int c, int b);
    inline static int LOWBITS(int c, int b);
    inline static int EXPAND_BITS(int x, int s, int d);
    static unsigned int rate_adjust(double x, int rate);

    void makeDphaseNoiseTable(int sampleRate);
    void makePmTable();
    void makeAmTable();

    inline void keyOn_BD();
    inline void keyOn_SD();
    inline void keyOn_TOM();
    inline void keyOn_HH();
    inline void keyOn_CYM();
    inline void keyOff_BD();
    inline void keyOff_SD();
    inline void keyOff_TOM();
    inline void keyOff_HH();
    inline void keyOff_CYM();
    inline void setRythmMode(int data);
    inline void update_noise();
    inline void update_ampm();

    inline void calcSample(int channelMask, int *voice, int *drum);
    void checkMute();
    bool checkMuteHelper();

    void setStatus(uint8_t flags);
    void resetStatus(uint8_t flags);
    void changeStatusMask(uint8_t newMask);

    int adr;
    int output[2];
    // Register
    uint8_t reg[0x100];
    bool rythm_mode;
    // Pitch Modulator
    int pm_mode;
    unsigned int pm_phase;
    // Amp Modulator
    int am_mode;
    unsigned int am_phase;

    // Noise Generator
    int noise_seed;
    int whitenoise;
    int noiseA;
    int noiseB;
    unsigned int noiseA_phase;
    unsigned int noiseB_phase;
    unsigned int noiseA_dphase;
    unsigned int noiseB_dphase;

    // Channel & Slot
    Channel ch[9];
    Slot *slot[18];

    // LFO Table
    int pmtable[2][PM_PG_WIDTH];
    int amtable[2][AM_PG_WIDTH];

    unsigned int pm_dphase;
    int lfo_pm;
    unsigned int am_dphase;
    int lfo_am;

    int maxVolume;

    // ADPCM
    Y8950Adpcm adpcm;
    friend class Y8950Adpcm;

    /** Keyboard connector. */
//  Y8950KeyboardConnector connector;

    /** 13-bit (exponential) DAC. */
//  DACSound16S dac13;
    
    //DAC stuff
    int dacSampleVolume;
    int dacOldSampleVolume;
    int dacSampleVolumeSum;
    int dacCtrlVolume;
    int dacDaVolume;
    int dacEnabled;
};

#endif
