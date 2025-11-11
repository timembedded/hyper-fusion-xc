------------------------------------------------------------------------
-- MSX slot address decoding
--
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
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity address_decoding is
  port(
    -- Clock
    clock                     : in std_logic;
    slot_reset                : in std_logic;

    -- Avalon memory slave
    mes_read                  : in std_logic;
    mes_write                 : in std_logic;
    mes_address               : in std_logic_vector(16 downto 0);
    mes_writedata             : in std_logic_vector(7 downto 0);
    mes_readdata              : out std_logic_vector(8 downto 0);
    mes_readdatavalid         : out std_logic;
    mes_waitrequest           : out std_logic;

    -- Avalon io slave
    ios_read                  : in std_logic;
    ios_write                 : in std_logic;
    ios_address               : in std_logic_vector(7 downto 0);
    ios_writedata             : in std_logic_vector(7 downto 0);
    ios_readdata              : out std_logic_vector(8 downto 0);
    ios_readdatavalid         : out std_logic;
    ios_waitrequest           : out std_logic;

    -- Functions
    test_reg                  : out std_logic_vector(7 downto 0);
    enable_expand             : in std_logic;
    enable_sd                 : in std_logic;
    enable_mapper             : in std_logic;
    enable_fmpac              : in std_logic;
    enable_scc                : in std_logic;

    -- ESP IPC
    iom_esp_read              : out std_logic;
    iom_esp_write             : out std_logic;
    iom_esp_address           : out std_logic_vector(7 downto 0);
    iom_esp_writedata         : out std_logic_vector(7 downto 0);
    iom_esp_readdata          : in std_logic_vector(8 downto 0);
    iom_esp_readdatavalid     : in std_logic;
    iom_esp_waitrequest       : in std_logic;

    -- Memory mapper
    mem_mapper_read           : out std_logic;
    mem_mapper_write          : out std_logic;
    mem_mapper_address        : out std_logic_vector(15 downto 0);
    mem_mapper_writedata      : out std_logic_vector(7 downto 0);
    mem_mapper_readdata       : in std_logic_vector(7 downto 0);
    mem_mapper_readdatavalid  : in std_logic;
    mem_mapper_waitrequest    : in std_logic;
    iom_mapper_read           : out std_logic;
    iom_mapper_write          : out std_logic;
    iom_mapper_address        : out std_logic_vector(1 downto 0);
    iom_mapper_writedata      : out std_logic_vector(7 downto 0);
    iom_mapper_readdata       : in std_logic_vector(7 downto 0);
    iom_mapper_readdatavalid  : in std_logic;
    iom_mapper_waitrequest    : in std_logic;

    -- SD
    mem_sd_read              : out std_logic;
    mem_sd_write             : out std_logic;
    mem_sd_address           : out std_logic_vector(15 downto 0);
    mem_sd_writedata         : out std_logic_vector(7 downto 0);
    mem_sd_readdata          : in std_logic_vector(7 downto 0);
    mem_sd_readdatavalid     : in std_logic;
    mem_sd_waitrequest       : in std_logic;

    -- FM-PAC
    mem_fmpac_read            : out std_logic;
    mem_fmpac_write           : out std_logic;
    mem_fmpac_address         : out std_logic_vector(13 downto 0);
    mem_fmpac_writedata       : out std_logic_vector(7 downto 0);
    mem_fmpac_readdata        : in std_logic_vector(7 downto 0);
    mem_fmpac_readdatavalid   : in std_logic;
    mem_fmpac_waitrequest     : in std_logic;
    iom_fmpac_write           : out std_logic;
    iom_fmpac_address         : out std_logic_vector(0 downto 0);
    iom_fmpac_writedata       : out std_logic_vector(7 downto 0);
    iom_fmpac_waitrequest     : in std_logic;

    -- SCC
    mem_scc_read              : out std_logic;
    mem_scc_write             : out std_logic;
    mem_scc_address           : out std_logic_vector(15 downto 0);
    mem_scc_writedata         : out std_logic_vector(7 downto 0);
    mem_scc_readdata          : in std_logic_vector(7 downto 0);
    mem_scc_readdatavalid     : in std_logic;
    mem_scc_waitrequest       : in std_logic;

    -- Mega-ram mapper
    iom_mega_read             : out std_logic;
    iom_mega_write            : out std_logic;
    iom_mega_address          : out std_logic_vector(1 downto 0);
    iom_mega_writedata        : out std_logic_vector(7 downto 0);
    iom_mega_readdata         : in std_logic_vector(7 downto 0);
    iom_mega_readdatavalid    : in std_logic;
    iom_mega_waitrequest      : in std_logic
);
end address_decoding;

