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
-- RAM layout
------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity ram_layout is
  port(
    -- clock
    clock                     : IN std_logic;
    slot_reset                : IN std_logic;

    -- RAM memory
    mem_ram_read              : out std_logic;
    mem_ram_write             : out std_logic;
    mem_ram_address           : out std_logic_vector(20 downto 0);
    mem_ram_writedata         : out std_logic_vector(7 downto 0);
    mem_ram_readdata          : in std_logic_vector(7 downto 0);
    mem_ram_readdatavalid     : in std_logic;
    mem_ram_waitrequest       : in std_logic;

    -- Memory mapper
    mes_mapper_read           : in std_logic;
    mes_mapper_write          : in std_logic;
    mes_mapper_address        : in std_logic_vector(19 downto 0);
    mes_mapper_writedata      : in std_logic_vector(7 downto 0);
    mes_mapper_readdata       : out std_logic_vector(7 downto 0);
    mes_mapper_readdatavalid  : out std_logic;
    mes_mapper_waitrequest    : out std_logic
);
end ram_layout;

architecture rtl of ram_layout is

  -- chipselect
  type mes_cs_t is (MES_CS_MAPPER, MES_CS_NONE);
  signal mes_cs_i : mes_cs_t;
  signal mes_cs_read_r, mes_cs_read_x : mes_cs_t;

  signal mem_ram_read_x, mem_ram_read_r           : std_logic;
  signal mem_ram_write_x, mem_ram_write_r         : std_logic;
  signal mem_ram_address_x, mem_ram_address_r     : std_logic_vector(20 downto 0);
  signal mem_ram_writedata_x, mem_ram_writedata_r : std_logic_vector(7 downto 0);

begin

  mem_ram_read <= mem_ram_read_r;
  mem_ram_write <= mem_ram_write_r;
  mem_ram_address <= mem_ram_address_r;
  mem_ram_writedata <= mem_ram_writedata_r;

  --------------------------------------------------------------------
  -- Arbiter
  --------------------------------------------------------------------
  arbiter : process(all)
  begin
    if (mes_mapper_read = '1' or mes_mapper_write = '1') then
      mes_cs_i <= MES_CS_MAPPER;
    else
      mes_cs_i <= MES_CS_NONE;
    end if;
  end process;

  --------------------------------------------------------------------
  -- Read and write
  --------------------------------------------------------------------
  mem_read_write: process(all)
    variable datavalid_v : std_logic;
  begin
    mem_ram_read_x <= '0';
    mem_ram_write_x <= '0';
    mem_ram_writedata_x <= (others => '-');
    mem_ram_address_x <= (others => '-');
    mes_cs_read_x <= mes_cs_read_r;
    datavalid_v := '0';

    mes_mapper_waitrequest <= '1';

    -- Read signal and waitrequest
    if (mem_ram_read_r = '1' or mem_ram_write_r = '1') then
      if (mem_ram_waitrequest = '1') then
        -- keep
        mem_ram_read_x <= mem_ram_read_r;
        mem_ram_write_x <= mem_ram_write_r;
        mem_ram_writedata_x <= mem_ram_writedata_r;
        mem_ram_address_x <= mem_ram_address_r;
      elsif (mem_ram_readdatavalid = '1') then
        mes_cs_read_x <= MES_CS_NONE;
        datavalid_v := '1';
      end if;
    end if;
    if ((mem_ram_read_r = '0' and mem_ram_write_r = '0') or datavalid_v = '1') then
      if (mem_ram_read_x = '1') then
        mes_cs_read_x <= mes_cs_i;
      end if;
      case (mes_cs_i) is
        when MES_CS_MAPPER =>
          mes_mapper_waitrequest <= '0';
          mem_ram_read_x <= mes_mapper_read;
          mem_ram_write_x <= mes_mapper_write;
          mem_ram_writedata_x <= mes_mapper_writedata;
          mem_ram_address_x <= '1' & mes_mapper_address;
        when others =>
      end case;
    end if;

    -- Read de-multiplexer
    mes_mapper_readdata <= mem_ram_readdata;
    mes_mapper_readdatavalid <= '0';
    case (mes_cs_read_r) is
      when MES_CS_MAPPER =>
        -- Memory mapper
        mes_mapper_readdatavalid <= mem_ram_readdatavalid;
      when others =>
    end case;
  end process;

  --------------------------------------------------------------------
  -- Registers
  --------------------------------------------------------------------
  process(clock)
  begin
    if rising_edge(clock) then
      if (slot_reset = '1') then
        mes_cs_read_r <= MES_CS_NONE;
        mem_ram_read_r <= '0';
        mem_ram_write_r <= '0';
      else
        mes_cs_read_r <= mes_cs_read_x;
        mem_ram_read_r <= mem_ram_read_x;
        mem_ram_write_r <= mem_ram_write_x;
      end if;
      mem_ram_address_r <= mem_ram_address_x;
      mem_ram_writedata_r <= mem_ram_writedata_x;
    end if;
  end process;

end rtl;
