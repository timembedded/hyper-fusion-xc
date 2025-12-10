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
-- FPGA part of audio devices
------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.common.all;

entity audiodev is
  port(
    -- clock and reset
    clock              : in std_logic;
    slot_reset         : in std_logic;
    clkena_3m58        : in std_logic;

    -- IRQ
    irq                : out std_logic;

    -- Audio data
    audio_data         : in std_logic_vector(15 downto 0);

    -- io slave port
    ios_read           : in std_logic;
    ios_write          : in std_logic;
    ios_address        : in std_logic_vector(7 downto 0);
    ios_writedata      : in std_logic_vector(7 downto 0);
    ios_readdata       : out std_logic_vector(8 downto 0);
    ios_readdatavalid  : out std_logic;
    ios_waitrequest    : out std_logic;

    -- io master port
    iom_read           : out std_logic;
    iom_write          : out std_logic;
    iom_address        : out std_logic_vector(7 downto 0);
    iom_writedata      : out std_logic_vector(7 downto 0);
    iom_readdata       : in std_logic_vector(8 downto 0);
    iom_readdatavalid  : in std_logic;
    iom_waitrequest    : in std_logic
);
end audiodev;

architecture rtl of audiodev is

  signal address_latch_x, address_latch_r : std_logic_vector(7 downto 0);
  signal take_read_i : std_logic;
  signal readdata_x, readdata_r : std_logic_vector(7 downto 0);
  signal readdatavalid_x, readdatavalid_r : std_logic;

  signal read_status_i  : std_logic;
  signal write_addr_i   : std_logic;
  signal write_reg_i    : std_logic;
  signal read_reg_i     : std_logic;

  signal status_int_x, status_int_r       : std_logic;
  signal status_t1_x, status_t1_r         : std_logic;
  signal status_t2_x, status_t2_r         : std_logic;
  signal status_eos_x, status_eos_r       : std_logic;
  signal status_bufrdy_x, status_bufrdy_r : std_logic;
  signal status_pcmbsy_x, status_pcmbsy_r : std_logic;

  constant C_BUFRDY_TIME : integer := 720; -- wild guess
  signal reset_bufrdy_i : std_logic;
  signal bufrdy_timer_x, bufrdy_timer_r : integer range 0 to C_BUFRDY_TIME-1;

  signal unmask_t1_x, unmask_t1_r : std_logic;
  signal unmask_t2_x, unmask_t2_r : std_logic;
  signal unmask_eos_x, unmask_eos_r : std_logic;
  signal unmask_bufrdy_x, unmask_bufrdy_r : std_logic;

  constant C_TIMER_CLKDIV : integer := 286; -- 12.5 kHz timer base (3.58MHz/286 = 12.516 kHz)
  signal timer_clkdiv_x, timer_clkdiv_r : integer range 0 to C_TIMER_CLKDIV-1;
  signal timer_tick_x, timer_tick_r : std_logic;
  signal timer_t1_cnt_x, timer_t1_cnt_r : unsigned(7 downto 0);
  signal timer_t2_cnt_x, timer_t2_cnt_r : unsigned(9 downto 0);
  signal timer_t1_preset_x, timer_t1_preset_r : std_logic_vector(7 downto 0);
  signal timer_t2_preset_x, timer_t2_preset_r : std_logic_vector(7 downto 0);
  signal timer_t1_running_x, timer_t1_running_r : std_logic;
  signal timer_t2_running_x, timer_t2_running_r : std_logic;

  signal reg7_x, reg7_r                 : std_logic_vector(7 downto 0);

  constant C_SAMPLERATE_PRESCALE        : integer := 72; -- 3.579545 MHz / 72 = 49.716 kHz
  signal prescale_x, prescale_r         : integer range 0 to C_SAMPLERATE_PRESCALE-1;
  signal clkena_samp_x, clkena_samp_r   : std_logic;

  signal delta_x, delta_r               : unsigned(15 downto 0);
  signal step_x, step_r                 : unsigned(15 downto 0);
  signal step_add_i                     : unsigned(16 downto 0);

  signal mem_stop_x, mem_stop_r         : unsigned(18 downto 0);
  signal mem_start_x, mem_start_r       : unsigned(18 downto 0);
  signal mem_pointer_x, mem_pointer_r   : unsigned(18 downto 0);
  signal start_playing_i                : std_logic;
  signal play_sample_i                  : std_logic;
  signal write_samples_i                : std_logic;
  signal read_samples_i                 : std_logic;

