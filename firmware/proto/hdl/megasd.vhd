------------------------------------------------------------------------
-- Copyright (C) 2025 Tim Brugman
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
--  SD/MMC card interface
------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity megasd is
  port(
    -- Clock
    clock  : in std_logic;
    slot_reset   : in std_logic;

    -- Avalon slave ports
    mes_sd_read           : in std_logic;
    mes_sd_write          : in std_logic;
    mes_sd_address        : in std_logic_vector(15 downto 0);
    mes_sd_writedata      : in std_logic_vector(7 downto 0);
    mes_sd_readdata       : out std_logic_vector(7 downto 0);
    mes_sd_readdatavalid  : out std_logic;
    mes_sd_waitrequest    : out std_logic;

    -- rom master port
    rom_sd_read           : out std_logic;
    rom_sd_address        : out std_logic_vector(16 downto 0);
    rom_sd_readdata       : in std_logic_vector(7 downto 0);
    rom_sd_readdatavalid  : in std_logic;
    rom_sd_waitrequest    : in std_logic;

    mmc_ck  : out std_logic;
    mmc_cs  : out std_logic;
    mmc_di  : inout std_logic;
    mmc_do  : in std_logic
  );
end megasd;

architecture rtl of megasd is

  constant C_DIV_FACTOR : integer := 4;

  signal mmc_do_r  : std_logic;   -- fast input register

  type read_state_t is (RS_IDLE, RS_SD, RS_ROM);
  signal read_state_x, read_state_r : read_state_t;
  signal read_waitrequest_i : std_logic;
  signal write_waitrequest_i : std_logic;

  type xfer_state_t is (XS_IDLE, XS_SETUP, XS_RUN);
  signal xfer_state_x, xfer_state_r : xfer_state_t;

  signal ErmBank0    : std_logic_vector(7 downto 0);
  signal ErmBank1    : std_logic_vector(7 downto 0);
  signal ErmBank2    : std_logic_vector(7 downto 0);
  signal ErmBank3    : std_logic_vector(7 downto 0);

  signal mmc_cs_x, mmc_cs_r    : std_logic;
  signal mmc_ck_x, mmc_ck_r    : std_logic;
  signal mmc_di_x, mmc_di_r    : std_logic;
  signal mmc_oe_x, mmc_oe_r    : std_logic;

  signal mmcdbi_x, mmcdbi_r   : std_logic_vector(7 downto 0);
  signal mmcena_i             : std_logic;
  signal mmcact_x, mmcact_r   : std_logic;

  signal clkdiv_cnt  : integer range 0 to C_DIV_FACTOR-1;
  signal mmcclkena   : std_logic;

  signal xfer_read_i, xfer_write_i, xfer_chipselect_i : std_logic;
  signal xfer_writedata_i : std_logic_vector(7 downto 0);
  
  signal MmcMod_r           : std_logic_vector(1 downto 0);
  signal shift_in_x, shift_in_r : std_logic;
  signal MmcCs_x, MmcCs_r   : std_logic;
  signal MmcSeq_x, MmcSeq_r : unsigned(4 downto 0);
  signal MmcDbo_x, MmcDbo_r : std_logic_vector(7 downto 0);

