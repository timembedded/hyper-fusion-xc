------------------------------------------------------------------------
-- Copyright (C) 2024 Tim Brugman
--
--  This firmware is free code: you can redistribute it and/or modify
--  it under the terms of the GNU General Public License as published
--  by the Free Software Foundation, version 3
--
--  This firmware is distributed in the hope that it will be useful,
--  but WITHOUT ANY WARRANTY; without even the implied warranty of
--  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE
--  See the GNU General Public License for more details
--
--  You should have received a copy of the GNU General Public License
--  along with this program. If not, see https://www.gnu.org/licenses/
--
------------------------------------------------------------------------
-- SCC
------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity scc is
  port(
    -- clock and reset
    clock                 : in std_logic;
    slot_reset            : in std_logic;
    clkena_3m58           : in std_logic;

    -- Configuration
    SccEna                : in std_logic;

    -- avalon slave port
    mes_scc_read          : in std_logic;
    mes_scc_write         : in std_logic;
    mes_scc_address       : in std_logic_vector(15 downto 0);
    mes_scc_writedata     : in std_logic_vector(7 downto 0);
    mes_scc_readdata      : out std_logic_vector(7 downto 0);
    mes_scc_readdatavalid : out std_logic;
    mes_scc_waitrequest   : out std_logic;

    -- avalon master port
    mem_scc_read          : out std_logic;
    mem_scc_write         : out std_logic;
    mem_scc_address       : out std_logic_vector(15 downto 0);
    mem_scc_writedata     : out std_logic_vector(7 downto 0);
    mem_scc_readdata      : in std_logic_vector(7 downto 0);
    mem_scc_readdatavalid : in std_logic;
    mem_scc_waitrequest   : in std_logic;

    -- SCC mode registers
    EseScc_MA19           : out std_logic; -- EseScc_xxx was SccModeA
    EseScc_MA20           : out std_logic;
    SccPlus_Enable        : out std_logic; -- SccPlus_xxx was SccModeB
    SccPlus_AllRam        : out std_logic;
    SccPlus_B0Ram         : out std_logic;
    SccPlus_B1Ram         : out std_logic;
    SccPlus_B2Ram         : out std_logic;

    -- Audio output
    SccAmp                : out std_logic_vector(10 downto 0)
  );
end scc;

architecture rtl of scc is

  signal Dec1FFE     : std_logic;
  signal DecSccA     : std_logic;
  signal DecSccB     : std_logic;

  signal SccBank2    : std_logic_vector(7 downto 0);
  signal SccBank3    : std_logic_vector(7 downto 0);

  signal SccRegWe    : std_logic;
  signal SccModWe    : std_logic;
  signal SccWavRd    : std_logic;
  signal SccWavWe    : std_logic;
  signal SccWavWx    : std_logic;
  signal SccWavAdr   : std_logic_vector(4 downto 0);
  signal SccWavDatIn : std_logic_vector(7 downto 0);

  signal ssc_wave_readdata_i : std_logic_vector(7 downto 0);
  signal ssc_wave_readdatavalid_i : std_logic;

  signal MasterRd    : std_logic;
  signal MasterWr    : std_logic;
  signal MasterAdr   : std_logic_vector(15 downto 0);
  signal MasterDat   : std_logic_vector(7 downto 0);
  signal mes_scc_waitrequest_i : std_logic;

  signal EseScc_MA19_i        : std_logic; -- EseScc_xxx was SccModeA
  signal EseScc_MA20_i        : std_logic;
  signal SccPlus_Enable_i     : std_logic; -- SccPlus_xxx was SccModeB
  signal SccPlus_AllRam_i     : std_logic;
  signal SccPlus_B0Ram_i      : std_logic;
  signal SccPlus_B1Ram_i      : std_logic;
  signal SccPlus_B2Ram_i      : std_logic;

