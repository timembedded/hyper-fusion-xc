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
-- MSX cartridge slave bridge
--
-- Bridge from asynchronous MSX cartridge bus to
-- synchronous Avalon busses for memory and IO
--
-- Note: for now it is assumed the peripheral handles / returns
--       data fast enough, so never wait states are inserted
--
------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity card_bus_slave is
  port(
    -- System Clock
    clock             : in std_logic;
    reset             : in std_logic;

    -- MSX-Slot
    slt_reset_n       : in std_logic;
    slt_sltsl_n       : in std_logic;
    slt_iorq_n        : in std_logic;
    slt_rd_n          : in std_logic;
    slt_wr_n          : in std_logic;
    slt_addr          : in std_logic_vector(15 downto 0);
    slt_data          : inout std_logic_vector(7 downto 0);
    slt_bdir_n        : inout std_logic;
    slt_wait          : out std_logic;
    slt_int_n         : in std_logic;
    slt_m1_n          : in std_logic;
    slt_merq_n        : in std_logic;

    -- Synchronous reset output
    slot_reset        : out std_logic;
    soft_reset        : out std_logic;

    -- Misc
    our_slot          : out std_logic_vector(1 downto 0);

    -- avalon memory master
    mem_address       : out std_logic_vector(16 downto 0);
    mem_write         : out std_logic;
    mem_writedata     : out std_logic_vector(7 downto 0);
    mem_read          : out std_logic;
    mem_readdata      : in std_logic_vector(8 downto 0);
    mem_readdatavalid : in std_logic;
    mem_waitrequest   : in std_logic;

    -- avalon io master
    iom_address       : out std_logic_vector(7 downto 0);
    iom_write         : out std_logic;
    iom_writedata     : out std_logic_vector(7 downto 0);
    iom_read          : out std_logic;
    iom_readdata      : in std_logic_vector(8 downto 0);
    iom_readdatavalid : in std_logic;
    iom_waitrequest   : in std_logic;

    -- io sniffer
    ism_address       : out std_logic_vector(8 downto 0); -- 0x00-0xff = writes, 0x100-0x1ff = reads
    ism_write         : out std_logic;
    ism_writedata     : out std_logic_vector(7 downto 0);
    ism_waitrequest   : in std_logic
  );
end card_bus_slave;

architecture rtl of card_bus_slave is

  constant IO_CYCLE_TIME       : integer := 15; -- 150ns, after this time the sniffer samples the data

  constant MAX_MEM_CYCLE_TIME  : integer := 15; -- 150ns, when no data for MEMORY read after this time, the WAIT signal will be asserted
  constant MAX_IO_CYCLE_TIME   : integer := 30; -- 300ns, when no data for IO read after this time, the WAIT signal will be asserted
  constant WAIT_HOLD_TIME      : integer := 2;  -- 20ns, when data arrives when WAIT asserted, keep WAIT active this time

  -- State machine
  type state_t is (S_RESET, S_IDLE, S_MEM_START_READ, S_MEM_RETURN_DATA, S_MEM_START_WRITE, S_MEM_WRITE_DONE,
                   S_IO_START_READ, S_IO_RETURN_DATA, S_IO_START_WRITE, S_IO_WRITE_DONE);
  signal state_x, state_r                 : state_t;
  type sniff_state_t is (SF_RESET, SF_IDLE, SF_READ_SNIFF, SF_FINISH_SNIFF);
  signal sniff_state_x, sniff_state_r     : sniff_state_t;
  signal sniff_io_time_x, sniff_io_time_r : integer range 0 to IO_CYCLE_TIME-1;
  signal wait_time_x, wait_time_r         : integer range 0 to MAX_IO_CYCLE_TIME-1;
  signal slot_wait_x, slot_wait_r         : std_logic;
  signal mem_waiting_x, mem_waiting_r     : std_logic;
  signal iom_waiting_x, iom_waiting_r     : std_logic;

  -- Asynchronous signals
  signal memrd_i, memwr_i                 : std_logic;
  signal memxrd_i, memxwr_i               : std_logic;
  signal iord_i, iowr_i                   : std_logic;

  -- Synchronizers
  signal slt_reset_n_s, slt_reset_n_r     : std_logic;
  signal memrd_s, memrd_r, memrd_d        : std_logic;
  signal memwr_s, memwr_r, memwr_d        : std_logic;
  signal memxrd_s, memxrd_r               : std_logic;
  signal memxwr_s, memxwr_r               : std_logic;
  signal iord_s, iord_r                   : std_logic;
  signal iowr_s, iowr_r                   : std_logic;

  -- Soft reset detection
  signal soft_rst_i, soft_rst_s, soft_rst_r, soft_rst_d : std_logic;

  -- Synchronous reset outputs
  signal slot_reset_n_x, slot_reset_n_r   : std_logic;
  signal slot_readdata_x, slot_readdata_r : std_logic_vector(8 downto 0);
  signal soft_reset_x, soft_reset_r       : std_logic;

  -- Other slot
  signal slot_reg_x, slot_reg_r           : std_logic_vector(7 downto 0);
  signal our_slot_x, our_slot_r           : std_logic_vector(1 downto 0);
  signal other_slot_x, other_slot_r       : integer range 0 to 2;
  signal sltsl1_i, sltsl2_i, sltslx_i     : std_logic;

  -- Avalon memory master
  signal mem_read_x, mem_read_r           : std_logic;
  signal mem_write_x, mem_write_r         : std_logic;
  signal mem_address_x, mem_address_r     : std_logic_vector(16 downto 0);
  signal mem_writedata_x, mem_writedata_r : std_logic_vector(7 downto 0);

  -- Avalon io master
  signal iom_read_x, iom_read_r           : std_logic;
  signal iom_write_x, iom_write_r         : std_logic;
  signal iom_address_x, iom_address_r     : std_logic_vector(7 downto 0);
  signal iom_writedata_x, iom_writedata_r : std_logic_vector(7 downto 0);

  -- io sniffer
  signal ism_address_x, ism_address_r     : std_logic_vector(8 downto 0);
  signal ism_write_x, ism_write_r         : std_logic;
  signal ism_writedata_x, ism_writedata_r : std_logic_vector(7 downto 0);

