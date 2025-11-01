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
-- Flash and SRAM interface
------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity flash_ram_interface is
port(
  -- clock and reset
  clock       : in std_logic;
  slot_reset  : in std_logic;

  -- avalon slave ports for flash
  mes_port_a_read           : in std_logic;
  mes_port_a_write          : in std_logic;
  mes_port_a_address        : in std_logic_vector(23 downto 0);
  mes_port_a_writedata      : in std_logic_vector(7 downto 0);
  mes_port_a_readdata       : out std_logic_vector(7 downto 0);
  mes_port_a_readdatavalid  : out std_logic;
  mes_port_a_waitrequest    : out std_logic;

  -- avalon slave ports for ram
  mes_port_b_read           : in std_logic;
  mes_port_b_write          : in std_logic;
  mes_port_b_address        : in std_logic_vector(23 downto 0);
  mes_port_b_writedata      : in std_logic_vector(7 downto 0);
  mes_port_b_readdata       : out std_logic_vector(7 downto 0);
  mes_port_b_readdatavalid  : out std_logic;
  mes_port_b_waitrequest    : out std_logic;

  -- avalon slave ports for flash+ram
  mes_port_c_read           : in std_logic;
  mes_port_c_write          : in std_logic;
  mes_port_c_address        : in std_logic_vector(23 downto 0);
  mes_port_c_writedata      : in std_logic_vector(7 downto 0);
  mes_port_c_readdata       : out std_logic_vector(7 downto 0);
  mes_port_c_readdatavalid  : out std_logic;
  mes_port_c_waitrequest    : out std_logic;

  -- Parallel flash interface
  pFlAdr    : OUT std_logic_vector(22 downto 0);
  pFlDat    : INOUT std_logic_vector(7 downto 0);
  pFlCS_n   : OUT std_logic;
  pFlOE_n   : OUT std_logic;
  pFlW_n    : OUT std_logic;
  pFlRP_n   : OUT std_logic;
  pFlRB_b   : IN std_logic;
  pFlVpp    : OUT std_logic;

  -- SRAM interface
  pRAMCS_n  : OUT std_logic
);
end flash_ram_interface;

architecture rtl of flash_ram_interface is

  constant FLASH_CYCLE_TIME : integer := 8; -- 80ns
  constant RAM_CYCLE_TIME   : integer := 6; -- 60ns

  signal delay_time_x, delay_time_r : integer range 0 to FLASH_CYCLE_TIME-1;

  type state_t is (S_IDLE, S_FLASH_READ, S_FLASH_WRITE, S_RAM_READ, S_RAM_WRITE);
  signal state_x, state_r : state_t;

  signal flram_address_x, flram_address_r     : std_logic_vector(22 downto 0);
  signal flram_writedata_x, flram_writedata_r : std_logic_vector(7 downto 0);
  signal flram_oe_x, flram_oe_r               : std_logic;
  signal flram_cs_flash_x, flram_cs_flash_r   : std_logic;
  signal flram_cs_ram_x, flram_cs_ram_r       : std_logic;
  type flram_port_select_t is (PORT_A, PORT_B, PORT_C);
  signal flram_port_select_x, flram_port_select_r : flram_port_select_t;
  signal flram_read_x, flram_read_r           : std_logic;
  signal flram_write_x, flram_write_r         : std_logic;

  signal mes_port_write_i                     : std_logic;
  signal mes_port_read_i                      : std_logic;
  signal mes_port_ram_not_flash_i             : std_logic;
  signal mes_port_datavalid_i                 : std_logic;
  signal mes_port_address_i                   : std_logic_vector(22 downto 0);
  signal mes_port_writedata_i                 : std_logic_vector(7 downto 0);

  signal mes_latch_data_x, mes_latch_data_r   : std_logic;
  signal mes_readdata_r                       : std_logic_vector(7 downto 0);
  signal mes_port_a_datavalid_x, mes_port_a_datavalid_r : std_logic;
  signal mes_port_b_datavalid_x, mes_port_b_datavalid_r : std_logic;
  signal mes_port_c_datavalid_x, mes_port_c_datavalid_r : std_logic;

