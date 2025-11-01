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
-- Flash layout
------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity flash_layout is
  port(
    -- clock
    clock       : IN std_logic;
    slot_reset  : IN std_logic;

    -- Flash memory
    mem_flash_read            : out std_logic;
    mem_flash_write           : out std_logic;
    mem_flash_address         : out std_logic_vector(22 downto 0);
    mem_flash_writedata       : out std_logic_vector(7 downto 0);
    mem_flash_readdata        : in std_logic_vector(7 downto 0);
    mem_flash_readdatavalid   : in std_logic;
    mem_flash_waitrequest     : in std_logic;

    -- FM-Pack ROM
    mes_fmpac_read            : in std_logic;
    mes_fmpac_address         : in std_logic_vector(13 downto 0);
    mes_fmpac_readdata        : out std_logic_vector(7 downto 0);
    mes_fmpac_readdatavalid   : out std_logic;
    mes_fmpac_waitrequest     : out std_logic;

    -- MegaSD ROM
    mes_sd_read               : in std_logic;
    mes_sd_address            : in std_logic_vector(16 downto 0);
    mes_sd_readdata           : out std_logic_vector(7 downto 0);
    mes_sd_readdatavalid      : out std_logic;
    mes_sd_waitrequest        : out std_logic
);
end flash_layout;

architecture rtl of flash_layout is

  -- chipselect
  type mes_cs_t is (MES_CS_FMPAC, MES_CS_SD, MES_CS_NONE);
  signal mes_cs_i : mes_cs_t;
  signal mes_cs_read_r, mes_cs_read_x : mes_cs_t;

  signal mem_flash_read_x, mem_flash_read_r           : std_logic;
  signal mem_flash_write_x, mem_flash_write_r         : std_logic;
  signal mem_flash_address_x, mem_flash_address_r     : std_logic_vector(22 downto 0);
  signal mem_flash_writedata_x, mem_flash_writedata_r : std_logic_vector(7 downto 0);

begin

  mem_flash_read <= mem_flash_read_r;
  mem_flash_write <= mem_flash_write_r;
  mem_flash_address <= mem_flash_address_r;
  mem_flash_writedata <= mem_flash_writedata_r;

  --------------------------------------------------------------------
  -- Arbiter
  --------------------------------------------------------------------

  arbiter : process(all)
  begin
    if (mes_fmpac_read = '1') then
      -- FM-PAC
      mes_cs_i <= MES_CS_FMPAC;
    elsif (mes_sd_read = '1') then
      -- MegaSD
      mes_cs_i <= MES_CS_SD;
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
    mem_flash_read_x <= '0';
    mem_flash_write_x <= '0';
    mem_flash_writedata_x <= (others => '-');
    mem_flash_address_x <= (others => '-');
    mes_cs_read_x <= mes_cs_read_r;
    datavalid_v := '0';

    mes_fmpac_waitrequest <= '1';
    mes_sd_waitrequest <= '1';

    -- Read signal and waitrequest
    if (mem_flash_read_r = '1' or mem_flash_write_r = '1') then
      if (mem_flash_waitrequest = '1') then
        -- keep
        mem_flash_read_x <= mem_flash_read_r;
        mem_flash_write_x <= mem_flash_write_r;
        mem_flash_writedata_x <= mem_flash_writedata_r;
        mem_flash_address_x <= mem_flash_address_r;
      elsif (mem_flash_readdatavalid = '1') then
        mes_cs_read_x <= MES_CS_NONE;
        datavalid_v := '1';
      end if;
    end if;
    if ((mem_flash_read_r = '0' and mem_flash_write_r = '0') or datavalid_v = '1') then
      if (mem_flash_read_x = '1') then
        mes_cs_read_x <= mes_cs_i;
      end if;
      case (mes_cs_i) is
        when MES_CS_FMPAC =>
          -- FM-PAC
          mem_flash_read_x <= mes_fmpac_read;
          mem_flash_address_x <= "000"&"0011"&"00" & mes_fmpac_address;
          mes_fmpac_waitrequest <= mem_flash_waitrequest;
        when MES_CS_SD =>
          -- MegaSD
          mem_flash_read_x <= mes_sd_read;
          if (mes_sd_address(16) = '0') then
            mem_flash_address_x <= "000"&"0001"& mes_sd_address(15 downto 0);
          else
            mem_flash_address_x <= "000"&"0010"& mes_sd_address(15 downto 0);
          end if;
          mes_sd_waitrequest <= mem_flash_waitrequest;
        when others =>
      end case;
    end if;

    -- Read de-multiplexer
    mes_fmpac_readdata <= mem_flash_readdata;
    mes_fmpac_readdatavalid <= '0';
    mes_sd_readdata <= mem_flash_readdata;
    mes_sd_readdatavalid <= '0';
    case (mes_cs_read_r) is
      when MES_CS_FMPAC =>
        -- FM-PAC
        mes_fmpac_readdatavalid <= mem_flash_readdatavalid;
      when MES_CS_SD =>
        -- MegaSD
        mes_sd_readdatavalid <= mem_flash_readdatavalid;
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
        mem_flash_read_r <= '0';
        mem_flash_write_r <= '0';
      else
        mes_cs_read_r <= mes_cs_read_x;
        mem_flash_read_r <= mem_flash_read_x;
        mem_flash_write_r <= mem_flash_write_x;
      end if;
      mem_flash_address_r <= mem_flash_address_x;
      mem_flash_writedata_r <= mem_flash_writedata_x;
    end if;
  end process;

end rtl;
