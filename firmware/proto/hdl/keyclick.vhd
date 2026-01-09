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
--  MSX Key Click
------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.common.all;

entity keyclick is
  port(
    -- clock and reset
    clock              : in std_logic;
    slot_reset         : in std_logic;
    clkena_3m58        : in std_logic;

    -- io slave port (write-only)
    ios_write          : in std_logic;
    ios_address        : in std_logic_vector(7 downto 0);
    ios_writedata      : in std_logic_vector(7 downto 0);

    -- Output
    sample_out         : out std_logic_vector(15 downto 0)
);
end keyclick;

architecture rtl of keyclick is

  signal key_click_x, key_click_r       : std_logic;
  signal out_filter_x, out_filter_r     : unsigned(15 downto 0);
  signal sample_out_x, sample_out_r     : std_logic_vector(15 downto 0);
  signal freq_div_x, freq_div_r         : unsigned(7 downto 0);
  signal reset_filter_x, reset_filter_r : std_logic;

begin

  sample_out <= sample_out_r;

  process (all)
  begin
    freq_div_x <= freq_div_r;
    if( clkena_3m58 = '1' ) then
      freq_div_x <= freq_div_r + x"01";
    end if;
  end process;

  process(all)
  begin
    key_click_x <= key_click_r;
    -- I/O port access on AAh ... 1 bit sound port write (not PSG)
    if( ios_write = '1' and (ios_address = x"AA" or ios_address = x"AB") ) then
      if (ios_address(0) = '0') then
        key_click_x <= ios_writedata(7);
      elsif (ios_writedata(3 downto 1) = "111" and ios_writedata(7) = '0') then
        key_click_x <= ios_writedata(0);
      end if;
    end if;
  end process;

  process(all)
    variable subtract : std_logic_vector(15 downto 0);
  begin
    out_filter_x <= out_filter_r;
    if( reset_filter_r = '1' ) then
      out_filter_x <= (others => '0');
    elsif( clkena_3m58 = '1' ) then  
      subtract := "000000000" & key_click_r & "000000";
      out_filter_x <= out_filter_r - unsigned(subtract); 
    end if;
  end process;

  process(all)
  begin
    if freq_div_x(6) = '0' and freq_div_r(6) = '1' then
      sample_out_x <= std_logic_vector(out_filter_r);
      reset_filter_x <= '1';
    else
      sample_out_x <= sample_out_r;
      reset_filter_x <= '0';
    end if;
  end process;  

  process(clock)
  begin
    if rising_edge(clock) then
      if (slot_reset = '1') then
        key_click_r  <= '1';
        out_filter_r <= (others => '0');
        sample_out_r <= (others => '0');
        reset_filter_r <= '0';
        freq_div_r <= (others => '0');
      else
        key_click_r  <= key_click_x;
        out_filter_r <= out_filter_x;
        sample_out_r <= sample_out_x;
        reset_filter_r <= reset_filter_x;
        freq_div_r <= freq_div_x;
      end if;
    end if;
  end process;

end rtl;

  