begin

  irq <= status_int_r;

  iom_read      <= ios_read when take_read_i = '0' else '0';
  iom_write     <= ios_write;
  iom_address   <= ios_address;
  iom_writedata <= ios_writedata;
  ios_readdata  <= '1' & readdata_r when readdatavalid_r = '1' else iom_readdata;
  ios_readdatavalid <= iom_readdatavalid or readdatavalid_r;
  ios_waitrequest <= iom_waitrequest;

  read_status_i <= '1' when ios_read = '1' and ios_address = x"c0" else '0';
  write_addr_i <= '1' when ios_write = '1' and ios_address = x"c0" else '0';
  read_reg_i <= '1' when ios_read = '1' and ios_address = x"c1" else '0';
  write_reg_i <= '1' when ios_write = '1' and ios_address = x"c1" else '0';
  
  -- Generate IRQ
  status_int_x <= '1' when unmask_t1_r = '1' and status_t1_r = '1' else
                  '1' when unmask_t2_r = '1' and status_t2_r = '1' else
                  '1' when unmask_eos_r = '1' and status_eos_r = '1' else
                  '1' when unmask_bufrdy_r = '1' and status_bufrdy_r = '1' else
                  '0';

  -- Sample player stub
  p_sample : process(all)
  begin
    mem_stop_x <= mem_stop_r;
    mem_start_x <= mem_start_r;
    mem_pointer_x <= mem_pointer_r;

    mem_stop_x(2 downto 0) <= "111";
    mem_start_x(2 downto 0) <= "000";

    reg7_x <= reg7_r;

    step_x <= step_r;
    delta_x <= delta_r;

    status_eos_x <= status_eos_r;
    status_pcmbsy_x <= status_pcmbsy_r;
    status_bufrdy_x <= status_bufrdy_r;

    bufrdy_timer_x <= bufrdy_timer_r;
    reset_bufrdy_i <= '0';

    start_playing_i <= '0';
    play_sample_i <= '0';
    write_samples_i <= '0';
    
    -- Memory pointer
    if (start_playing_i = '1') then
      mem_pointer_x <= mem_start_r;
      step_x <= delta_r xor x"ffff";
    elsif (play_sample_i = '1') then
      mem_pointer_x <= mem_pointer_r + 1;
    elsif (write_samples_i = '1' or read_samples_i = '1') then
      mem_pointer_x <= mem_pointer_r + 2;
    end if;

    -- Sample prescaler
    clkena_samp_x <= '0';
    prescale_x <= prescale_r;
    if (clkena_3m58 = '1') then
      if (prescale_r < C_SAMPLERATE_PRESCALE-1) then
        prescale_x <= prescale_r + 1;
      else
        prescale_x <= 0;
        clkena_samp_x <= '1';
      end if;
    end if;

    -- Play sample
    step_add_i <= ('0' & step_r) + delta_r;
    if (status_pcmbsy_r = '1' and
        reg7_r(7 downto 6) = "10" and clkena_samp_r = '1') then
      step_x <= step_add_i(step_x'high downto 0);
      if (step_add_i(step_add_i'high) = '1') then
        -- Next sample
        play_sample_i <= '1';
        if (mem_pointer_r = mem_stop_r) then
          if (reg7_r(4) = '1') then
            -- loop this sample
            start_playing_i <= '1';
          end if;
        end if;
      end if;
    end if;

    -- Buffer ready timer
    if (reset_bufrdy_i = '1') then
      status_bufrdy_x <= '0';
      bufrdy_timer_x <= C_BUFRDY_TIME-1;
    elsif (reg7_r(7) = '1' and reg7_r(5) = '0') then
      if (play_sample_i = '1') then
        status_bufrdy_x <= '1';
      end if;
    elsif (clkena_3m58 = '1') then
      if (reg7_r(7) = '0') then
        if (bufrdy_timer_r > 0) then
          bufrdy_timer_x <= bufrdy_timer_r - 1;
        else
          -- If the BUF_RDY mask is cleared (e.g. by writing the value 0x80 to
          -- register R#4). Reading the status register still has the BUF_RDY
          -- bit set. Without this behavior demos like 'NOP Unknown reality'
          -- hang when testing the amount of sample ram or when uploading data
          -- to the sample ram.
          --
          -- Before this code was added, those demos also worked but only
          -- because we had a hack that always kept bit BUF_RDY set.
          --
          -- When the ADPCM unit is not performing any function (e.g. after a
          -- reset), the BUF_RDY bit should still be set. The AUDIO detection
          -- routine in 'MSX-Audio BIOS v1.3' depends on this. See
          --   [3533002] Y8950 not being detected by MSX-Audio v1.3
          --   https://sourceforge.net/tracker/?func=detail&aid=3533002&group_id=38274&atid=421861
          -- TODO I've implemented this as '(reg7 & R07_MODE) == 0', is this
          --      correct/complete?
          --if ((reg7_r(7)= '0' and reg7_r(5)= '1') or
          --    (reg7_r(7 downto 5) = "000")) then
          if (reg7_r(7) = '0' or reg7_r(5)= '0') then
            status_bufrdy_x <= '1';
          else
            status_bufrdy_x <= '0';
          end if;
        end if;
      end if;
    end if;

    -- Check sample ready
    if ((reg7_r(7) = '0' and reg7_r(5) = '1' and mem_pointer_r(18 downto 1) = mem_stop_r(18 downto 1)) or -- buffer read/write done, per byte, don't check LSB bit (nibble)
        (reg7_r(7) = '1' and reg7_r(5) = '1' and mem_pointer_r = mem_stop_r) -- playing, buffer increments per nibble
       ) then
      status_eos_x <= '1';
      status_pcmbsy_x <= '0';
    end if;

    -- Register write
    if (write_reg_i = '1') then
      case (address_latch_r) is
        when x"04" => -- FLAG_CONTROL
          if (ios_writedata(7) = '1') then
            -- Reset all flags
            status_eos_x <= '0';
            reset_bufrdy_i <= '1';
          end if;

        when x"07" => -- START/REC/MEM DATA/REPEAT/SP-OFF/-/-/RESET
          reg7_x <= ios_writedata;
          if (ios_writedata(0) = '1') then
            reg7_x(7) <= '0';
            status_pcmbsy_x <= '0';
          else
            if (ios_writedata(7) = '1') then
              start_playing_i <= '1';
              status_pcmbsy_x <= '1';
            else
              status_pcmbsy_x <= '0';
            end if;
          end if;
          
        when x"08" => -- CSM/KEY BOARD SPLIT/-/-/SAMPLE/DA AD/64K/ROM
          --rom_bank_x <= ios_writedata(0);
          --addr_64k_x <= ios_writedata(1);

        when x"09" => -- START ADDRESS (L)
          mem_start_x(10 downto 3) <= unsigned(ios_writedata);

        when x"0A" => -- START ADDRESS (H)
          mem_start_x(18 downto 11) <= unsigned(ios_writedata);

        when x"0B" => -- STOP ADDRESS (L)
          mem_stop_x(10 downto 3) <= unsigned(ios_writedata);

        when x"0C" => -- STOP ADDRESS (H)
          mem_stop_x(18 downto 11) <= unsigned(ios_writedata);

        when x"0D" => -- PRESCALE (L)
          -- not implemented

        when x"0E" => -- PRESCALE (H)
          -- not implemented

        when x"0F" => -- ADPCM-DATA
          if (reg7_r(7 downto 5) = "011") then
            -- external memory write
            write_samples_i <= '1';
            reset_bufrdy_i <= '1';
          end if;
          if (reg7_r(7 downto 5) = "100") then
            -- ADPCM synthesis from CPU
            reset_bufrdy_i <= '1';
          end if;

        when x"10" => -- DELTA-N (L)
          delta_x(7 downto 0) <= unsigned(ios_writedata);

        when x"11" => -- DELTA-N (H)
          delta_x(15 downto 8) <= unsigned(ios_writedata);

        when x"12" => -- ENVELOP CONTROL
          --volume_x <= ios_writedata;

        when x"1A" => -- PCM-DATA
          -- not implemented

        when others =>
      end case;
    end if;

  end process;

  -- Timers
  p_timers : process(all)
  begin
    timer_clkdiv_x <= timer_clkdiv_r;
    timer_t1_cnt_x <= timer_t1_cnt_r;
    timer_t2_cnt_x <= timer_t2_cnt_r;
    timer_t1_preset_x <= timer_t1_preset_r;
    timer_t2_preset_x <= timer_t2_preset_r;
    timer_t1_running_x <= timer_t1_running_r;
    timer_t2_running_x <= timer_t2_running_r;
    status_t1_x <= status_t1_r;
    status_t2_x <= status_t2_r;

    -- Generate 80us (12.5 kHz) timebase
    timer_tick_x <= '0';
    if (clkena_3m58 = '1') then
      if (timer_clkdiv_r = C_TIMER_CLKDIV-1) then
        timer_clkdiv_x <= 0;
        timer_tick_x <= '1';
      else
        timer_clkdiv_x <= timer_clkdiv_r + 1;
      end if;
    end if;

    -- Timer 1 (80us)
    if (timer_t1_running_r = '0') then
      timer_t1_cnt_x <= unsigned(timer_t1_preset_r);
    elsif (timer_tick_r = '1') then
      if (timer_t1_cnt_r = x"ff") then
        timer_t1_cnt_x <= unsigned(timer_t1_preset_r);
        status_t1_x <= '1';
      else
        timer_t1_cnt_x <= timer_t1_cnt_r + 1;
      end if;
    end if;

    -- Timer 2 (320us)
    if (timer_t2_running_r = '0') then
      timer_t2_cnt_x <= unsigned(timer_t2_preset_r & "00");
    elsif (timer_tick_r = '1') then
      if (timer_t2_cnt_r = x"ff" & "11") then
        timer_t2_cnt_x <= unsigned(timer_t2_preset_r & "00");
        status_t2_x <= '1';
      else
        timer_t2_cnt_x <= timer_t2_cnt_r + 1;
      end if;
    end if;

    -- Register write
    if (write_reg_i = '1') then
      case (address_latch_r) is
        when x"02" => -- TIMER1
          timer_t1_preset_x <= ios_writedata;
        when x"03" => -- TIMER2
          timer_t2_preset_x <= ios_writedata;
        when x"04" => -- FLAG_CONTROL
          if (ios_writedata(7) = '1') then
            -- Reset all flags
            status_t1_x <= '0';
            status_t2_x <= '0';
          else
            timer_t1_running_x <= ios_writedata(0);
            timer_t2_running_x <= ios_writedata(1);
          end if;
        when others =>
      end case;
    end if;
  end process;

  -- Status register
  p_status : process(all)
  begin
    address_latch_x <= address_latch_r;
    readdata_x <= x"00";
    readdatavalid_x <= '0';
    take_read_i <= '0';
    read_samples_i <= '0';

    unmask_t1_x <= unmask_t1_r;
    unmask_t2_x <= unmask_t2_r;
    unmask_eos_x <= unmask_eos_r;
    unmask_bufrdy_x <= unmask_bufrdy_r;

    if (write_addr_i = '1') then
      address_latch_x <= ios_writedata;
    end if;

    if (write_reg_i = '1') then
      case (address_latch_r) is
        when x"04" => -- FLAG CONTROL
          if (ios_writedata(7) = '0') then
            unmask_t1_x <= not ios_writedata(6);
            unmask_t2_x <= not ios_writedata(5);
            unmask_eos_x <= not ios_writedata(4);
            unmask_bufrdy_x <= not ios_writedata(3);
          end if;
        when others =>
      end case;
    end if;

    -- Register read
    if (read_reg_i = '1') then
      take_read_i <= '1';
      readdatavalid_x <= '1';
      case (address_latch_r) is
        when x"13" =>
          readdata_x <= audio_data(7 downto 0);
        when x"14" =>
          readdata_x <= audio_data(15 downto 8);
        when x"0F" => -- ADPCM-DATA
          take_read_i <= '0';
          readdatavalid_x <= '0';
          if (reg7_r(7 downto 5) = "001") then
            -- external memory write
            read_samples_i <= '1';
          end if;
        when x"19" =>
          readdata_x <= x"04";
        when others =>
          readdata_x <= x"ff";
      end case;
    end if;

    if (read_status_i = '1') then
      -- Status read
      take_read_i <= '1';
      readdata_x(7) <= status_int_r;
      readdata_x(6) <= status_t1_r and unmask_t1_r;
      readdata_x(5) <= status_t2_r and unmask_t2_r;
      readdata_x(4) <= status_eos_r and unmask_eos_r;
      readdata_x(3) <= status_bufrdy_r and unmask_bufrdy_r;
      readdata_x(2 downto 1) <= "11"; -- bit 1 and 2 are always 1
      readdata_x(0) <= status_pcmbsy_r;
      readdatavalid_x <= '1';
    end if;

  end process;

  process(clock, slot_reset)
  begin
    if rising_edge(clock) then
      if (slot_reset = '1') then
        address_latch_r <= x"00";
        status_int_r <= '0';
        status_t1_r <= '0';
        status_t2_r <= '0';
        status_eos_r <= '0';
        status_bufrdy_r <= '1';
        status_pcmbsy_r <= '0';
        unmask_t1_r <= '0';
        unmask_t2_r <= '0';
        unmask_eos_r <= '0';
        unmask_bufrdy_r <= '0';
        bufrdy_timer_r <= 0;
        prescale_r <= 0;
        clkena_samp_r <= '0';
        timer_clkdiv_r <= 0;
        timer_tick_r <= '0';
        timer_t1_cnt_r <= (others => '0');
        timer_t2_cnt_r <= (others => '0');
        timer_t1_preset_r <= (others => '0');
        timer_t2_preset_r <= (others => '0');
        timer_t1_running_r <= '0';
        timer_t2_running_r <= '0';
        reg7_r <= (others => '0');
        step_r <= (others => '0');
        delta_r <= (others => '0');
        mem_stop_r <= (others => '0');
        mem_start_r <= (others => '0');
        mem_pointer_r <= (others => '0');
      else
        address_latch_r <= address_latch_x;
        readdata_r <= readdata_x;
        readdatavalid_r <= readdatavalid_x;
        status_int_r <= status_int_x;
        status_t1_r <= status_t1_x;
        status_t2_r <= status_t2_x;
        status_eos_r <= status_eos_x;
        status_bufrdy_r <= status_bufrdy_x;
        status_pcmbsy_r <= status_pcmbsy_x;
        unmask_t1_r <= unmask_t1_x;
        unmask_t2_r <= unmask_t2_x;
        unmask_eos_r <= unmask_eos_x;
        unmask_bufrdy_r <= unmask_bufrdy_x;
        bufrdy_timer_r <= bufrdy_timer_x;
        prescale_r <= prescale_x;
        clkena_samp_r <= clkena_samp_x;
        timer_clkdiv_r <= timer_clkdiv_x;
        timer_tick_r <= timer_tick_x;
        timer_t1_cnt_r <= timer_t1_cnt_x;
        timer_t2_cnt_r <= timer_t2_cnt_x;
        timer_t1_preset_r <= timer_t1_preset_x;
        timer_t2_preset_r <= timer_t2_preset_x;
        timer_t1_running_r <= timer_t1_running_x;
        timer_t2_running_r <= timer_t2_running_x;
        reg7_r <= reg7_x;
        step_r <= step_x;
        delta_r <= delta_x;
        mem_stop_r <= mem_stop_x;
        mem_start_r <= mem_start_x;
        mem_pointer_r <= mem_pointer_x;
      end if;
    end if;
  end process;

end rtl;

  