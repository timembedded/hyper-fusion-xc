// $Id: OpenMsxY8950Adpcm.h,v 1.2 2006/06/17 21:42:32 vincent_van_dam Exp $

#ifndef __Y8950ADPCM_HH__
#define __Y8950ADPCM_HH__

#include "MsxTypes.h"
#include <string>

#include "fifo.h"

using namespace std;

typedef unsigned long  EmuTime;
typedef unsigned char  uint8_t;
typedef unsigned short word;
typedef unsigned __int64 uint64;
class Y8950;

class Y8950Adpcm
{
public:
    Y8950Adpcm(Y8950& y8950, int sampleRam);
    virtual ~Y8950Adpcm();
    
    void reset();
    void setSampleRate(int sr);
    bool muted();
    void writeReg(uint8_t rg, uint8_t data);
    uint8_t readReg(uint8_t rg);
    int calcSample();
    
private:
    void schedule();
    void unschedule();
    int CLAP(int min, int x, int max);
    void restart();

    Y8950& y8950;

    int sampleRate;
    
    int ramSize;
    int startAddr;
    int stopAddr;
    int playAddr;
    int addrMask;
    int memPntr;
    bool romBank;
    uint8_t* ramBank;
    
    bool playing;
    int volume;
    word delta;
    unsigned int nowStep, step;
    int out, output;
    int diff;
    int nextLeveling;
    int sampleStep;
    int volumeWStep;
        
    uint8_t reg7;
    uint8_t reg15;

    fifo_t adpcmFifo;
    uint8_t fifoBuffer[1024];
};

#endif 
