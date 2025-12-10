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
-- Digital input filter
------------------------------------------------------------------------

-----
-- Library
-----
LIBRARY ieee;
USE ieee.std_logic_1164.all;

-----
-- Entity
-----
ENTITY input_filter IS
GENERIC (
  FILTER_CLOCKS : integer   := 1;
  DATA_WIDTH    : integer   := 1;
  RESET_STATE   : std_logic := '0'
);
PORT
(
  -- Clock
  clk       : IN  std_logic;
  clken     : IN  std_logic;
  reset     : IN  std_logic;

  -- Data
  input     : IN  std_logic_vector(DATA_WIDTH-1 downto 0);
  output    : OUT std_logic_vector(DATA_WIDTH-1 downto 0)
);
END ENTITY input_filter;

-----
-- Architecture
-----
ARCHITECTURE rtl OF input_filter IS

-----
-- Signals
-----

  -- Meta stability filter
  signal input_sync_c1                  : std_logic_vector(DATA_WIDTH-1 downto 0) := (others => RESET_STATE);
  signal input_sync_c2                  : std_logic_vector(DATA_WIDTH-1 downto 0) := (others => RESET_STATE);

  -- Digital filter
  signal filter_state_x, filter_state_r : std_logic_vector(DATA_WIDTH-1 downto 0) := (others => RESET_STATE);
  type filter_count_t is array (0 to DATA_WIDTH-1) of integer range 0 to FILTER_CLOCKS-1;
  signal filter_count_x, filter_count_r : filter_count_t;

-----
-- Implementation
-----
BEGIN

  -- Connect output
  output <= filter_state_r when FILTER_CLOCKS > 1 else input_sync_c2;

  ---------------------------------------------------------------------
  -- Sample input signal
  -- Since this is a asynchronous signal it must be clocked trough
  -- at least two flip-flops to prevent meta stability issues.
  ---------------------------------------------------------------------
  input_sync_c1 <= input when rising_edge(clk);
  input_sync_c2 <= input_sync_c1 when rising_edge(clk);

  ---------------------------------------------------------------------
  -- The filter
  ---------------------------------------------------------------------
  GEN_FILTERS: for I in 0 to DATA_WIDTH-1 generate
  process(input_sync_c2, filter_state_r, filter_count_r)
  begin
    -- registers
    filter_state_x(I) <= filter_state_r(I);
    filter_count_x(I) <= filter_count_r(I);

    -- filter implementation
    if( input_sync_c2(I) /= filter_state_r(I) ) then
      if( filter_count_r(I) = FILTER_CLOCKS-1 ) then
        filter_state_x(I) <= input_sync_c2(I);
        filter_count_x(I) <= 0;
      else
        filter_count_x(I) <= filter_count_r(I) + 1;
      end if;
    else
      filter_count_x(I) <= 0;
    end if;
  end process;
  end generate GEN_FILTERS;

  ---------------------------------------------------------------------
  -- Registers
  ---------------------------------------------------------------------
  process(clk, reset)
  begin
    if( reset = '1' ) then
      filter_state_r <= (others => RESET_STATE);
      filter_count_r <= (others => 0);
    elsif( clk = '1' and clk'event ) then
      if( clken = '1' ) then
        filter_state_r <= filter_state_x;
        filter_count_r <= filter_count_x;
      end if;
    end if;
  end process;

END ARCHITECTURE rtl;