begin

  -- avalon slave port
  mes_scc_waitrequest_i <= MasterRd or MasterWr; -- do not accept new transfer if one is in progress
  mes_scc_waitrequest <= mes_scc_waitrequest_i;
  mes_scc_readdata <= ssc_wave_readdata_i when ssc_wave_readdatavalid_i = '1' else mem_scc_readdata;
  mes_scc_readdatavalid <= ssc_wave_readdatavalid_i or mem_scc_readdatavalid;

  -- avalon master port
  mem_scc_read <= MasterRd;
  mem_scc_write <= MasterWr;
  mem_scc_address <= MasterAdr;
  mem_scc_writedata <= MasterDat;

  -- Mode register outputs
  EseScc_MA19 <= EseScc_MA19_i;
  EseScc_MA20 <= EseScc_MA20_i;
  SccPlus_Enable <= SccPlus_Enable_i;
  SccPlus_AllRam <= SccPlus_AllRam_i;
  SccPlus_B0Ram  <= SccPlus_B0Ram_i;
  SccPlus_B1Ram  <= SccPlus_B1Ram_i;
  SccPlus_B2Ram  <= SccPlus_B2Ram_i;

  --------------------------------------------------------
  -- scc_wave
  --------------------------------------------------------

  scc_wave_i : entity work.scc_wave(rtl)
  port map (
    -- clock and reset
    clock         => clock,
    slot_reset    => slot_reset,
    clkena_3m58   => clkena_3m58,

    pSltAdr       => mes_scc_address(7 downto 0),
    pSltDat       => mes_scc_writedata,

    SccRegWe      => SccRegWe,
    SccModWe      => SccModWe,
    SccWavRd      => SccWavRd,
    SccWavWe      => SccWavWe,
    SccWavWx      => SccWavWx,
    SccWavAdr     => SccWavAdr,
    SccWavDatIn   => SccWavDatIn,
    SccWavDatVld  => ssc_wave_readdatavalid_i,
    SccWavDatOut  => ssc_wave_readdata_i,

    SccAmp        => SccAmp
 );

  ----------------------------------------------------------------
  -- Decode Cartrige
  ----------------------------------------------------------------

  Dec1FFE <= '1' when mes_scc_address(12 downto 1) = "111111111111" 
                 else '0';
  DecSccA <= '1' when mes_scc_address(15 downto 11) = "10011" and SccPlus_Enable_i = '0' and SccBank2(5 downto 0) = "111111"
                 else '0';
  DecSccB <= '1' when mes_scc_address(15 downto 11) = "10111" and SccPlus_Enable_i = '1' and SccBank3(7) = '1'
                 else '0';

  ----------------------------------------------------------------
  -- SCC register / wave memory access
  ----------------------------------------------------------------
  process(clock, slot_reset)
  begin
    if (slot_reset = '1') then

      SccBank2   <= "00000010";
      SccBank3   <= "00000011";
      EseScc_MA19_i <= '0';
      EseScc_MA20_i <= '0';
      SccPlus_Enable_i <= '0';
      SccPlus_AllRam_i <= '0';
      SccPlus_B0Ram_i <= '0';
      SccPlus_B1Ram_i <= '0';
      SccPlus_B2Ram_i <= '0';

      SccWavWx   <= '0';
      SccWavAdr  <= (others => '0');
      SccWavDatIn <= (others => '0');

    elsif rising_edge(clock) then

      MasterRd <= '0';
      MasterWr <= '0';
      SccWavRd <= '0';
      SccWavWe <= '0';
      SccRegWe <= '0';
      SccModWe <= '0';

      -- Keep master transfer in case of slave waitrequest
      if (MasterRd = '1' and mem_scc_waitrequest = '1') then
        MasterRd <= '1';
      end if;
      if (MasterWr = '1' and mem_scc_waitrequest = '1') then
        MasterWr <= '1';
      end if;

      if (SccEna = '0') then
        SccBank2 <= "00000010";
        SccBank3   <= "00000011";
        EseScc_MA19_i <= '0';
        EseScc_MA20_i <= '0';
        SccPlus_Enable_i <= '0';
        SccPlus_AllRam_i <= '0';
        SccPlus_B0Ram_i <= '0';
        SccPlus_B1Ram_i <= '0';
        SccPlus_B2Ram_i <= '0';

        MasterRd <= mes_scc_read and (not mes_scc_waitrequest_i);
        MasterAdr <= mes_scc_address;
        MasterWr <= mes_scc_write and (not mes_scc_waitrequest_i);
        MasterAdr <= mes_scc_address;
        MasterDat <= mes_scc_writedata;

      else
        -- Mapped I/O port access on 9000-97FFh ... Bank resister write
        if (mes_scc_write = '1' and mes_scc_address(15 downto 11) = "10010" and
            SccPlus_AllRam_i = '0') then
          SccBank2 <= mes_scc_writedata;
        end if;
        -- Mapped I/O port access on B000-B7FFh ... Bank resister write
        if (mes_scc_write = '1' and mes_scc_address(15 downto 11) = "10110" and
            EseScc_MA19_i = '0' and EseScc_MA20_i = '0' and SccPlus_AllRam_i = '0') then
          SccBank3 <= mes_scc_writedata;
        end if;

        -- Mapped I/O port access on 7FFE-7FFFh ... ESE-SCC resister write
        -- Bit 4 - bank control MA20 (B7)
        -- Bit 6 - bank control MA19 (B6)
        if (mes_scc_write = '1' and mes_scc_address(15 downto 13) = "011" and Dec1FFE = '1' and
            SccPlus_Enable_i = '0' and SccPlus_AllRam_i = '0') then
          EseScc_MA19_i <= mes_scc_writedata(6);
          EseScc_MA20_i <= mes_scc_writedata(4);
        end if;

        -- Mapped I/O port access on BFFE-BFFFh ... SCC+ mode resister write
        -- Bit 5 - Sound Mode (1 = SCC+, 0 = SCC)
        -- Bit 4 - Memory Mode (1 = all the pages in RAM mode, 0 = page A000h~BFFFh in ROM mode and others in mode determined by the bits 0~2)
        -- Bit 2 - Bank 8000h~9FFFh Mode (1 = RAM, 0 = bank select)
        -- Bit 1 - Bank 6000h~7FFFh Mode (1 = RAM, 0 = bank select)
        -- Bit 0 - Bank 4000h~5FFFh Mode (1 = RAM, 0 = bank select)
        if (mes_scc_write = '1' and mes_scc_address(15 downto 13) = "101" and Dec1FFE = '1' and
            EseScc_MA19_i = '0' and EseScc_MA20_i = '0') then
          SccPlus_B0Ram_i <= mes_scc_writedata(0);
          SccPlus_B1Ram_i <= mes_scc_writedata(1);
          SccPlus_B2Ram_i <= mes_scc_writedata(2);
          SccPlus_AllRam_i <= mes_scc_writedata(4);
          SccPlus_Enable_i <= mes_scc_writedata(5);
        end if;

        -- Mapped I/O port access on 9860-987Fh ... Wave memory copy
        if (mes_scc_write = '1' and mes_scc_address(7 downto 5) = "011" and
            SccPlus_AllRam_i = '0' and DecSccA = '1') then
          SccWavAdr <= mes_scc_address(4 downto 0);
          SccWavDatIn <= mes_scc_writedata;
          SccWavWx  <= '1';
        else
          SccWavWx  <= '0';
        end if;

        -- Mapped I/O port access on 9800-987Fh / B800-B89Fh ... Wave memory
        if (mes_scc_read = '1' and mes_scc_waitrequest_i = '0') then
          if SccPlus_AllRam_i = '0' and
             ((DecSccA = '1' and mes_scc_address(7) = '0') or
              (DecSccB = '1' and (mes_scc_address(7) = '0' or mes_scc_address(6 downto 5) = "00")))
          then
            SccWavRd <= '1';

          else
            -- Forward this read to the master port
            MasterRd <= '1';
            MasterAdr <= mes_scc_address;
          end if;
        end if;

        if (mes_scc_write = '1' and mes_scc_waitrequest_i = '0') then
          -- Mapped I/O port access on 9800-987Fh / B800-B89Fh ... Wave memory
          if SccPlus_AllRam_i = '0' and
             ((DecSccA = '1' and mes_scc_address(7) = '0') or DecSccB = '1')
          then
            SccWavWe <= '1';

          -- Mapped I/O port access on 9880-988Fh / B8A0-B8AF ... Resister write
          elsif SccEna = '1' and
             ((DecSccA = '1' and mes_scc_address(7 downto 5) = "100") or
             (DecSccB = '1' and mes_scc_address(7 downto 5) = "101")) and
             SccPlus_AllRam_i = '0'
          then
            SccRegWe <= '1';

          -- Mapped I/O port access on 98C0-98FFh / B8C0-B8DFh ... Resister write
          elsif mes_scc_address(7 downto 6) = "11" and
             (DecSccA = '1' or (mes_scc_address(5) = '0' and DecSccB = '1')) and
             SccPlus_AllRam_i = '0'
          then
            SccModWe <= '1';
          end if;

          -- Also forward writes to the master port
          MasterWr <= '1';
          MasterAdr <= mes_scc_address;
          MasterDat <= mes_scc_writedata;
        end if;
      end if;

    end if;
  end process;

end rtl;