begin

  --------------------------------------------------------
  -- Parallel flash and ram connections
  --------------------------------------------------------

  pFlDat <= flram_writedata_r when flram_oe_r = '1' else (others => 'Z');
  pFlAdr <= flram_address_r;
  pFlCS_n <= not flram_cs_flash_r;
  pRAMCS_n <= not flram_cs_ram_r;
  pFlOE_n <= not flram_read_r;
  pFlW_n <= not flram_write_r;
  pFlRP_n <= '1';
  pFlVpp <= '0';

  -- Data input register
  -- Note: Make sure this is a 'fast input register'
  process(clock)
  begin
    if rising_edge(clock) then
      if (mes_latch_data_r = '1') then
        mes_readdata_r <= pFlDat;
      end if;
    end if;
  end process;

  --------------------------------------------------------
  -- Arbiter
  --------------------------------------------------------
  process(all)
  begin
    flram_port_select_x <= flram_port_select_r;
    mes_port_a_waitrequest <= '1';
    mes_port_b_waitrequest <= '1';
    mes_port_c_waitrequest <= '1';

    if (state_r = S_IDLE) then
      if (mes_port_a_read = '1' or mes_port_a_write = '1') then
        flram_port_select_x <= PORT_A;
        mes_port_a_waitrequest <= '0';
      elsif (mes_port_b_read = '1' or mes_port_b_write = '1') then
        flram_port_select_x <= PORT_B;
        mes_port_b_waitrequest <= '0';
      elsif (mes_port_c_read = '1' or mes_port_c_write = '1') then
        flram_port_select_x <= PORT_C;
        mes_port_c_waitrequest <= '0';
      end if;
    end if;
  end process;

  mes_port_write_i <=
    mes_port_a_write when flram_port_select_x = PORT_A else
    mes_port_b_write when flram_port_select_x = PORT_B else
    mes_port_c_write;

  mes_port_read_i <=
    mes_port_a_read when flram_port_select_x = PORT_A else
    mes_port_b_read when flram_port_select_x = PORT_B else
    mes_port_c_read;

  mes_port_ram_not_flash_i <=
    mes_port_a_address(23) when flram_port_select_x = PORT_A else
    mes_port_b_address(23) when flram_port_select_x = PORT_B else
    mes_port_c_address(23);

  mes_port_address_i <=
    mes_port_a_address(22 downto 0) when flram_port_select_x = PORT_A else
    mes_port_b_address(22 downto 0) when flram_port_select_x = PORT_B else
    mes_port_c_address(22 downto 0);

  mes_port_writedata_i <=
    mes_port_a_writedata when flram_port_select_x = PORT_A else
    mes_port_b_writedata when flram_port_select_x = PORT_B else
    mes_port_c_writedata;

  mes_port_a_datavalid_x <= mes_port_datavalid_i when flram_port_select_r = PORT_A else '0';
  mes_port_b_datavalid_x <= mes_port_datavalid_i when flram_port_select_r = PORT_B else '0';
  mes_port_c_datavalid_x <= mes_port_datavalid_i when flram_port_select_r = PORT_C else '0';

  mes_port_a_readdatavalid <= mes_port_a_datavalid_r;
  mes_port_a_readdata <= mes_readdata_r;
  mes_port_b_readdatavalid <= mes_port_b_datavalid_r;
  mes_port_b_readdata <= mes_readdata_r;
  mes_port_c_readdatavalid <= mes_port_c_datavalid_r;
  mes_port_c_readdata <= mes_readdata_r;

  --------------------------------------------------------
  -- Read/write state machine
  --------------------------------------------------------
  process(all)
  begin
    state_x <= state_r;
    delay_time_x <= delay_time_r;

    mes_latch_data_x <= '0';
    mes_port_datavalid_i <= '0';

    flram_oe_x <= '0';
    flram_cs_flash_x <= '0';
    flram_cs_ram_x <= '0';
    flram_read_x <= '0';
    flram_write_x <= '0';
    flram_address_x <= flram_address_r;
    flram_writedata_x <= flram_writedata_r;

    case (state_r) is
      when S_IDLE =>
        flram_address_x <= mes_port_address_i;
        flram_writedata_x <= mes_port_writedata_i;

        if (mes_port_read_i = '1' and mes_port_ram_not_flash_i = '1') then
          -- RAM read
          flram_cs_ram_x <= '1';
          flram_read_x <= '1';
          delay_time_x <= RAM_CYCLE_TIME-1;
          state_x <= S_RAM_READ;
        elsif (mes_port_write_i = '1' and mes_port_ram_not_flash_i = '1') then
          -- RAM write
          flram_cs_ram_x <= '1';
          flram_oe_x <= '1';
          delay_time_x <= RAM_CYCLE_TIME-1;
          state_x <= S_RAM_WRITE;
        elsif (mes_port_read_i = '1' and mes_port_ram_not_flash_i = '0') then
          -- Flash read
          flram_cs_flash_x <= '1';
          flram_read_x <= '1';
          delay_time_x <= FLASH_CYCLE_TIME-1;
          state_x <= S_FLASH_READ;
        elsif (mes_port_write_i = '1' and mes_port_ram_not_flash_i = '0') then
          -- Flash write
          flram_cs_flash_x <= '1';
          flram_oe_x <= '1';
          delay_time_x <= FLASH_CYCLE_TIME-1;
          state_x <= S_FLASH_WRITE;
        end if;

      when S_FLASH_READ =>
        -- Process read
        flram_cs_flash_x <= '1';
        flram_read_x <= '1';
        if (delay_time_r /= 0) then
          if (delay_time_r = 1) then
            mes_latch_data_x <= '1';
          end if;
          delay_time_x <= delay_time_r - 1;
        else
          mes_port_datavalid_i <= '1';
          state_x <= S_IDLE;
        end if;
 
      when S_FLASH_WRITE =>
        -- Process write
        flram_cs_flash_x <= '1';
        flram_oe_x <= '1';
        flram_write_x <= '1';
        if (delay_time_r /= 0) then
          delay_time_x <= delay_time_r - 1;
        else
          state_x <= S_IDLE;
        end if;

      when S_RAM_READ =>
        -- Process read
        flram_cs_ram_x <= '1';
        flram_read_x <= '1';
        if (delay_time_r /= 0) then
          if (delay_time_r = 1) then
            mes_latch_data_x <= '1';
          end if;
          delay_time_x <= delay_time_r - 1;
        else
          mes_port_datavalid_i <= '1';
          state_x <= S_IDLE;
        end if;
 
      when S_RAM_WRITE =>
        -- Process write
        flram_cs_ram_x <= '1';
        flram_oe_x <= '1';
        flram_write_x <= '1';
        if (delay_time_r /= 0) then
          delay_time_x <= delay_time_r - 1;
        else
          state_x <= S_IDLE;
        end if;
 
    end case;

  end process;

  --------------------------------------------------------
  -- Registers
  --------------------------------------------------------
  process(clock)
  begin
    if rising_edge(clock) then
      if (slot_reset = '1') then
        state_r <= S_IDLE;
        flram_cs_flash_r <= '0';
        flram_cs_ram_r <= '0';
      else
        state_r <= state_x;
        flram_cs_flash_r <= flram_cs_flash_x;
        flram_cs_ram_r <= flram_cs_ram_x;
      end if;

      delay_time_r <= delay_time_x;

      flram_address_r <= flram_address_x;
      flram_writedata_r <= flram_writedata_x;
      flram_oe_r <= flram_oe_x;
      flram_read_r <= flram_read_x;
      flram_write_r <= flram_write_x;
      flram_port_select_r <= flram_port_select_x;

      mes_latch_data_r <= mes_latch_data_x;
      mes_port_a_datavalid_r <= mes_port_a_datavalid_x;
      mes_port_b_datavalid_r <= mes_port_b_datavalid_x;
      mes_port_c_datavalid_r <= mes_port_c_datavalid_x;
    end if;
  end process;

end rtl;