architecture rtl of address_decoding is

  -- Functions
  signal enable_expand_r                        : std_logic;
  signal enable_sd_r                            : std_logic;
  signal enable_mapper_r                        : std_logic;
  signal enable_fmpac_r                         : std_logic;
  signal enable_scc_r                           : std_logic;

  -- Slot expander
  signal slot_expand_reg_x, slot_expand_reg_r   : std_logic_vector(7 downto 0);
  signal exp_select_i                           : std_logic_vector(3 downto 0);

  -- Chip select
  type mem_cs_t is (MEM_CS_NONE, MEM_CS_EXTREG, MEM_CS_MAPPER, MEM_CS_SD, MEM_CS_FMPAC, MEM_CS_SCC);
  type iom_cs_t is (IOM_CS_NONE, IOM_CS_MAPPER, IOM_CS_FMPAC, IOM_CS_MEGA, IOM_CS_TESTREG, IOM_CS_WAITREG, IOM_CS_DELAYREG);
  signal mem_read_x, mem_read_r                   : std_logic;
  signal mem_cs_i, mem_cs_read_x, mem_cs_read_r   : mem_cs_t;
  signal iom_cs_i, iom_cs_read_x, iom_cs_read_r   : iom_cs_t;

  -- Reads/writes
  signal mem_mapper_read_i                        : std_logic;
  signal mem_mapper_write_i                       : std_logic;
  signal iom_mapper_read_i                        : std_logic;
  signal iom_mapper_write_i                       : std_logic;

  signal mem_sd_read_i                            : std_logic;
  signal mem_sd_write_i                           : std_logic;

  signal mem_fmpac_read_i                         : std_logic;
  signal mem_fmpac_write_i                        : std_logic;
  signal iom_fmpac_write_i                        : std_logic;
  signal iom_mega_read_i                          : std_logic;
  signal iom_mega_write_i                         : std_logic;
  signal iom_testreg_write_i                      : std_logic;
  signal iom_esp_read_i                           : std_logic;
  signal iom_esp_write_i                          : std_logic;

  signal mem_scc_read_i                           : std_logic;
  signal mem_scc_write_i                          : std_logic;

   -- Avalon memory slave
  signal mes_readdata_x, mes_readdata_r           : std_logic_vector(8 downto 0);
  signal mes_readdatavalid_x, mes_readdatavalid_r : std_logic;
  signal mes_read_waitrequest_i                   : std_logic;
  signal mes_write_waitrequest_i                  : std_logic;

  -- Avalon io slave
  signal ios_readdata_x, ios_readdata_r           : std_logic_vector(8 downto 0);
  signal ios_readdatavalid_x, ios_readdatavalid_r : std_logic;
  signal ios_waitrequest_i                        : std_logic;

  -- Debug
  signal test_reg_x, test_reg_r                   : std_logic_vector(7 downto 0);
  signal delay_reg_x, delay_reg_r                 : std_logic_vector(7 downto 0);
  signal wait_reg_x, wait_reg_r                   : std_logic_vector(7 downto 0);
  signal test_delaycount_x, test_delaycount_r     : unsigned(7 downto 0);
  signal test_waitcount_x, test_waitcount_r       : unsigned(7 downto 0);

