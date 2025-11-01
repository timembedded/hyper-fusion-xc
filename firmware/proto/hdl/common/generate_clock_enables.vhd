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
-- Generate clock enable signals
------------------------------------------------------------------------

-----
-- Library
-----
LIBRARY ieee;
USE ieee.std_logic_1164.all;
USE ieee.numeric_std.all;
use work.common.all;

-----
-- Entity
-----
ENTITY generate_clock_enables IS
GENERIC (
  FREQ_MHZ : natural := 0
);
PORT
(
  clk        : IN std_logic;
  pll_locked : IN std_logic;

  reset      : OUT std_logic;

  clken1us   : OUT std_logic;
  clken1ms   : OUT std_logic;
  clken1s    : OUT std_logic
);
END ENTITY generate_clock_enables;

-----
-- Architecture
-----
ARCHITECTURE rtl OF generate_clock_enables IS

-----
-- Signals
-----

  signal is_running_x : std_logic;
  signal is_running_r : std_logic := '0';
  signal clken_1us_x, clken_1ms_x, clken_1s_x : std_logic;
  signal clken_1us_r, clken_1ms_r, clken_1s_r : std_logic := '0';
  signal count_1us_x  : integer range 0 to FREQ_MHZ-1;
  signal count_1us_r  : integer range 0 to FREQ_MHZ-1 := 0;
  signal count_1ms_x  : integer range 0 to 999;
  signal count_1ms_r  : integer range 0 to 999 := 0;
  signal count_1s_x   : integer range 0 to 999;
  signal count_1s_r   : integer range 0 to 999 := 0;

-----
-- Implementation
-----
BEGIN

  -----
  -- Outputs
  -----
  reset    <= not is_running_r;
  clken1us <= clken_1us_r;
  clken1ms <= clken_1ms_r;
  clken1s  <= clken_1s_r;

  -----
  -- Clock dividers
  -----

  process(is_running_r, count_1us_r, count_1ms_r, count_1s_r, clken_1ms_r, clken_1us_r)
  begin
    is_running_x <= is_running_r;
    count_1ms_x <= count_1ms_r;
    count_1s_x <= count_1s_r;
    clken_1us_x <= '0';
    clken_1ms_x <= '0';
    clken_1s_x <= '0';

    -- Count clocks, wraps every microsecond
    if( count_1us_r = FREQ_MHZ-1 ) then
      is_running_x <= '1';
      clken_1us_x <= is_running_r;
      count_1us_x <= 0;
    else 
      count_1us_x <= count_1us_r + 1;
    end if;

    -- Count microseconds, wraps every millisecond
    if( clken_1us_r = '1' ) then
      if( count_1ms_r = 999 ) then
        clken_1ms_x <= '1';
        count_1ms_x <= 0;
      else
        count_1ms_x <= count_1ms_r + 1;
      end if;
    end if;

    -- Count milliseconds, wraps every second
    if( clken_1ms_r = '1' ) then
      if( count_1s_r = 999 ) then
        clken_1s_x  <= '1';
        count_1s_x <= 0;
      else
        count_1s_x <= count_1s_r + 1;
      end if;
    end if;
  end process;

  -----
  -- Registers
  -----

  process(pll_locked, clk)
  begin
    if( pll_locked = '0' ) then
      is_running_r <= '0';
      clken_1us_r <= '0';
      count_1us_r <= 0;
      clken_1ms_r <= '0';
      count_1ms_r <= 0;
      clken_1s_r <= '0';
      count_1s_r <= 0;
    elsif( clk = '1' and clk'event ) then
      is_running_r <= is_running_x;
      clken_1us_r <= clken_1us_x;
      count_1us_r <= count_1us_x;
      clken_1ms_r <= clken_1ms_x;
      count_1ms_r <= count_1ms_x;
      clken_1s_r <= clken_1s_x;
      count_1s_r <= count_1s_x;
    end if;
  end process;

END ARCHITECTURE rtl;