begin

  -- Reset
  slot_reset <= not slot_reset_n_r;
  soft_reset <= soft_reset_r;

  -- Asynchronous signals
  soft_rst_i <= '1' when slt_addr(15 downto 0) = x"0000" and slt_merq_n = '0' and slt_m1_n = '0' and slt_rd_n = '0' else '0';
  memrd_i <= '1' when slt_sltsl_n = '0' and slt_merq_n = '0' and slt_rd_n = '0' else '0';
  memwr_i <= '1' when slt_sltsl_n = '0' and slt_merq_n = '0' and slt_wr_n = '0' else '0';
  memxrd_i <= '1' when sltslx_i = '1' and slt_merq_n = '0' and slt_rd_n = '0' else '0';
  memxwr_i <= '1' when sltslx_i = '1' and slt_merq_n = '0' and slt_wr_n = '0' else '0';
  iord_i <= '1' when slt_iorq_n = '0' and slt_rd_n = '0' else '0';
  iowr_i <= '1' when slt_iorq_n = '0' and slt_wr_n = '0' else '0';
  slt_wait <= slot_wait_r;

  -- Synchronizers
  slt_reset_n_s <= slt_reset_n when rising_edge(clock);
  slt_reset_n_r <= slt_reset_n_s when rising_edge(clock);
  soft_rst_s <= soft_rst_i when rising_edge(clock);
  soft_rst_r <= soft_rst_s when rising_edge(clock);
  soft_rst_d <= soft_rst_r when rising_edge(clock);
  memrd_s <= memrd_i when rising_edge(clock);
  memrd_r <= memrd_s when rising_edge(clock);
  memrd_d <= memrd_r when rising_edge(clock);
  memwr_s <= memwr_i when rising_edge(clock);
  memwr_r <= memwr_s when rising_edge(clock);
  memwr_d <= memwr_r when rising_edge(clock);
  memxrd_s <= memxrd_i when rising_edge(clock);
  memxrd_r <= memxrd_s when rising_edge(clock);
  memxwr_s <= memxwr_i when rising_edge(clock);
  memxwr_r <= memxwr_s when rising_edge(clock);
  iord_s <= iord_i when rising_edge(clock);
  iord_r <= iord_s when rising_edge(clock);
  iowr_s <= iowr_i when rising_edge(clock);
  iowr_r <= iowr_s when rising_edge(clock);

  -- Misc
  our_slot <= our_slot_r;

  -- Avalon memory master
  mem_address   <= mem_address_r;
  mem_write     <= mem_write_r;
  mem_writedata <= mem_writedata_r;
  mem_read      <= mem_read_r;

  -- Avalon io master
  iom_address   <= iom_address_r;
  iom_write     <= iom_write_r;
  iom_writedata <= iom_writedata_r;
  iom_read      <= iom_read_r;

  -- io sniffer for writes
  ism_address     <= ism_address_r;
  ism_write       <= ism_write_r;
  ism_writedata   <= ism_writedata_r;

  -- Wait state generation
  p_wait : process(all)
  begin
    slot_wait_x <= slot_wait_r;
    wait_time_x <= wait_time_r;

    if (slot_wait_r = '0') then
      -- WAIT not asserted
      if (mem_waiting_r = '1' or iom_waiting_r = '1') then
        if ((mem_waiting_r = '1' and wait_time_r < MAX_MEM_CYCLE_TIME-1) or
            (iom_waiting_r = '1' and wait_time_r < MAX_IO_CYCLE_TIME-1)) then
          wait_time_x <= wait_time_r + 1;
        else
          -- bus is blocked for MAX_CYCLE_TIME clocks, assert WAIT signal
          wait_time_x <= 0;
          slot_wait_x <= '1';
        end if;
      else
        wait_time_x <= 0;
      end if;
    else
      -- WAIT asserted, wait till we can release it
      if (mem_waiting_r = '0' and iom_waiting_r = '0') then
        -- release after WAIT_HOLD_TIME clocks
        if (wait_time_r /= WAIT_HOLD_TIME) then
          wait_time_x <= wait_time_r + 1;
        else
          slot_wait_x <= '0';
        end if;
      else
        wait_time_x <= 0;
      end if;
    end if;
  end process;
  
  -- Memory state-machine
  p_mem : process(all)
  begin
    state_x <= state_r;
    mem_waiting_x <= mem_waiting_r;
    iom_waiting_x <= iom_waiting_r;

    slot_reset_n_x <= '1';
    slot_readdata_x <= slot_readdata_r;
    soft_reset_x <= '0';

    mem_read_x <= '0';
    mem_write_x <= '0';
    mem_address_x <= mem_address_r;
    mem_writedata_x <= mem_writedata_r;

    iom_read_x <= '0';
    iom_write_x <= '0';
    iom_address_x <= iom_address_r;
    iom_writedata_x <= iom_writedata_r;

    slt_bdir_n <= 'Z';

    if (slot_readdata_r(8) = '1') then
      slt_data <= slot_readdata_r(7 downto 0);
    else
      slt_data <= (others => 'Z');
    end if;

    if (soft_rst_d = '0' and soft_rst_r = '1' and slot_reg_r(1 downto 0) = "00") then
      soft_reset_x <= '1';
    end if;

    case (state_r) is
      when S_RESET =>
        slot_reset_n_x <= '0';
        if (slt_reset_n_r = '1') then
          state_x <= S_IDLE;
        end if;

      when S_IDLE =>
        -- Note that no synchronizers are needed for address
        -- and data from the slot as the signals are guaranteed
        -- to be stable when one of the read/writes gets active
        mem_waiting_x <= '0';
        iom_waiting_x <= '0';
        if (slt_reset_n_r = '0') then
          state_x <= S_RESET;
        elsif (memrd_r = '1' or memxrd_r = '1') then
          mem_read_x <= '1';
          mem_address_x <= sltslx_i & slt_addr;
          mem_waiting_x <= '1';
          state_x <= S_MEM_START_READ;
        elsif (memwr_r = '1' or memxwr_r = '1') then
          mem_write_x <= '1';
          mem_address_x <= sltslx_i & slt_addr;
          mem_waiting_x <= '1';
          mem_writedata_x <= slt_data;
          state_x <= S_MEM_START_WRITE;
        elsif (iord_r = '1') then
          iom_read_x <= '1';
          iom_address_x <= slt_addr(7 downto 0);
          iom_waiting_x <= '1';
          state_x <= S_IO_START_READ;
        elsif (iowr_r = '1') then
          iom_write_x <= '1';
          iom_address_x <= slt_addr(7 downto 0);
          iom_writedata_x <= slt_data;
          iom_waiting_x <= '1';
          state_x <= S_IO_START_WRITE;
        end if;

      when S_MEM_START_READ =>
        -- Read data from peripherals (avalon master interface)
        if (mem_waitrequest = '1') then
          mem_read_x <= '1';
        else
          state_x <= S_MEM_RETURN_DATA;
        end if;
      when S_MEM_RETURN_DATA =>
        -- Show the data on the Z80 bus
        if (mem_address_r(16) = '1') then
          -- Only for 'other slot' the bdir signal needs to be asserted
          slt_bdir_n <= '0';
        end if;
        if (mem_readdatavalid = '1') then
          mem_waiting_x <= '0';
          slot_readdata_x <= mem_readdata;
        end if;
        if (memrd_r = '0' and memxrd_r = '0') then
          slot_readdata_x(8) <= '0';
          state_x <= S_IDLE;
        end if;

      when S_MEM_START_WRITE =>
        if (mem_waitrequest = '1') then
          -- Another write state
          mem_write_x <= '1';
        else
          -- We're done
          mem_waiting_x <= '0';
          if (memwr_r = '0' and memxwr_r = '0') then
            state_x <= S_IDLE;
          else
            state_x <= S_MEM_WRITE_DONE;
          end if;
        end if;
      when S_MEM_WRITE_DONE =>
        -- Wait for write signal to deassert
        if (memwr_r = '0' and memxwr_r = '0') then
          state_x <= S_IDLE;
        end if;

      when S_IO_START_READ =>
        -- Read data from peripherals (avalon master interface)
        if (iom_waitrequest = '1') then
          iom_read_x <= '1';
        else
          state_x <= S_IO_RETURN_DATA;
        end if;
      when S_IO_RETURN_DATA =>
        -- Show the data on the Z80 bus
        slt_bdir_n <= '0';
        if (iom_readdatavalid = '1') then
          iom_waiting_x <= '0';
          slot_readdata_x <= iom_readdata;
        end if;
        if (iord_r = '0') then
          slot_readdata_x(8) <= '0';
          state_x <= S_IDLE;
        end if;

      when S_IO_START_WRITE =>
        if (iom_waitrequest = '1') then
          -- Another write state
          iom_write_x <= '1';
        else
          -- We're done
          iom_waiting_x <= '0';
          if (iowr_r = '0') then
            state_x <= S_IDLE;
          else
            state_x <= S_IO_WRITE_DONE;
          end if;
        end if;
      when S_IO_WRITE_DONE =>
        -- Wait for write signal to deassert
        if (iowr_r = '0') then
          state_x <= S_IDLE;
        end if;

    end case;
  end process;

  -- Other slot
  sltsl1_i <= '1' when (slt_merq_n = '0' and slt_addr(15 downto 14) = "00" and slot_reg_r(1 downto 0) = "01") else
              '1' when (slt_merq_n = '0' and slt_addr(15 downto 14) = "01" and slot_reg_r(3 downto 2) = "01") else
              '1' when (slt_merq_n = '0' and slt_addr(15 downto 14) = "10" and slot_reg_r(5 downto 4) = "01") else
              '1' when (slt_merq_n = '0' and slt_addr(15 downto 14) = "11" and slot_reg_r(7 downto 6) = "01") else '0';

  sltsl2_i <= '1' when (slt_merq_n = '0' and slt_addr(15 downto 14) = "00" and slot_reg_r(1 downto 0) = "10") else
              '1' when (slt_merq_n = '0' and slt_addr(15 downto 14) = "01" and slot_reg_r(3 downto 2) = "10") else
              '1' when (slt_merq_n = '0' and slt_addr(15 downto 14) = "10" and slot_reg_r(5 downto 4) = "10") else
              '1' when (slt_merq_n = '0' and slt_addr(15 downto 14) = "11" and slot_reg_r(7 downto 6) = "10") else '0';

  sltslx_i <= '1' when (other_slot_r = 1 and sltsl1_i = '1') else
              '1' when (other_slot_r = 2 and sltsl2_i = '1') else '0';

  xslot : process(all)
  begin
    slot_reg_x <= slot_reg_r;
    other_slot_x <= other_slot_r;
    our_slot_x <= our_slot_r;

    if (iom_write_r = '1' and iom_address_r = x"A8") then
      slot_reg_x <= iom_writedata_r;
    end if;

    if ((memrd_r = '1' and memrd_d = '0') or (memwr_r = '1' and memwr_d = '0')) then
      if (sltsl1_i = '1') then
        other_slot_x <= 2;
        our_slot_x <= "01";
      elsif (sltsl2_i = '1') then
        other_slot_x <= 1;
        our_slot_x <= "10";
      else
        other_slot_x <= 0;
        our_slot_x <= "00";
      end if;
    end if;

  end process;

  -- Sniffer
  sniffer : process(all)
  begin
    sniff_state_x <= sniff_state_r;
    sniff_io_time_x <= sniff_io_time_r;

    ism_address_x <= ism_address_r;
    ism_write_x <= '0';
    ism_writedata_x <= ism_writedata_r;

    case (sniff_state_r) is
      when SF_RESET =>
        if (slt_reset_n_r = '1') then
          sniff_state_x <= SF_IDLE;
        end if;

      when SF_IDLE =>
        sniff_io_time_x <= IO_CYCLE_TIME-1;
        if (slt_reset_n_r = '0') then
          sniff_state_x <= SF_RESET;
        elsif (iord_r = '1') then
          ism_address_x <= '1' & slt_addr(7 downto 0);
          sniff_state_x <= SF_READ_SNIFF;
        elsif (iowr_r = '1') then
          ism_address_x <= '0' & slt_addr(7 downto 0);
          ism_writedata_x <= slt_data;
          ism_write_x <= '1';
          sniff_state_x <= SF_FINISH_SNIFF;
        end if;

      when SF_READ_SNIFF =>
        if (sniff_io_time_r /= 0) then
          sniff_io_time_x <= sniff_io_time_r - 1;
        else
          ism_write_x <= '1';
          ism_writedata_x <= slt_data;
          sniff_state_x <= SF_FINISH_SNIFF;
        end if;

      when SF_FINISH_SNIFF =>
        if (ism_write_r = '1' and ism_waitrequest = '1') then
          ism_write_x <= '1';
        elsif (iord_s = '0' and iowr_r = '0') then
          sniff_state_x <= SF_IDLE;
        end if;
    end case;
  end process;

  -- Registers
  regs : process(clock, reset)
  begin
    if (reset = '1') then
      state_r <= S_RESET;
      sniff_state_r <= SF_RESET;
      wait_time_r <= 0;
      mem_waiting_r <= '0';
      iom_waiting_r <= '0';
      slot_reset_n_r <= '0';
      soft_reset_r <= '0';
      slot_reg_r <= x"00";
      other_slot_r <= 0;
      our_slot_r <= "00";
      slot_readdata_r(8) <= '0';
      mem_read_r <= '0';
      mem_write_r <= '0';
      iom_read_r <= '0';
      iom_write_r <= '0';
      ism_write_r <= '0';
    elsif rising_edge(clock) then
      state_r <= state_x;
      sniff_state_r <= sniff_state_x;
      wait_time_r <= wait_time_x;
      mem_waiting_r <= mem_waiting_x;
      iom_waiting_r <= iom_waiting_x;
      slot_reset_n_r <= slot_reset_n_x;
      soft_reset_r <= soft_reset_x;
      slot_reg_r <= slot_reg_x;
      other_slot_r <= other_slot_x;
      our_slot_r <= our_slot_x;
      slot_readdata_r(8) <= slot_readdata_x(8);
      mem_read_r <= mem_read_x;
      mem_write_r <= mem_write_x;
      iom_read_r <= iom_read_x;
      iom_write_r <= iom_write_x;
      ism_write_r <= ism_write_x;
    end if;
    if rising_edge(clock) then
      slot_readdata_r(7 downto 0) <= slot_readdata_x(7 downto 0);
      slot_wait_r <= slot_wait_x;
      mem_address_r <= mem_address_x;
      mem_writedata_r <= mem_writedata_x;
      iom_address_r <= iom_address_x;
      iom_writedata_r <= iom_writedata_x;
      -- io sniffer
      sniff_io_time_r <= sniff_io_time_x;
      ism_address_r <= ism_address_x;
      ism_writedata_r <= ism_writedata_x;
    end if;
  end process;

end rtl;