begin

  test_reg <= test_reg_r;

  -- Data out to slave ports
  mes_readdata <= mes_readdata_r;
  mes_readdatavalid <= mes_readdatavalid_r;
  mes_waitrequest <= mes_read_waitrequest_i or mes_write_waitrequest_i;
  ios_readdata <= ios_readdata_r;
  ios_readdatavalid <= ios_readdatavalid_r;
  ios_waitrequest <= ios_waitrequest_i;

  -- ESP IO
  iom_esp_read          <= iom_esp_read_i;
  iom_esp_write         <= iom_esp_write_i;
  iom_esp_address       <= ios_address(7 downto 0);
  iom_esp_writedata     <= ios_writedata;

  -- Memory mapper
  mem_mapper_read       <= mem_mapper_read_i;
  mem_mapper_write      <= mem_mapper_write_i;
  mem_mapper_address    <= mes_address(15 downto 0);
  mem_mapper_writedata  <= mes_writedata;
  iom_mapper_read       <= iom_mapper_read_i;
  iom_mapper_write      <= iom_mapper_write_i;
  iom_mapper_address    <= ios_address(1 downto 0);
  iom_mapper_writedata  <= ios_writedata;

  -- MegaSD
  mem_sd_read           <= mem_sd_read_i;
  mem_sd_write          <= mem_sd_write_i;
  mem_sd_address        <= mes_address(15 downto 0);
  mem_sd_writedata      <= mes_writedata;

  -- FM-Pac
  mem_fmpac_read        <= mem_fmpac_read_i;
  mem_fmpac_write       <= mem_fmpac_write_i;
  mem_fmpac_address     <= mes_address(13 downto 0);
  mem_fmpac_writedata   <= mes_writedata;
  iom_fmpac_write       <= iom_fmpac_write_i;
  iom_fmpac_address     <= ios_address(0 downto 0);
  iom_fmpac_writedata   <= ios_writedata;

  -- SCC
  mem_scc_read          <= mem_scc_read_i;
  mem_scc_write         <= mem_scc_write_i;
  mem_scc_address       <= mes_address(15 downto 0);
  mem_scc_writedata     <= mes_writedata;

  -- Mega mapper
  iom_mega_read         <= iom_mega_read_i;
  iom_mega_write        <= iom_mega_write_i;
  iom_mega_address      <= ios_address(1 downto 0);
  iom_mega_writedata    <= ios_writedata;


  --------------------------------------------------------------------
  -- Test register
  --------------------------------------------------------------------

  test_reg_x <= ios_writedata when ios_write = '1' and iom_testreg_write_i = '1' and ios_waitrequest_i = '0' else
                test_reg_r;
  delay_reg_x <= ios_writedata when ios_write = '1' and iom_cs_i = IOM_CS_DELAYREG else
                 delay_reg_r;
  wait_reg_x <= ios_writedata when ios_write = '1' and iom_cs_i = IOM_CS_WAITREG else
                 wait_reg_r;

  --------------------------------------------------------------------
  -- Functions
  --------------------------------------------------------------------

  enable_expand_r <= enable_expand when rising_edge(clock);
  enable_sd_r <= enable_sd when rising_edge(clock);
  enable_mapper_r <= enable_mapper when rising_edge(clock);
  enable_fmpac_r <= enable_fmpac when rising_edge(clock);
  enable_scc_r <= enable_scc when rising_edge(clock);

  --------------------------------------------------------------------
  -- Slot expander
  --------------------------------------------------------------------

  slot_expand_reg_x <= mes_writedata when mes_write = '1' and mes_address(15 downto 0) = x"ffff" else
                       slot_expand_reg_r;

  exp_select_i(0) <= '1' when enable_expand_r = '0' else
                     '1' when (mes_address(16 downto 14) = "000" and slot_expand_reg_r(1 downto 0) = "00") else
                     '1' when (mes_address(16 downto 14) = "001" and slot_expand_reg_r(3 downto 2) = "00") else
                     '1' when (mes_address(16 downto 14) = "010" and slot_expand_reg_r(5 downto 4) = "00") else
                     '1' when (mes_address(16 downto 14) = "011" and slot_expand_reg_r(7 downto 6) = "00") else '0';

  exp_select_i(1) <= '1' when enable_expand_r = '0' else
                     '1' when (mes_address(16 downto 14) = "000" and slot_expand_reg_r(1 downto 0) = "01") else
                     '1' when (mes_address(16 downto 14) = "001" and slot_expand_reg_r(3 downto 2) = "01") else
                     '1' when (mes_address(16 downto 14) = "010" and slot_expand_reg_r(5 downto 4) = "01") else
                     '1' when (mes_address(16 downto 14) = "011" and slot_expand_reg_r(7 downto 6) = "01") else '0';

  exp_select_i(2) <= '1' when enable_expand_r = '0' else
                     '1' when (mes_address(16 downto 14) = "000" and slot_expand_reg_r(1 downto 0) = "10") else
                     '1' when (mes_address(16 downto 14) = "001" and slot_expand_reg_r(3 downto 2) = "10") else
                     '1' when (mes_address(16 downto 14) = "010" and slot_expand_reg_r(5 downto 4) = "10") else
                     '1' when (mes_address(16 downto 14) = "011" and slot_expand_reg_r(7 downto 6) = "10") else '0';

  exp_select_i(3) <= '1' when enable_expand_r = '0' else
                     '1' when (mes_address(16 downto 14) = "000" and slot_expand_reg_r(1 downto 0) = "11") else
                     '1' when (mes_address(16 downto 14) = "001" and slot_expand_reg_r(3 downto 2) = "11") else
                     '1' when (mes_address(16 downto 14) = "010" and slot_expand_reg_r(5 downto 4) = "11") else
                     '1' when (mes_address(16 downto 14) = "011" and slot_expand_reg_r(7 downto 6) = "11") else '0';


  --------------------------------------------------------------------
  -- Memory chipselects
  --------------------------------------------------------------------

  -- Address decoding
  mem_chipselect : process(all)
  begin
    if (enable_expand_r = '1' and mes_address(16) = '0' and mes_address(15 downto 0) = x"ffff") then
      mem_cs_i <= MEM_CS_EXTREG;
    elsif (exp_select_i(0) = '1' and (mes_address(15 downto 14) = "01" or mes_address(15 downto 14) = "10") and enable_scc_r = '1') then
      mem_cs_i <= MEM_CS_SCC;
    -- SSC in 2nd slot
    elsif (mes_address(16) = '1' and (mes_address(15 downto 14) = "01" or mes_address(15 downto 14) = "10") and enable_scc_r = '1') then
      mem_cs_i <= MEM_CS_SCC;
    elsif (exp_select_i(1) = '1' and mes_address(15 downto 14) = "01" and enable_sd_r = '1') then
      mem_cs_i <= MEM_CS_SD;
    elsif (exp_select_i(2) = '1' and enable_mapper_r = '1') then
      mem_cs_i <= MEM_CS_MAPPER;
    elsif (exp_select_i(3) = '1' and mes_address(15 downto 14) = "01" and enable_fmpac_r = '1') then
      mem_cs_i <= MEM_CS_FMPAC;
    else
      mem_cs_i <= MEM_CS_NONE;
    end if;
  end process;

  -- Read
  mem_chipselect_read : process(all)
  begin
    -- Read signals
    mem_mapper_read_i <= '0';
    mem_fmpac_read_i <= '0';
    mem_sd_read_i <= '0';
    mem_scc_read_i <= '0';
    mem_read_x <= '0';

    -- Read signals and waitrequest
    case (mem_cs_i) is
      when MEM_CS_MAPPER =>
        mem_mapper_read_i <= mes_read;
        mes_read_waitrequest_i <= mem_mapper_waitrequest;
      when MEM_CS_SD =>
        mem_sd_read_i <= mes_read;
        mes_read_waitrequest_i <= mem_sd_waitrequest;
      when MEM_CS_FMPAC =>
        mem_fmpac_read_i <= mes_read;
        mes_read_waitrequest_i <= mem_fmpac_waitrequest;
      when MEM_CS_SCC =>
        mem_scc_read_i <= mes_read;
        mes_read_waitrequest_i <= mem_scc_waitrequest;
      when others =>
        mes_read_waitrequest_i <= '0';
    end case;

    -- Read chipselect state
    if (mes_read = '1' and mes_read_waitrequest_i = '0') then
      mem_cs_read_x <= mem_cs_i;
      mem_read_x <= '1';
    elsif (mes_readdatavalid_r = '1') then
      -- return data, can accept new transfer next clock
      mem_cs_read_x <= MEM_CS_NONE;
    else
      -- no active chipselect, keep current state
      mem_cs_read_x <= mem_cs_read_r;
    end if;

    -- Read multiplexer
    mes_readdata_x <= "0--------";
    mes_readdatavalid_x <= '0';
    case (mem_cs_read_r) is
      when MEM_CS_EXTREG =>
        -- ALL SLOTS -> Slot expander
        mes_readdatavalid_x <= '1';
        mes_readdata_x <= '1' & (not slot_expand_reg_r);
      when MEM_CS_MAPPER =>
        -- Memory mapper
        if (mem_mapper_readdatavalid = '1') then
          mes_readdatavalid_x <= '1';
          mes_readdata_x <= '1' & mem_mapper_readdata;
        end if;
      when MEM_CS_SD =>
        -- MegaSD
        if (mem_sd_readdatavalid = '1') then
          mes_readdatavalid_x <= '1';
          mes_readdata_x <= '1' & mem_sd_readdata;
        end if;
      when MEM_CS_FMPAC =>
        -- FM-Pac
        if (mem_fmpac_readdatavalid = '1') then
          mes_readdatavalid_x <= '1';
          mes_readdata_x <= '1' & mem_fmpac_readdata;
        end if;
      when MEM_CS_SCC =>
        -- SCC
        if (mem_scc_readdatavalid = '1') then
          mes_readdatavalid_x <= '1';
          mes_readdata_x <= '1' & mem_scc_readdata;
        end if;
      when others =>
        mes_readdatavalid_x <= mem_read_r;
    end case;
  end process;

  -- Write
  mem_chipselect_write : process(all)
  begin
    mes_write_waitrequest_i <= '0';

    -- write signals
    mem_mapper_write_i <= '0';
    mem_fmpac_write_i <= '0';
    mem_sd_write_i <= '0';
    mem_scc_write_i <= '0';

    -- create write signals
    if (mes_write = '1' and mem_cs_i = MEM_CS_MAPPER) then
      -- Memory mapper
      mem_mapper_write_i <= '1';
      mes_write_waitrequest_i <= mem_mapper_waitrequest;
    elsif (mes_write = '1' and mem_cs_i = MEM_CS_SD) then
      -- MegaSD
      mem_sd_write_i <= '1';
      mes_write_waitrequest_i <= mem_sd_waitrequest;
    elsif (mes_write = '1' and mem_cs_i = MEM_CS_FMPAC) then
      -- FM-Pack
      mem_fmpac_write_i <= '1';
      mes_write_waitrequest_i <= mem_fmpac_waitrequest;
    elsif (mes_write = '1' and mem_cs_i = MEM_CS_SCC) then
      -- SCC
      mem_scc_write_i <= '1';
      mes_write_waitrequest_i <= mem_scc_waitrequest;
    end if;
  end process;


  --------------------------------------------------------------------
  -- I/O chipselects
  --------------------------------------------------------------------

  -- Address decoding
  iom_chipselect : process(all)
  begin
    if (ios_address(7 downto 2) = "1111"&"11" and enable_mapper_r = '1') then
      -- 0xFC - 0xFF
      iom_cs_i <= IOM_CS_MAPPER;
    elsif (ios_address(7 downto 1) = "0111"&"110" and enable_fmpac_r = '1') then
      -- 0x7C - 0x7D
      iom_cs_i <= IOM_CS_FMPAC;
    elsif (ios_address(7 downto 2) = "1111"&"00") then
      -- 0xF0 - 0xF3
      iom_cs_i <= IOM_CS_MEGA;
    elsif (ios_address = x"52") then
      iom_cs_i <= IOM_CS_TESTREG;
    elsif (ios_address = x"53") then
      iom_cs_i <= IOM_CS_WAITREG;
    elsif (ios_address = x"54") then
      iom_cs_i <= IOM_CS_DELAYREG;
    else
      iom_cs_i <= IOM_CS_NONE;
    end if;
  end process;

  -- Read
  iom_chipselect_read : process(all)
  begin
    -- Read signals
    iom_mapper_read_i <= '0';
    iom_mega_read_i <= '0';
    iom_esp_read_i <= '0';

    test_delaycount_x <= test_delaycount_r;
    test_waitcount_x <= test_waitcount_r;

    -- Wait counter (read and write)
    if (ios_read = '1' or ios_write = '1') then
      if (test_waitcount_r /= 0) then
        test_waitcount_x <= test_waitcount_r - 1;
      end if;
    else
      test_waitcount_x <= unsigned(wait_reg_r);
    end if;

    -- Read delay counter
    if (ios_read = '1' and ios_waitrequest_i = '0') then
      test_delaycount_x <= unsigned(delay_reg_r);
    else
      if (test_delaycount_r /= 0) then
        test_delaycount_x <= test_delaycount_r - 1;
      end if;
    end if;

    -- I/O read signals and waitrequest
    case (iom_cs_i) is
      when IOM_CS_MAPPER =>
        iom_mapper_read_i <= ios_read;
        ios_waitrequest_i <= iom_mapper_waitrequest;
      when IOM_CS_FMPAC =>
        ios_waitrequest_i <= iom_fmpac_waitrequest;
      when IOM_CS_MEGA =>
        iom_mega_read_i <= ios_read;
        ios_waitrequest_i <= iom_mega_waitrequest;
      when IOM_CS_TESTREG =>
        if (test_waitcount_r /= 0) then
          ios_waitrequest_i <= '1';
        else
          ios_waitrequest_i <= '0';
        end if;
      when others =>
        iom_esp_read_i <= ios_read;
        ios_waitrequest_i <= iom_esp_waitrequest;
    end case;

    -- Read chipselect state
    if (ios_read = '1' and ios_waitrequest_i = '0') then
      iom_cs_read_x <= iom_cs_i;
    elsif (ios_readdatavalid_r = '1') then
      -- return data, can accept new transfer next clock
      iom_cs_read_x <= IOM_CS_NONE;
    else
      -- keep current state
      iom_cs_read_x <= iom_cs_read_r;
    end if;

    -- Read multiplexer
    ios_readdata_x <= "0--------";
    ios_readdatavalid_x <= '0';
    case (iom_cs_read_r) is
      when IOM_CS_MAPPER =>
        -- Memory mapper
        ios_readdata_x <= '1' & iom_mapper_readdata;
        ios_readdatavalid_x <= iom_mapper_readdatavalid;
      when IOM_CS_MEGA =>
        -- Mega-ram mapper
        ios_readdata_x <= '1' & iom_mega_readdata;
        ios_readdatavalid_x <= iom_mega_readdatavalid;
      when IOM_CS_TESTREG =>
        -- Test register
        if (test_delaycount_r = 0) then
          ios_readdata_x <= '1' & test_reg_r;
          ios_readdatavalid_x <= '1';
        end if;
      when IOM_CS_DELAYREG =>
        ios_readdata_x <= '1' & delay_reg_r;
        ios_readdatavalid_x <= '1';
      when IOM_CS_WAITREG =>
        ios_readdata_x <= '1' & wait_reg_r;
        ios_readdatavalid_x <= '1';
      when others =>
        ios_readdata_x <= iom_esp_readdata;
        ios_readdatavalid_x <= iom_esp_readdatavalid;
    end case;
  end process;

  -- Write
  iom_chipselect_write : process(all)
  begin
    -- write signals
    iom_mapper_write_i <= '0';
    iom_fmpac_write_i <= '0';
    iom_mega_write_i <= '0';
    iom_testreg_write_i <= '0';
    iom_esp_write_i <= '0';

    -- create write signals
    if (ios_write = '1' and iom_cs_i = IOM_CS_MAPPER) then
      -- 0xFC - 0xFF
      iom_mapper_write_i <= '1';
    elsif (ios_write = '1' and iom_cs_i = IOM_CS_FMPAC) then
      -- 0x7C - 0x7D
      iom_fmpac_write_i <= '1';
    elsif (ios_write = '1' and iom_cs_i = IOM_CS_MEGA) then
      -- 0xF0 - 0xF3
      iom_mega_write_i <= '1';
    elsif (ios_write = '1' and iom_cs_i = IOM_CS_TESTREG) then
      iom_testreg_write_i <= '1';
    else
      iom_esp_write_i <= ios_write;
    end if;
  end process;


  --------------------------------------------------------------------
  -- Registers
  --------------------------------------------------------------------
  process(clock)
  begin
    if rising_edge(clock) then
      if slot_reset = '1' then
        slot_expand_reg_r <= x"00";
        mem_read_r <= '0';
        mem_cs_read_r <= MEM_CS_NONE;
        iom_cs_read_r <= IOM_CS_NONE;
        -- Debug
        test_reg_r <= x"00";
        delay_reg_r <= x"00";
        wait_reg_r <= x"00";
        test_delaycount_r <= x"00";
        test_waitcount_r <= x"00";
      else
        -- internal registers
        slot_expand_reg_r <= slot_expand_reg_x;
        -- chipselects
        mem_read_r <= mem_read_x;
        mem_cs_read_r <= mem_cs_read_x;
        iom_cs_read_r <= iom_cs_read_x;
        -- Avalon memory slave
        mes_readdata_r <= mes_readdata_x;
        mes_readdatavalid_r <= mes_readdatavalid_x;
        -- Avalon io slave
        ios_readdata_r <= ios_readdata_x;
        ios_readdatavalid_r <= ios_readdatavalid_x;
        -- Debug
        test_reg_r <= test_reg_x;
        delay_reg_r <= delay_reg_x;
        wait_reg_r <= wait_reg_x;
        test_delaycount_r <= test_delaycount_x;
        test_waitcount_r <= test_waitcount_x;
      end if;
    end if;
  end process;

end rtl;