begin

  mmc_cs <= mmc_cs_r;
  mmc_ck <= mmc_ck_r;
  mmc_di <= mmc_di_r when mmc_oe_r = '1' else 'Z';

  ----------------------------------------------------------------
  -- Clock for MMC
  ----------------------------------------------------------------
  process(clock)
  begin
    if rising_edge(clock) then
      if (slot_reset = '1') then
        clkdiv_cnt <= 0;
        mmcclkena <= '0';
      else
        if (clkdiv_cnt = C_DIV_FACTOR-1) then
          clkdiv_cnt <= 0;
          mmcclkena <= '1';
        else
          clkdiv_cnt <= clkdiv_cnt + 1;
          mmcclkena <= '0';
        end if;
      end if;
    end if;
  end process;

  ----------------------------------------------------------------
  -- Bank register write
  --
  -- Mapped I/O port access on 6000-7FFFh
  --
  -- ErmBank0
  --   [7..4] - Device select ("01XX" = MMC, "0110" = EPCS)
  --   [3..0] - Mapper 8k page (0-15) for 4000-5FFF
  -- ErmBank1
  --   [3..0] - Mapper 8k page (0-15) for 6000-7FFF
  -- ErmBank2
  --   [3..0] - Mapper 8k page (0-15) for 8000-9FFF
  -- ErmBank3
  --   [3..0] - Mapper 8k page (0-15) for A000-BFFF
  ----------------------------------------------------------------
  process(clock)
  begin
    if rising_edge(clock) then
      if (slot_reset = '1') then
        ErmBank0   <= X"00";
        ErmBank1   <= X"00";
        ErmBank2   <= X"00";
        ErmBank3   <= X"00";
      else
        -- Mapped I/O port access on 6000-7FFFh ... Bank register write
        if (mes_sd_write = '1' and mes_sd_address(15 downto 13) = "011") then -- 6000-7FFF
          case mes_sd_address(12 downto 11) is
            when "00"   => ErmBank0 <= mes_sd_writedata;
            when "01"   => ErmBank1 <= mes_sd_writedata;
            when "10"   => ErmBank2 <= mes_sd_writedata;
            when others => ErmBank3 <= mes_sd_writedata;
          end case;
        end if;
      end if;
    end if;
  end process;

  mmcena_i <= '1' when ErmBank0(7 downto 6) = "01" else '0';

  ----------------------------------------------------------------
  -- Mode register
  --
  -- Memory mapped I/O port access on 4000-57FFh
  --
  -- MmcMod_r
  --   [0] = '0' is MMC enabled
  --
  process(clock)
  begin
    if rising_edge(clock) then
      if (slot_reset = '1') then
        MmcMod_r <= "00";
      else
        if (mmcena_i = '1' and mes_sd_write = '1'
            and mes_sd_address(15 downto 13) = "010" -- 4000-5FFF
            and mes_sd_address(12 downto 11) = "11") -- exclude 5800-5FFF
        then
          MmcMod_r <= mes_sd_writedata(1 downto 0);
        end if;
      end if;
    end if;
  end process;

  --------------------------------------------------------
  -- Register/ROM read
  --------------------------------------------------------

  rom_sd_address <= ErmBank0(3 downto 0) & mes_sd_address(12 downto 0) when mes_sd_address(14 downto 13) = "10" else -- 4000-5FFF
                    ErmBank1(3 downto 0) & mes_sd_address(12 downto 0) when mes_sd_address(14 downto 13) = "11" else -- 6000-7FFF
                    ErmBank2(3 downto 0) & mes_sd_address(12 downto 0) when mes_sd_address(14 downto 13) = "00" else -- 8000-9FFF
                    ErmBank3(3 downto 0) & mes_sd_address(12 downto 0);                                              -- A000-BFFF

  mes_sd_waitrequest <= read_waitrequest_i or write_waitrequest_i;

  -- Read process
  process(all)
  begin
    read_state_x <= read_state_r;
    read_waitrequest_i <= '1';

    rom_sd_read <= '0';

    mes_sd_readdatavalid <= '0';
    mes_sd_readdata <= mmcdbi_r;

    xfer_read_i <= '0';

    case (read_state_r) is
      when RS_IDLE =>
        -- Accept transfers in this state only
        read_waitrequest_i <= '0';

        -- Memory mapped I/O port access on 4000-57FFh ... SD/MMC data register
        if (mes_sd_read = '1'
            and mes_sd_address(15 downto 13) = "010"  -- 4000-57FF
            and mes_sd_address(12 downto 11) /= "11"  -- exclude 5800-5FFF
            and mmcena_i = '1')
        then
          -- Start read transfer
          if (mmcact_r = '1') then
            -- Previous transfer busy, wait
            read_waitrequest_i <= '1';
          else
            xfer_read_i <= '1';
            read_state_x <= RS_SD;
          end if;
        
        -- ROM read
        elsif (mes_sd_read = '1') then
          -- Request ROM read
          rom_sd_read <= '1';
          if (rom_sd_waitrequest = '1') then
            read_waitrequest_i <= '1';
          else
            read_state_x <= RS_ROM;
          end if;
        end if;

      when RS_SD =>
        -- Read SD-Card
        -- Note that the PREVIOUS read result is returned, so always return data immediately
        mes_sd_readdatavalid <= '1';
        read_state_x <= RS_IDLE;

      when RS_ROM =>
        -- Read from flash, wait for datavalid
        mes_sd_readdata <= rom_sd_readdata;
        mes_sd_readdatavalid <= rom_sd_readdatavalid;
        if (rom_sd_readdatavalid = '1') then
          read_state_x <= RS_IDLE;
        end if;
    end case;
  end process;

  -- Write process
  process(all)
  begin
    xfer_write_i <= '0';
    write_waitrequest_i <= '0';

    xfer_writedata_i <= mes_sd_writedata;
    xfer_chipselect_i <= mes_sd_address(12);

    -- Memory mapped I/O port access on 4000-57FFh ... SD/MMC data register
    if (mmcena_i = '1' and mes_sd_write = '1'
        and mes_sd_address(15 downto 13) = "010"  -- 4000-57FF
        and mes_sd_address(12 downto 11) /= "11"  -- exclude 5800-5FFF
        and mmcena_i = '1')
    then
      if (mmcact_r = '1') then
        write_waitrequest_i <= '1';
      else
        xfer_write_i <= '1';
      end if;
    end if;
  end process;

  ----------------------------------------------------------------
  -- SD/MMC card access
  ----------------------------------------------------------------
  process(all)
  begin
    xfer_state_x <= xfer_state_r;
    shift_in_x <= '0';
    MmcCs_x <= MmcCs_r;
    MmcSeq_x <= MmcSeq_r;
    MmcDbo_x <= MmcDbo_r;
    mmcdbi_x <= mmcdbi_r;
    mmcact_x <= mmcact_r;
    mmc_cs_x <= mmc_cs_r;
    mmc_ck_x <= mmc_ck_r;
    mmc_di_x <= mmc_di_r;
    mmc_oe_x <= mmc_oe_r;

    ----------------------------------------------------------------
    -- Ouput
    ----------------------------------------------------------------

    if (mmcclkena = '1') then
      if (MmcSeq_r(0) = '0') then
        -- Output data
        case MmcSeq_r(4 downto 1) is
          when "1010" => mmc_oe_x <= '1'; mmc_di_x <= MmcDbo_r(7);
          when "1001" => mmc_oe_x <= '1'; mmc_di_x <= MmcDbo_r(6);
          when "1000" => mmc_oe_x <= '1'; mmc_di_x <= MmcDbo_r(5);
          when "0111" => mmc_oe_x <= '1'; mmc_di_x <= MmcDbo_r(4);
          when "0110" => mmc_oe_x <= '1'; mmc_di_x <= MmcDbo_r(3);
          when "0101" => mmc_oe_x <= '1'; mmc_di_x <= MmcDbo_r(2);
          when "0100" => mmc_oe_x <= '1'; mmc_di_x <= MmcDbo_r(1);
          when "0011" => mmc_oe_x <= '1'; mmc_di_x <= MmcDbo_r(0);
          when "0010" => mmc_oe_x <= '1'; mmc_di_x <= '1';
          when "0001" => mmc_oe_x <= '0'; mmc_di_x <= '1';
          when others => mmc_oe_x <= '0'; mmc_di_x <= '1';
        end case;
      end if;

      -- Output clock
      if (MmcSeq_r(4 downto 1) > "0010") then
        mmc_ck_x <= MmcSeq_r(0);
      else
        mmc_ck_x <= '1';
      end if;
    end if;

    ----------------------------------------------------
    -- Input
    ----------------------------------------------------

    if (mmcclkena = '1' and MmcSeq_r(0) = '0' and MmcSeq_r(4 downto 1) > "0001") then
      shift_in_x <= '1';
    end if;

    if (shift_in_r = '1') then
      mmcdbi_x(0) <= mmc_do_r;
      mmcdbi_x(mmcdbi_x'high downto 1) <= mmcdbi_r(mmcdbi_r'high-1 downto 0);
    end if;

    ----------------------------------------------------
    -- Transfer state machine
    ----------------------------------------------------

    case (xfer_state_r) is
    when XS_IDLE =>
      -- Not active, ready for new transfer
      mmcact_x <= '0';

      if (MmcMod_r(0) = '0' and (xfer_read_i = '1' or xfer_write_i = '1')) then
        -- Set pending request
        if (xfer_write_i = '1') then
          MmcDbo_x <= xfer_writedata_i;
        else
          MmcDbo_x <= (others => '1');
        end if;
        MmcCs_x <= xfer_chipselect_i;
        mmcact_x <= '1';
        xfer_state_x <= XS_SETUP;
      end if;

    when XS_SETUP =>
      -- Start new when pending
      if (mmcclkena = '1') then
        -- Start new transfer
        xfer_state_x <= XS_RUN;
        MmcSeq_x <= "10101";

        -- Set chipselect
        mmc_cs_x <= MmcCs_r;
      end if;

    when XS_RUN =>
      -- Continue current transfer
      if (mmcclkena = '1') then
        MmcSeq_x <= MmcSeq_r - 1;
        if (MmcSeq_x = "00000") then
          xfer_state_x <= XS_IDLE;
        end if;
      end if;
    end case;

  end process;

  ----------------------------------------------------------------
  -- Registers
  ----------------------------------------------------------------
  process(clock)
  begin
    if rising_edge(clock) then
      mmc_do_r <= mmc_do;
      if (slot_reset = '1') then
        read_state_r <= RS_IDLE;
        xfer_state_r <= XS_IDLE;
        shift_in_r <= '0';
        MmcSeq_r <= (others => '0');
        MmcDbo_r <= (others => '1');
        mmcdbi_r <= (others => '1');
        MmcCs_r <= '0';
        mmcact_r <= '0';
        mmc_cs_r <= '1';
        mmc_ck_r <= '1';
        mmc_di_r <= '1';
        mmc_oe_r <= '1'; 
      else
        read_state_r <= read_state_x;
        xfer_state_r <= xfer_state_x;
        shift_in_r <= shift_in_x;
        MmcSeq_r <= MmcSeq_x;
        MmcDbo_r <= MmcDbo_x;
        mmcdbi_r <= mmcdbi_x;
        MmcCs_r <= MmcCs_x;
        mmcact_r <= mmcact_x;
        mmc_cs_r <= mmc_cs_x;
        mmc_ck_r <= mmc_ck_x;
        mmc_di_r <= mmc_di_x;
        mmc_oe_r <= mmc_oe_x;
      end if;
    end if;
  end process;

end rtl;
