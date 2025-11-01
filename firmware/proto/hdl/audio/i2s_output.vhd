----------------------------------------------------------
-- Generate I2S audio output
--
-- Author: Tim Brugman
----------------------------------------------------------

-----
-- Library
-----
LIBRARY ieee;
USE ieee.std_logic_1164.all;
USE ieee.numeric_std.all;
USE work.common.all;

-----
-- Entity
-----
ENTITY i2s_output IS
GENERIC
(
  MASTER_CLOCK_DIVIDER  : integer := 4;
  I2S_CLOCK_DIVIDER     : integer := 4;
  I2S_BITS_PER_CHANNEL  : integer := 16
);
PORT
(
  clock                 : IN  std_logic;
  reset                 : IN  std_logic;

  -- Parallel interface
  audio_ack             : OUT  std_logic;
  audio_left            : IN std_logic_vector(I2S_BITS_PER_CHANNEL-1 downto 0);
  audio_right           : IN std_logic_vector(I2S_BITS_PER_CHANNEL-1 downto 0);

  -- I2S interface
  i2s_mclk              : OUT  std_logic;
  i2s_lrclk             : OUT  std_logic;
  i2s_sclk              : OUT  std_logic;
  i2s_data              : OUT  std_logic
);
END ENTITY i2s_output;

-----
-- Architecture
-----
ARCHITECTURE rtl OF i2s_output IS

-----
-- Signals
-----  

  -- Clock dividers and clocks
  signal prescaler_main_x, prescaler_main_r : integer range 0 to MASTER_CLOCK_DIVIDER-1;
  signal clock_divided_x, clock_divided_r   : std_logic;
  signal clock_enable_x, clock_enable_r     : std_logic;
  signal i2s_clkdiv_x, i2s_clkdiv_r     : integer range 0 to I2S_CLOCK_DIVIDER-1;
  signal bitcount_x, bitcount_r         : integer range 0 to I2S_BITS_PER_CHANNEL-1;
  signal i2s_mclk_x, i2s_mclk_r         : std_logic;
  signal i2s_sclk_x, i2s_sclk_r         : std_logic;
  signal i2s_lrclk_x, i2s_lrclk_r       : std_logic;

  -- Shift register and output register
  signal load_data_x, load_data_r       : std_logic;
  signal shift_data_x, shift_data_r     : std_logic;
  signal data_ack_x, data_ack_r         : std_logic;
  signal shift_register_x, shift_register_r   : std_logic_vector((I2S_BITS_PER_CHANNEL*2)-1 downto 0);
  signal output_register_x, output_register_r : std_logic;

-----
-- Implementation
-----
BEGIN

  -- Outputs
  audio_ack <= data_ack_r;
  i2s_mclk <= i2s_mclk_r;
  i2s_lrclk <= i2s_lrclk_r;
  i2s_sclk <= i2s_sclk_r;
  i2s_data <= output_register_r;
  
  -- Pre-scalers
  process(prescaler_main_r, clock_divided_r)
  begin
    clock_divided_x <= clock_divided_r;
    clock_enable_x <= '0';
    if( prescaler_main_r /= MASTER_CLOCK_DIVIDER-1 ) then
      prescaler_main_x <= prescaler_main_r + 1;
    else
      prescaler_main_x <= 0;
      clock_enable_x <= '1';
      clock_divided_x <= not clock_divided_r;
    end if;
  end process;

  -- Shift register and output register
  process(shift_register_r, output_register_r, shift_data_r,
          load_data_r, audio_left, audio_right)
  begin
    shift_register_x <= shift_register_r;
    output_register_x <= output_register_r;
    data_ack_x <= '0';

    if( shift_data_r = '1' ) then
      -- Output register
      output_register_x <= shift_register_r(shift_register_r'high);
      -- Shift register
      if( load_data_r = '1' ) then
        -- Load with new data
        shift_register_x <= audio_left & audio_right;
        data_ack_x <= '1';
      else
        -- Shift
        shift_register_x <= shift_register_r(shift_register_r'high-1 downto 0) & '0';
      end if;
    end if;
  end process;

  -- I2S
  process(clock_enable_r, i2s_mclk_r, i2s_sclk_r, i2s_lrclk_r, bitcount_r, i2s_clkdiv_r)
  begin
    i2s_clkdiv_x <= i2s_clkdiv_r;
    i2s_mclk_x <= i2s_mclk_r;
    i2s_sclk_x <= i2s_sclk_r;
    i2s_lrclk_x <= i2s_lrclk_r;
    bitcount_x <= bitcount_r;
    load_data_x <= '0';
    shift_data_x <= '0';

    if( clock_enable_r = '1' ) then
      -- mclk
      i2s_mclk_x <= not i2s_mclk_r;

      -- i2sclk
      if( i2s_mclk_r = '0' ) then -- rising edge
        if( i2s_clkdiv_r /= I2S_CLOCK_DIVIDER-1 ) then
          i2s_clkdiv_x <= i2s_clkdiv_r + 1;
        else
          i2s_clkdiv_x <= 0;
          i2s_sclk_x <= not i2s_sclk_r;

          if( i2s_sclk_r = '1' ) then -- falling edge
            -- Shift new bit into output register
            shift_data_x <= '1';

            -- Count bits
            if( bitcount_r /= I2S_BITS_PER_CHANNEL-1 ) then
              bitcount_x <= bitcount_r + 1;
            else
              -- Flank of lrclk
              bitcount_x <= 0;
              i2s_lrclk_x <= not i2s_lrclk_r;

              if( i2s_lrclk_r = '1' ) then -- falling edge
                -- Load new data into shift register
                load_data_x <= '1';
              end if;
            end if;
          end if;
        end if;
      end if;

    end if;
  end process;

  process(clock, reset)
  begin
    if( reset = '1' ) then
      -- Clock dividers and clocks
      prescaler_main_r <= 0;
      clock_divided_r <= '0';
      clock_enable_r <= '0';
      i2s_clkdiv_r <= 0;
      bitcount_r <= 0;
      i2s_mclk_r <= '0';
      i2s_sclk_r <= '0';
      i2s_lrclk_r <= '0';
      -- Shift register and output register
      load_data_r <= '0';
      shift_data_r <= '0';
      data_ack_r <= '0';
      shift_register_r <= (others => '0');
      output_register_r <= '0';
    elsif( clock = '1' and clock'event ) then
      -- Clock dividers and clocks
      prescaler_main_r <= prescaler_main_x;
      clock_divided_r <= clock_divided_x;
      clock_enable_r <= clock_enable_x;
      i2s_clkdiv_r <= i2s_clkdiv_x;
      bitcount_r <= bitcount_x;
      i2s_mclk_r <= i2s_mclk_x;
      i2s_sclk_r <= i2s_sclk_x;
      i2s_lrclk_r <= i2s_lrclk_x;
      -- Shift register and output register
      load_data_r <= load_data_x;
      shift_data_r <= shift_data_x;
      data_ack_r <= data_ack_x;
      shift_register_r <= shift_register_x;
      output_register_r <= output_register_x;
    end if;
  end process;

END ARCHITECTURE rtl;
