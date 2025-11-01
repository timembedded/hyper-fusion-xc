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

entity memory_mapper is
  port(
    -- clock and reset
    clock                     : in std_logic;
    slot_reset                : in std_logic;

    -- avalon slave ports
    mes_mapper_read           : in std_logic;
    mes_mapper_write          : in std_logic;
    mes_mapper_address        : in std_logic_vector(15 downto 0);
    mes_mapper_writedata      : in std_logic_vector(7 downto 0);
    mes_mapper_readdata       : out std_logic_vector(7 downto 0);
    mes_mapper_readdatavalid  : out std_logic;
    mes_mapper_waitrequest    : out std_logic;
    ios_mapper_read           : in std_logic;
    ios_mapper_write          : in std_logic;
    ios_mapper_address        : in std_logic_vector(1 downto 0);
    ios_mapper_writedata      : in std_logic_vector(7 downto 0);
    ios_mapper_readdata       : out std_logic_vector(7 downto 0);
    ios_mapper_readdatavalid  : out std_logic;
    ios_mapper_waitrequest    : out std_logic;

    -- RAM master port
    ram_mapper_read           : out std_logic;
    ram_mapper_write          : out std_logic;
    ram_mapper_address        : out std_logic_vector(19 downto 0);
    ram_mapper_writedata      : out std_logic_vector(7 downto 0);
    ram_mapper_readdata       : in std_logic_vector(7 downto 0);
    ram_mapper_readdatavalid  : in std_logic;
    ram_mapper_waitrequest    : in std_logic
);
end memory_mapper;

architecture rtl of memory_mapper is

  -- Mapper
  type mapper_reg_t is array(0 to 3) of std_logic_vector(5 downto 0);
  signal map_reg_r : mapper_reg_t;

begin

  --------------------------------------------------------
  -- Connect RAM
  --------------------------------------------------------

  ram_mapper_read <= mes_mapper_read;
  ram_mapper_write <= mes_mapper_write;
  ram_mapper_address <= map_reg_r(0) & mes_mapper_address(13 downto 0) when mes_mapper_address(15 downto 14) = "00" else
                        map_reg_r(1) & mes_mapper_address(13 downto 0) when mes_mapper_address(15 downto 14) = "01" else
                        map_reg_r(2) & mes_mapper_address(13 downto 0) when mes_mapper_address(15 downto 14) = "10" else
                        map_reg_r(3) & mes_mapper_address(13 downto 0);
  ram_mapper_writedata <= mes_mapper_writedata;
  mes_mapper_readdata <= ram_mapper_readdata;
  mes_mapper_readdatavalid <= ram_mapper_readdatavalid;
  mes_mapper_waitrequest <= ram_mapper_waitrequest;

  --------------------------------------------------------
  -- Mapper I/O registers
  --------------------------------------------------------

  -- Write
  process(clock)
  begin
    if rising_edge(clock) then
      if (slot_reset = '1') then
        map_reg_r <= (others => (others => '0'));
      elsif (ios_mapper_write = '1') then
        map_reg_r(to_integer(unsigned(ios_mapper_address))) <= ios_mapper_writedata(5 downto 0);
      end if;
    end if;
  end process;

  -- Read
  ios_mapper_waitrequest <= '0';
  ios_mapper_readdata <= "00" & map_reg_r(to_integer(unsigned(ios_mapper_address))) when rising_edge(clock);
  ios_mapper_readdatavalid <= ios_mapper_read when rising_edge(clock);

end rtl;
