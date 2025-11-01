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
-- FM-PAC
------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity fmpac is
  port(
    -- clock and reset
    clock       : in std_logic;
    slot_reset  : in std_logic;
    clkena_3m58 : in std_logic;

    -- avalon slave ports
    mes_fmpac_read           : in std_logic;
    mes_fmpac_write          : in std_logic;
    mes_fmpac_address        : in std_logic_vector(13 downto 0);
    mes_fmpac_writedata      : in std_logic_vector(7 downto 0);
    mes_fmpac_readdata       : out std_logic_vector(7 downto 0);
    mes_fmpac_readdatavalid  : out std_logic;
    mes_fmpac_waitrequest    : out std_logic;
    ios_fmpac_write          : in std_logic;
    ios_fmpac_address        : in std_logic_vector(0 downto 0);
    ios_fmpac_writedata      : in std_logic_vector(7 downto 0);
    ios_fmpac_waitrequest    : out std_logic;

    -- rom master port
    rom_fmpac_read           : out std_logic;
    rom_fmpac_address        : out std_logic_vector(13 downto 0);
    rom_fmpac_readdata       : in std_logic_vector(7 downto 0);
    rom_fmpac_readdatavalid  : in std_logic;
    rom_fmpac_waitrequest    : in std_logic;

    -- Audio output
    BCMO    : out std_logic_vector(15 downto 0);
    BCRO    : out std_logic_vector(15 downto 0);
    SDO     : out std_logic
);
end fmpac;

architecture RTL of fmpac is

  type read_state_t is (RS_IDLE, RS_SRAM, RS_ROM);
  signal read_state_x, read_state_r : read_state_t;
  signal read_waitrequest_i : std_logic;

  signal mes_fmpac_readdatavalid_r, mes_fmpac_readdatavalid_x : std_logic;
  signal mes_fmpac_readdata_r, mes_fmpac_readdata_x           : std_logic_vector(7 downto 0);

  signal pYM2413_CS : std_logic;
  signal pYM2413_A  : std_logic;
  signal pYM2413_D  : std_logic_vector(7 downto 0);
  signal ym2413_waitrequest_i : std_logic;

  -- FM Pack
  signal R7FF6b0 : std_logic;
  signal R7FF6b4 : std_logic;
  signal CsRAM8k  : std_logic;
  signal R7FF7    : std_logic_vector(1 downto 0);
  signal R5FFE    : std_logic_vector(7 downto 0);
  signal R5FFF    : std_logic_vector(7 downto 0);  

  -- SRAM
  signal ram8k_a : std_logic_vector(12 downto 0);
  signal ram8k_d : std_logic_vector(7 downto 0);
  signal ram8k_q : std_logic_vector(7 downto 0);
  signal ram8k_wr : std_logic;

