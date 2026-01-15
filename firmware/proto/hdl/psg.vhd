------------------------------------------------------------------------
-- Copyright (C) 2026 Tim Brugman
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
--  MSX PSG + Key Click
--  Note: No filtering, output data needs to be filtered
------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.common.all;

entity psg is
  port(
    -- clock and reset
    clock              : in std_logic;
    slot_reset         : in std_logic;
    clkena_21m48       : in std_logic;
    clkena_3m58        : in std_logic;
    clkena_sample      : in std_logic;

    -- io slave port (write-only)
    ios_write          : in std_logic;
    ios_address        : in std_logic_vector(7 downto 0);
    ios_writedata      : in std_logic_vector(7 downto 0);

    -- Output
    sample_out         : out std_logic_vector(15 downto 0)
);
end psg;

architecture rtl of psg is

  -- 1-bit keyclick
  signal key_click        : std_logic;

  -- PSG signals
  signal psg_wrt          : std_logic;
  signal PsgAmp           : unsigned(  9 downto 0 );

begin

  -- Connect to output:
  -- bit 15   -> key-blick 1-bit audio
  -- bit 9..0 -> PSG sample data, unfiltered
  sample_out <= key_click & "00000" & std_logic_vector(PsgAmp);

  ----------------------------------------------------------------
  -- Key Click
  ----------------------------------------------------------------

  process(all)
  begin
    if rising_edge(clock) then
      -- I/O port access on AAh ... 1 bit sound port write (not PSG)
      if( ios_write = '1' and (ios_address = x"AA" or ios_address = x"AB") ) then
        if (ios_address(0) = '0') then
          key_click <= ios_writedata(7);
        elsif (ios_writedata(3 downto 1) = "111" and ios_writedata(7) = '0') then
          key_click <= ios_writedata(0);
        end if;
      end if;
    end if;
  end process;

  ----------------------------------------------------------------
  -- PSG
  ----------------------------------------------------------------

  psg_wrt <= '1' when ios_write = '1' and ios_address(7 downto 2) = "101000" else '0';

  i_psg_wave : entity work.psg_wave(rtl)
  port map(
    clock    => clock,
    reset    => slot_reset,
    clkena   => clkena_3m58,
    wrt      => psg_wrt,
    adr      => ios_address(1 downto 0),
    dbo      => ios_writedata,
    std_logic_vector(wave) => PsgAmp
  );

end rtl;

  