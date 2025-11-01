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
-- Common definitions and functions
------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package common is

  -- Find the base-2 logarithm of a number.
  function log2(v : in natural) return natural;

  -- Digital Input Filter
  component input_filter is
  generic (
    CLOCKS      : integer   := 2;
    DATA_WIDTH  : integer   := 1;
    RESET_STATE : std_logic := '0'
  );
  port
  (
    -- Clock
    clk       : IN  std_logic;
    clken     : IN  std_logic;
    reset     : IN  std_logic;

    -- Data
    input     : IN  std_logic_vector(DATA_WIDTH-1 downto 0);
    output    : OUT std_logic_vector(DATA_WIDTH-1 downto 0)
  );
  end component;

end package common;

package body common is

  -- Find the base 2 logarithm of a number.
  function log2(v : in natural) return natural is
    variable n    :    natural;
    variable logn :    natural;
  begin
    n      := 1;
    for i in 0 to 128 loop
      logn := i;
      exit when (n >= v);
      n    := n * 2;
    end loop;
    return logn;
  end function log2;

end package body common;