begin

  --------------------------------------------------------
  -- OPLL
  --------------------------------------------------------

  opll_i : entity work.opll(rtl)
  port map (
    XIN  => clock,
    XOUT => open,
    XENA => clkena_3m58,
    D    => pYM2413_D,
    A    => pYM2413_A,
    CS_n => not pYM2413_CS,
    WE_n => '0',
    IC_n => not slot_reset,
    MO   => open,
    RO   => open,
    BCMO => BCMO,
    BCRO => BCRO,
    SDO  => SDO
  );

  --------------------------------------------------------
  -- Address decoding
  --------------------------------------------------------
  --  7FF4h: write YM-2413 register port (write only)
  --  7FF5h: write YM-2413 data port (write only)
  --  7FF6h: activate OPLL I/O ports (read/write)
  --  7FF7h: ROM page (read/write)
  --  4Dh to 5FFEh and 69h to 5FFFh. Now 8kB SRAM is active in 4000h - 5FFFh 

  CsRAM8k <= '1' when mes_fmpac_address(13) = '0' and R5FFE = x"4D" and R5FFF = x"69" else '0';

  pYM2413_CS <= '1' when ios_fmpac_write = '1' else
                '1' when (mes_fmpac_write = '1' and mes_fmpac_address(13 downto 1) = "11"&"1111"&"1111"&"010" and R7FF6b0 = '1') else '0';

  pYM2413_A <= ios_fmpac_address(0) when ios_fmpac_write = '1' else mes_fmpac_address(0);
  pYM2413_D <= ios_fmpac_writedata when ios_fmpac_write = '1' else mes_fmpac_writedata;

  ym2413_waitrequest_i <= '1' when ios_fmpac_write = '1' and pYM2413_CS = '1' and clkena_3m58 = '0' else '0';

  --------------------------------------------------------
  -- RAM 8k
  --------------------------------------------------------

  ram8k_a <= mes_fmpac_address(12 downto 0);
  ram8k_d <= mes_fmpac_writedata;
  ram8k_wr <= '1' when CsRAM8k = '1' and mes_fmpac_write = '1' else '0';

  process(clock)
    type ram_t is array (0 to 8191) of std_logic_vector(7 downto 0);
    variable ram : ram_t;
  begin
    if rising_edge(clock) then
      -- write
      if (ram8k_wr = '1') then
        ram(to_integer(unsigned(ram8k_a))) := ram8k_d;
      end if;
      -- read
      ram8k_q <= ram(to_integer(unsigned(ram8k_a)));
    end if;
  end process;

  --------------------------------------------------------
  -- Register write
  --------------------------------------------------------

  ios_fmpac_waitrequest <= ym2413_waitrequest_i;

  process(clock, slot_reset)
  begin
    if rising_edge(clock) then
      if (slot_reset = '1') then
        R7FF6b0 <= '0' ;
        R7FF6b4 <= '1' ;
        R7FF7 <= "00" ;
        R5FFE <= "00000000" ;
        R5FFF <= "00000000" ;
      elsif (mes_fmpac_write = '1') then
        if (mes_fmpac_address = "11"&"1111"&"1111"&"0110") then
          R7FF6b0 <= mes_fmpac_writedata(0);
          R7FF6b4 <= mes_fmpac_writedata(4);
        end if;
        if (mes_fmpac_address = "11"&"1111"&"1111"&"0111") then
          R7FF7 <= mes_fmpac_writedata(1 downto 0);
        end if;
        if (mes_fmpac_address = "01"&"1111"&"1111"&"1110") then
          R5FFE <= mes_fmpac_writedata(7 downto 0);
        end if;
        if (mes_fmpac_address = "01"&"1111"&"1111"&"1111") then
          R5FFF <= mes_fmpac_writedata(7 downto 0);
        end if;
      end if;
    end if;
  end process;

  --------------------------------------------------------
  -- Register/ROM read
  --------------------------------------------------------

  rom_fmpac_address <= mes_fmpac_address;

  mes_fmpac_waitrequest <= read_waitrequest_i or ym2413_waitrequest_i;

  process(all)
  begin
    read_waitrequest_i <= '1';
    read_state_x <= read_state_r;
    rom_fmpac_read <= '0';
    mes_fmpac_readdata_x <= (others => '0');
    mes_fmpac_readdatavalid_x <= '0';

    case (read_state_r) is
      when RS_IDLE =>
        -- Accept tarnsfers in this state
        read_waitrequest_i <= '0';

        mes_fmpac_readdatavalid <= mes_fmpac_readdatavalid_r;
        mes_fmpac_readdata <= mes_fmpac_readdata_r;

        -- Decode requests
        if (mes_fmpac_address = "11"&"1111"&"1111"&"0110") then
          -- Register 7FF6
          mes_fmpac_readdatavalid_x <= '1';
          mes_fmpac_readdata_x <= "000" & R7FF6b4 & "000" & R7FF6b0;
        elsif (mes_fmpac_address = "11"&"1111"&"1111"&"0111") then
          -- Register 7FF7
          mes_fmpac_readdatavalid_x <= '1';
          mes_fmpac_readdata_x <= "000000" & R7FF7;
        elsif (mes_fmpac_address = "01"&"1111"&"1111"&"1110") then
          -- Register 7FFE
          mes_fmpac_readdatavalid_x <= '1';
          mes_fmpac_readdata_x <= R5FFE;
        elsif (mes_fmpac_address = "01"&"1111"&"1111"&"1111") then
          -- Register 7FFF
          mes_fmpac_readdatavalid_x <= '1';
          mes_fmpac_readdata_x <= R5FFF;
        elsif (CsRAM8k = '1' and mes_fmpac_read = '1') then
          -- SRAM
          read_state_x <= RS_SRAM;
        elsif (mes_fmpac_read = '1') then
          -- ROM
          rom_fmpac_read <= '1';
          if (rom_fmpac_waitrequest = '1') then
            read_waitrequest_i <= '1';
          else
            read_state_x <= RS_ROM;
          end if;
        end if;

      when RS_SRAM =>
        -- Read from ram block, fixed 1 cycle latency
        mes_fmpac_readdata <= ram8k_q;
        mes_fmpac_readdatavalid <= '1';
        read_state_x <= RS_IDLE;

      when RS_ROM =>
        -- Read from flash, wait for datavalid
        mes_fmpac_readdata <= rom_fmpac_readdata;
        mes_fmpac_readdatavalid <= rom_fmpac_readdatavalid;
        if (rom_fmpac_readdatavalid = '1') then
          read_state_x <= RS_IDLE;
        end if;
    end case;
  end process;

  --------------------------------------------------------
  -- Registers
  --------------------------------------------------------
  process(clock)
  begin
    if rising_edge(clock) then
      if slot_reset = '1' then
        read_state_r <= RS_IDLE;
        mes_fmpac_readdatavalid_r <= '0';
      else
        read_state_r <= read_state_x;
        mes_fmpac_readdatavalid_r <= mes_fmpac_readdatavalid_x;
      end if;
      mes_fmpac_readdata_r <= mes_fmpac_readdata_x;
    end if;
  end process;

end RTL;

  