----------------------------------------------------------
-- Generate audio waveform for testing purposes
--
-- Author: Tim Brugman
----------------------------------------------------------

-----
-- Library
-----
LIBRARY ieee;
USE ieee.std_logic_1164.all;
USE ieee.numeric_std.all;

-----
-- Entity
-----
ENTITY waveform_generator IS
PORT
(
  clk             : IN  std_logic;
  reset           : IN  std_logic;

  -- Audio interface
  audio_strobe    : IN  std_logic;
  audio_input     : IN std_logic_vector(15 downto 0);
  audio_output    : OUT std_logic_vector(15 downto 0);

  -- Control
  tone_enable     : IN std_logic;
  tone_select     : IN std_logic
);
END ENTITY waveform_generator;

-----
-- Architecture
-----
ARCHITECTURE rtl OF waveform_generator IS

-----
-- Signals
-----  

  constant MAX_VALUE_NEG : integer := -16;
  constant MAX_VALUE_POS : integer := 15;
  signal wave_count_x, wave_count_r       : integer range MAX_VALUE_NEG to MAX_VALUE_POS := 0;
  signal wave_out_x, wave_out_r           : std_logic_vector(15 downto 0);
  signal counting_down_x, counting_down_r : std_logic;
  signal extra_count_x, extra_count_r     : std_logic;

-----
-- Implementation
-----
BEGIN

  audio_output <= wave_out_r;

  -----
  -- Waveform generator
  -----
  process(audio_strobe, tone_enable, tone_select, counting_down_r,
          wave_count_r, wave_out_r, extra_count_r, audio_input)
  begin
    counting_down_x <= counting_down_r;
    wave_count_x <= wave_count_r;
    wave_out_x <= wave_out_r;
    extra_count_x <= '0';

    if( audio_strobe = '1' or extra_count_r = '1' ) then
      if( audio_strobe = '1' ) then
        if( tone_enable = '1' ) then
          wave_out_x <= std_logic_vector(to_signed(wave_count_r, 5)) & "00000000000";
        else
          wave_out_x <= audio_input;
        end if;
        extra_count_x <= tone_select;
      end if;
      if( counting_down_r = '0' ) then
        -- Counting up
        wave_count_x <= wave_count_r + 1;
        if( wave_count_r = MAX_VALUE_POS-1 ) then
          counting_down_x <= '1';
        end if;
      else
        -- Counting down
        wave_count_x <= wave_count_r - 1;
        if( wave_count_r = MAX_VALUE_NEG+1 ) then
          counting_down_x <= '0';
        end if;
      end if;
    end if;

  end process;

  -----
  -- Registers
  -----

  process(clk, reset)
  begin
    if( reset = '1' ) then
      counting_down_r <= '0';
      extra_count_r <= '0';
      wave_count_r <= 0;
      wave_out_r <= (others => '0');
    elsif( clk = '1' and clk'event ) then
      counting_down_r <= counting_down_x;
      extra_count_r <= extra_count_x;
      wave_count_r <= wave_count_x;
      wave_out_r <= wave_out_x;
    end if;
  end process;

END ARCHITECTURE rtl;
