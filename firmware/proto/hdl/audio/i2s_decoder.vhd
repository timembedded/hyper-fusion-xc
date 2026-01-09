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
  clock             : IN  std_logic;
  reset             : IN  std_logic;

  -- i2s interface
  i2s_bclk          : IN  std_logic;
  i2s_lrclk         : IN  std_logic;
  i2s_din           : IN  std_logic;
  i2s_dout          : OUT std_logic;

  -- Audio input to transmit
  audio_tx_left     : IN  std_logic_vector(15 downto 0);
  audio_tx_right    : IN  std_logic_vector(15 downto 0);
  audio_tx_ack      : OUT std_logic;

  -- Decoded output
  audio_rx_strobe   : OUT std_logic;
  audio_rx_left     : OUT std_logic_vector(15 downto 0);
  audio_rx_right    : OUT std_logic_vector(15 downto 0)
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
  signal i2s_din_i                                    : std_logic;

  -- i2s decoder
  constant BITS_PER_SAMPLE                            : integer := 16;
  signal i2s_shift_in_x, i2s_shift_in_r               : std_logic_vector(BITS_PER_SAMPLE-1 downto 0);
  signal i2s_shift_out_x, i2s_shift_out_r             : std_logic_vector(BITS_PER_SAMPLE*2-1 downto 0);
  signal i2s_latch_out_x, i2s_latch_out_r             : std_logic;
  signal audio_tx_ack_x, audio_tx_ack_r               : std_logic;
  signal audio_rx_right_x, audio_rx_right_r           : std_logic_vector(BITS_PER_SAMPLE-1 downto 0);
  signal audio_rx_left_x, audio_rx_left_r             : std_logic_vector(BITS_PER_SAMPLE-1 downto 0);
  signal audio_rx_strobe_x, audio_rx_strobe_r         : std_logic;

-----
-- Implementation
-----
BEGIN

  -----
  -- Outputs / glue
  -----
  audio_rx_left <= audio_rx_left_r;
  audio_rx_right <= audio_rx_right_r;
  audio_rx_strobe <= audio_rx_strobe_r;
  audio_tx_ack <= audio_tx_ack_r;

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
    input(2)  => i2s_din,

    output(0) => i2s_bclk_x,
    output(1) => i2s_lrclk_i,
    output(2) => i2s_din_i
  );

  -- I2S data output
  i2s_dout <= i2s_shift_out_r(i2s_shift_out_r'high);

  -----
  -- i2s Decoder Left
  -----
  process(all)
  begin
    i2s_lrclk_x <= i2s_lrclk_r;
    i2s_shift_in_x <= i2s_shift_in_r;
    i2s_shift_out_x <= i2s_shift_out_r;
    audio_rx_right_x <= audio_rx_right_r;
    audio_rx_left_x <= audio_rx_left_r;
    audio_tx_ack_x <= '0';
    i2s_latch_out_x <= i2s_latch_out_r;
    audio_rx_strobe_x <= '0';

    -- Output data in falling edge of bit clock
    if( i2s_bclk_r = '1' and i2s_bclk_x = '0' ) then
      if( i2s_latch_out_r = '1' ) then
        i2s_latch_out_x <= '0';
        audio_tx_ack_x <= '1';
        i2s_shift_out_x <= audio_tx_left & audio_tx_right;
      else
        i2s_shift_out_x <= i2s_shift_out_r(i2s_shift_out_r'high - 1 downto 0) & '0';
      end if;
    end if;

    -- Act on rising edge of bit clock
    if( i2s_bclk_r = '0' and i2s_bclk_x = '1' ) then
      -- Latch LRCLK
      i2s_lrclk_x <= i2s_lrclk_i;

      -- Input shift register
      i2s_shift_in_x <= i2s_shift_in_r(i2s_shift_in_r'high - 1 downto 0) & i2s_din_i;

      -- Start new sample at falling edge of LRCLK
      if( i2s_lrclk_r = '1' and i2s_lrclk_i = '0' ) then
        -- Latch output data on next falling edge of bit clock
        i2s_latch_out_x <= '1';
        -- Latch input data for right channel
        audio_rx_right_x <= i2s_shift_in_x;
        -- Input sample complete
        audio_rx_strobe_x <= '1';
      elsif( i2s_lrclk_r = '0' and i2s_lrclk_i = '1' ) then
        -- Latch input data for left channel
        audio_rx_left_x <= i2s_shift_in_x;
      end if;
    end if;
  end process;

  -----
  -- Registers
  -----
  process(clock, reset)
  begin
    if( reset = '1' ) then
      i2s_bclk_r <= '0';
      i2s_lrclk_r <= '0';
      i2s_shift_in_r <= (others => '0');
      i2s_shift_out_r <= (others => '0');
      i2s_latch_out_r <= '0';
      audio_tx_ack_r <= '0';
      audio_rx_right_r <= (others => '0');
      audio_rx_left_r <= (others => '0');
      audio_rx_strobe_r <= '0';
    elsif rising_edge(clock) then
      i2s_bclk_r <= i2s_bclk_x;
      i2s_lrclk_r <= i2s_lrclk_x;
      i2s_shift_in_r <= i2s_shift_in_x;
      i2s_shift_out_r <= i2s_shift_out_x;
      i2s_latch_out_r <= i2s_latch_out_x;
      audio_tx_ack_r <= audio_tx_ack_x;
      audio_rx_right_r <= audio_rx_right_x;
      audio_rx_left_r <= audio_rx_left_x;
      audio_rx_strobe_r <= audio_rx_strobe_x;
    end if;
  end process;

END ARCHITECTURE rtl;
