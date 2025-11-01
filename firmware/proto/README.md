HyperFusion-XC prototype based on Carnivore2 hardware
=====================================================

**_NOTE:_**  This is work in progress!

Based on modified Carnivore2 hardware, the following changes are made:
* CompactFlash removed, pins to be used for other functions
* Added SD-Card interface, uses only a few of the CompactFlash pins
* Added ESP-S3 module, connection done using the free pins of the CompactFlash

## Firmware design

- IDE removed, MegaSD instead. Use Nextor OCM rom

## I/O map

|Address|R/W|Description|
|:--|:--|:--|
|0x7C-0x7D|W|YM2413 (FM-PAC)|　　　　　　
|0x52|RW|Test register|
|0xF0 - 0xF3|RW|Carnivore2 configuration register|
|0xFC - 0xFF|RW|Memory mapper page select 0 - 3|

### Carnivore2 configuration register

The I/O address can be set to 0xF0, 0xF1, 0xF2 or 0xF3 by writing PFXN (see below).
Read will return 0xff by default but can also return the version and the slot number used for the card.

Write has the following meaning:

|Value|Description|
|:--|:--|
|"C"|Get version, read will return "2"|
|"R"|Enable control registers|
|"H"|Disable control registers|
|"S"|Get slot, read will return slot number ("1" or "2")|
|"0"|Set register base address to 0x0F80|
|"1"|Set register base address to 0x4F80|
|"2"|Set register base address to 0x8F80|
|"3"|Set register base address to 0xCF80|
|"A"|Set catrige main slot only (Not fully implemented, enables SSC only)|
|"M"|Set default subslot config|
|others|Set read-mode back to reading 0xff|

## Memory map subslot 0 - Mega-RAM/ROM mapper in Carnovore2-style

|Address|R/W|Description|
|:--|:--|:--|
|0x0000-0xFFFF|RW|Mappable to RAM or flash|
|0x4000|RW|Card detection register|
|0x0F80-0x0FBF|RW|Configuration registers when CardMDR[6..5] = 00|
|0x4F80-0x4FBF|RW|Configuration registers when CardMDR[6..5] = 01|
|0x8F80-0x8FBF|RW|Configuration registers when CardMDR[6..5] = 10|
|0xCF80-0xCFBF|RW|Configuration registers when CardMDR[6..5] = 11|

### Card detection register

The card detection register is always enabled and thus can always be used to detect the cartridge,
independent of the flash/ram mapping in this slot. To prevent conflicts the register is only accessible
after writing the sequence "c", "v", "2" to the address. After writing the sequence consecutive reads
from this register will return "C", "V", "2", then zeros. Writing an arbitrary value to the register
then closes the access again.

### Configuration registers

|Address|R/W|Name|Description|Implemented|
|:--|:--|:--|:--|:--|
|0x00|RW|CardMDR|Card configuration register|Yes|
||||bit 7    : disable is config registers|Yes|
||||bit 6..5 : address of config registers (00 = 0F80h, 01 = 4F80h, 10 = 8F80h, 11 = CF80h)|Yes|
||||bit 4    : enable SCC|Yes|
||||bit 3    : delayed reconfiguration (bank registers only)|Yes|
||||bit 2    : select activate bank configurations 0=of start/jmp0/rst0 1= read(400Xh)|No|
||||bit 1    : shadow BIOS in RAM|Yes|
||||bit 0    : disable read direct card vector port and card configuration registers|Yes|
|0x01|RW|AddrM0|Flash address A7..A0 for direct flash chip access|Yes|
|0x02|RW|AddrM1|Flash address A15..A8 for direct flash chip access|Yes|
|0x03|RW|AddrM2|Flash address A23..A16 for direct flash chip access|Yes|
|0x04|RW|DatM0|Flash data port for direct flash chip access|Yes|
|0x05|RW|AddrFR|Offset in flash to use for the mapper in multiples of 16 bytes|Yes|
|0x06-0x0B|RW|R1|Bank configuration registers 1|Yes|
|0x0C-0x11|RW|R2|Bank configuration registers 2|Yes|
|0x12-0x17|RW|R3|Bank configuration registers 3|Yes|
|0x18-0x1B|RW|R4|Bank configuration registers 4|Yes|
|0x1E|RW|MConf|Machine configuration register|Partially|
||||bit 7    : enable expand slot|Yes|
||||bit 6    : enable read mapper port (FCh, FDh, FEh, FFh)|No|
||||bit 5    : enable YM2413 (FM-Pack syntesizer)|No|
||||bit 4    : enable control MMM port (3C)|No|
||||bit 3    : enable x3 Expand slot FM Pack BIOS ROM|Yes|
||||bit 2    : enable x2 Expand slot MMM RAM mapper|Yes|
||||bit 1    : enable x1 Expand slot CF card disk interface|Yes|
||||bit 0    : enable x0 Expand slot SCC Cartridge|Yes|
|0x1F|RW|CardMDR|Card configuration register|Yes|
|0x23|RW|EEPROM|Direct EEPROM access|Yes|
||RW||bit 3    : Chipselect|Yes|
||RW||bit 2    : Clock|Yes|
||RW||bit 1    : Data bit to EEPROM|Yes|
||R||bit 0    : Data bit from EEPROM|Yes|
|0x35|RW|PFXN|I/O address selection (write f0h...f3h)|Yes|

### Bank configuration registers

|Address|R/W|Name|Description|
|:--|:--|:--|:--|
|0x00|RW|Mask|Mask A15..A8 for addressing the page select register (1 = use this address line, 0 = masked)|
|0x01|RW|Addr|Address A15..A8 campare value for addressing the page select register|
|0x02|RW|Reg|Page select register (also accessible via address configured in Mask and Addr)|
|0x03|RW|Mult|Page configuration register|
||||bit 7    : enable page register bank 1
||||bit 6    : mask A15 for page mapping of 8k banks (1 = use A15, 0 = A15 masked)
||||bit 5    : RAM (select RAM or atlernative ROM...)
||||bit 4    : enable write to bank
||||bit 3    : disable bank ( read and write )
||||bit 2..0 : bank size (111 = 64k, 110 = 32k, 101 = 16k, 100 = 8k, others = undefined)
|0x04|RW|MaskR|Mask for page select register 'Reg' (1 = use this bit, 0 = masked)|
|0x05|RW|AdrD|Address of bank|
||||bit 7..5 : address where bank is accesible (A15..A13)
||||bit 4..0 : reserved as A12..A8 for smaller banks than 8k

## Memory map subslot 1 - MegaSD (OCM)

To be described

## Memory map subslot 2 - Memory mapper

|Address|R/W|Description|
|:--|:--|:--|
|0x0000-0x3FFF|RW|Memory mapper page 0|
|0x4000-0x7FFF|RW|Memory mapper page 1|
|0x8000-0xBFFF|RW|Memory mapper page 2|
|0xC000-0xFFFF|RW|Memory mapper page 3|

## Memory map subslot 3 - FM-PAC

|Address|R/W|Description|
|:--|:--|:--|
|0x4000-0x7FFF|R|FM-PAC ROM|
|0x4000-0x7FFF|R|FM-PAC ROM|
|0x7FF4|W|Write YM2413 register port|
|0x7FF5|W|Write YM2413 data port|
|0x7FF6|RW|Activate OPLL I/O ports|
|0x7FF7|RW|ROM page|
