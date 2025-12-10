----------------------------------------------------------
-- I2S Audio Decoder
--
-- Characteristics:
--   Channels              : 2 (stereo)
--   Line Interface Format : Linear
--   Data length           : 16 bits, signed
--   Data Ordering         : MSB first
--   Clock mode            : Rising edge
--   Data bit shift        : Right-shifted by one (I2S typical)
--
-- Author: Tim Brugman
----------------------------------------------------------

-----
-- Library
-----
LIBRARY ieee;
USE ieee.std_logic_1164.all;
USE ieee.numeric_std.all;
use work.common.all;

-----
-- Entity
-----
ENTITY i2s_decoder IS
PORT
(
  -- System clock
  clock               : IN  std_logic;
  reset               : IN  std_logic;

  -- i2s interface
  i2s_bclk            : IN  std_logic;
  i2s_lrclk           : IN  std_logic;
  i2s_data            : IN  std_logic;

  -- Decoded output
  audio_strobe_left   : OUT std_logic;
  audio_strobe_right  : OUT std_logic;
  audio_sample_left   : OUT std_logic_vector(15 downto 0);
  audio_sample_right  : OUT std_logic_vector(15 downto 0)
);
END ENTITY i2s_decoder;

-----
-- Architecture
-----
ARCHITECTURE rtl OF i2s_decoder IS

-----
-- Signals
-----  

  -- Filtered i2s signals
  signal i2s_bclk_x, i2s_bclk_r                       : std_logic;
  signal i2s_lrclk_i, i2s_lrclk_x, i2s_lrclk_r        : std_logic;
  signal i2s_data_i                                   : std_logic;

  -- i2s decoder
  constant BITS_PER_SAMPLE                            : integer := 16;
  signal i2s_shift_left_x, i2s_shift_left_r           : std_logic_vector(BITS_PER_SAMPLE+1 downto 0);
  signal i2s_shift_right_x, i2s_shift_right_r         : std_logic_vector(BITS_PER_SAMPLE+1 downto 0);
  signal audio_strobe_left_x, audio_strobe_left_r     : std_logic;
  signal audio_strobe_right_x, audio_strobe_right_r   : std_logic;

-----
-- Implementation
-----
BEGIN

  -----
  -- Outputs / glue
  -----
  audio_strobe_left <= audio_strobe_left_r;
  audio_strobe_right <= audio_strobe_right_r;
  audio_sample_left <= i2s_shift_left_r(BITS_PER_SAMPLE-1 downto 0);
  audio_sample_right <= i2s_shift_right_r(BITS_PER_SAMPLE-1 downto 0);

  ---------------------------------------------------------------------
  -- Input filters
  ---------------------------------------------------------------------
  i_filter: entity work.input_filter(rtl)
  GENERIC MAP (
    RESET_STATE => '0',
    DATA_WIDTH  => 3
  )
  PORT MAP (
    clk       => clock,
    clken     => '1',
    reset     => reset,

    input(0)  => i2s_bclk,
    input(1)  => i2s_lrclk,
    input(2)  => i2s_data,

    output(0) => i2s_bclk_x,
    output(1) => i2s_lrclk_i,
    output(2) => i2s_data_i
  );  

  -- Latch LRCLK on rising edge of BCLK
  i2s_lrclk_x <= i2s_lrclk_i when ( i2s_bclk_r = '0' and i2s_bclk_x = '1' ) else i2s_lrclk_r;

  -----
  -- i2s Decoder Left
  -----
  process(all)
  begin
    i2s_shift_left_x <= i2s_shift_left_r;
    audio_strobe_left_x <= '0';

    -- Act on rising edge of clock
    if( i2s_bclk_r = '0' and i2s_bclk_x = '1' ) then
      if( i2s_lrclk_r = '0' and i2s_lrclk_i = '1' ) then
        -- rising edge; start of new sample
        i2s_shift_left_x(i2s_shift_left_r'high downto 1) <= (others => '1');
        i2s_shift_left_x(0) <= '0';
      elsif( i2s_shift_left_r(i2s_shift_left_r'high) = '1' ) then
        -- busy shifting
        i2s_shift_left_x(i2s_shift_left_r'high downto 0) <= i2s_shift_left_r(i2s_shift_left_r'high - 1 downto 0) & i2s_data_i;
      end if;
      -- Strobe out after clocked in the last bit
      if( i2s_shift_left_r(i2s_shift_left_r'high downto i2s_shift_left_r'high - 1) = "10" ) then
        audio_strobe_left_x <= '1';
      end if;
    end if;
  end process;

  -----
  -- i2s Decoder Right
  -----
  process(all)
  begin
    i2s_shift_right_x <= i2s_shift_right_r;
    audio_strobe_right_x <= '0';

    -- Act on rising edge of clock
    if( i2s_bclk_r = '0' and i2s_bclk_x = '1' ) then
      if( i2s_lrclk_r = '1' and i2s_lrclk_i = '0' ) then
        -- falling edge; start of new sample
        i2s_shift_right_x(i2s_shift_right_r'high downto 1) <= (others => '1');
        i2s_shift_right_x(0) <= '0';
      elsif( i2s_shift_right_r(i2s_shift_right_r'high) = '1' ) then
        -- busy shifting
        i2s_shift_right_x(i2s_shift_right_r'high downto 0) <= i2s_shift_right_r(i2s_shift_right_r'high - 1 downto 0) & i2s_data_i;
      end if;
      -- Strobe out after clocked in the last bit
      if( i2s_shift_right_r(i2s_shift_right_r'high downto i2s_shift_right_r'high - 1) = "10" ) then
        audio_strobe_right_x <= '1';
      end if;
    end if;
  end process;

  -----
  -- Registers
  -----

  -- Registers
  process(clock, reset)
  begin
    if( reset = '1' ) then
      i2s_bclk_r <= '0';
      i2s_lrclk_r <= '0';
      i2s_shift_left_r <= (others => '0');
      audio_strobe_left_r <= '0';
      i2s_shift_right_r <= (others => '0');
      audio_strobe_right_r <= '0';
    elsif rising_edge(clock) then
      i2s_bclk_r <= i2s_bclk_x;
      i2s_lrclk_r <= i2s_lrclk_x;
      i2s_shift_left_r <= i2s_shift_left_x;
      audio_strobe_left_r <= audio_strobe_left_x;
      i2s_shift_right_r <= i2s_shift_right_x;
      audio_strobe_right_r <= audio_strobe_right_x;
    end if;
  end process;

END ARCHITECTURE rtl;
