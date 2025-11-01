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
-- Keyboard sniffer
------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity keyboard_sniffer is
port(
  -- clock and reset
  clock             : in std_logic;
  slot_reset        : in std_logic;

  -- avalon slave ports for flash    -- io sniffer
  iss_address       : in std_logic_vector(8 downto 0); -- 0x00-0xff = writes, 0x100-0x1ff = reads
  iss_write         : in std_logic;
  iss_writedata     : in std_logic_vector(7 downto 0);
  iss_waitrequest   : out std_logic;

  -- Keys
  key_num           : out std_logic_vector(9 downto 0);
  key_shift         : out std_logic;
  key_ctrl          : out std_logic;
  key_graph         : out std_logic;
  key_code          : out std_logic
);
end keyboard_sniffer;

architecture rtl of keyboard_sniffer is

  signal key_row_x, key_row_r     : std_logic_vector(3 downto 0);
  signal key_num_x, key_num_r     : std_logic_vector(9 downto 0);
  signal key_shift_x, key_shift_r : std_logic;
  signal key_ctrl_x, key_ctrl_r   : std_logic;
  signal key_graph_x, key_graph_r : std_logic;
  signal key_code_x, key_code_r   : std_logic;

begin

  iss_waitrequest <= '0';

  key_num   <= key_num_r;
  key_shift <= key_shift_r;
  key_ctrl  <= key_ctrl_r;
  key_graph <= key_graph_r;
  key_code  <= key_code_r;

  process(all)
  begin
    key_row_x <= key_row_r;
    key_num_x <= key_num_r;
    key_shift_x <= key_shift_r;
    key_ctrl_x <= key_ctrl_r;
    key_graph_x <= key_graph_r;
    key_code_x <= key_code_r;

    if (iss_write = '1' and iss_address = '0' & x"AA") then
      key_row_x <= iss_writedata(3 downto 0);
    end if;
    if (iss_write = '1' and iss_address = '1' & x"A9" and key_row_r = x"0") then
      key_num_x(7 downto 0) <= not iss_writedata;
    end if;
    if (iss_write = '1' and iss_address = '1' & x"A9" and key_row_r = x"1") then
      key_num_x(9 downto 8) <= not iss_writedata(1 downto 0);
    end if;
    if (iss_write = '1' and iss_address = '1' & x"A9" and key_row_r = x"6") then
      key_shift_x <= not iss_writedata(0);
      key_ctrl_x <= not iss_writedata(1);
      key_graph_x <= not iss_writedata(2);
      key_code_x <= not iss_writedata(4);
    end if;
  end process;

  --------------------------------------------------------
  -- Registers
  --------------------------------------------------------
  process(clock)
  begin
    if rising_edge(clock) then
      key_row_r <= key_row_x;
      key_num_r <= key_num_x;
      key_shift_r <= key_shift_x;
      key_ctrl_r <= key_ctrl_x;
      key_graph_r <= key_graph_x;
      key_code_r <= key_code_x;
    end if;
  end process;

end rtl;

  