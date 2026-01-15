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
-- Carnivore2 custom firmware toplevel
------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.common.all;

entity top is
  port(
    -- PLL
    clk50       : IN std_logic;

    -- ADC
    adc_md      : OUT std_logic_vector(1 downto 0);
    adc_scki    : OUT std_logic;
    adc_bck     : OUT std_logic;
    adc_lrck    : OUT std_logic;
    adc_dout    : IN std_logic;

    -- DAC
    dac_xsmt    : OUT std_logic;
    dac_lrck    : OUT std_logic;
    dac_din     : OUT std_logic;
    dac_bck     : OUT std_logic;
    dac_sck     : OUT std_logic;
    dac_flt     : OUT std_logic;
    dac_demp    : OUT std_logic;

    -- SLOT
    pSltClk     : IN std_logic;
    pSltRst1_n   : IN std_logic;
    pSltSltsls_n : IN std_logic;
    pSltIorq_n  : IN std_logic;
    pSltRd_n    : IN std_logic;
    pSltWr_n    : IN std_logic;
    pSltAdr     : IN std_logic_vector(15 downto 0);
    pSltDat     : INOUT std_logic_vector(7 downto 0);
    pSltBdir_n  : INOUT std_logic;

    pSltCs1     : IN std_logic;
    pSltCs2     : IN std_logic;
    pSltCs12    : IN std_logic;
    pSltRfsh_n  : IN std_logic;
    pSltWait_n  : INOUT std_logic;
    pSltInt_n   : INOUT std_logic;
    pSltM1_n    : IN std_logic;
    pSltMerq_n  : IN std_logic;

    pSltRsv5    : IN std_logic;
    pSltRsv16   : IN std_logic;

    pSltReady_n : OUT std_logic;

    -- FLASH ROM interface
    pFlAdr      : OUT std_logic_vector(22 downto 0);
    pFlDat      : INOUT std_logic_vector(7 downto 0);
    pFlCS_n     : OUT std_logic;
    pFlOE_n     : OUT std_logic;
    pFlW_n      : OUT std_logic;
    pFlRP_n     : OUT std_logic;
    pFlRB_b     : IN std_logic;
    pFlVpp      : OUT std_logic;

    -- RAM chip ( Flash bus + rsc )
    pRAMCS_n    : OUT std_logic;

    -- SD card interface
    SD_CLK      : out std_logic;
    SD_CS       : out std_logic;
    SD_MOSI     : inout std_logic;
    SD_MISO     : in std_logic;

    -- ESP
    ESP_GPIO4   : in std_logic;     -- ipc cs
    ESP_GPIO5   : in std_logic;     -- ipc clk
    ESP_GPIO6   : inout std_logic;  -- ipc d0
    ESP_GPIO7   : inout std_logic;  -- ipc d1
    ESP_GPIO15  : inout std_logic;  -- ipc d2
    ESP_GPIO16  : inout std_logic;  -- ipc d3
    ESP_GPIO17  : out std_logic;    -- ipc irq
    ESP_GPIO18  : in std_logic;     -- i2s mclk
    ESP_GPIO8   : in std_logic;     -- i2s bclk
    ESP_GPIO3   : in std_logic;     -- i2s lrclk
    ESP_GPIO46  : in std_logic;     -- i2s data esp->fpga
    ESP_GPIO9   : out std_logic;    -- i2s data fpga->esp
    ESP_GPIO10  : in std_logic;
    ESP_GPIO11  : in std_logic;
    ESP_GPIO12  : in std_logic;
    ESP_GPIO13  : in std_logic;

    -- Free pins on CompactFlash
    HD01        : in std_logic;
    HD12        : in std_logic;
    HD04        : in std_logic;
    HD11        : in std_logic;
    HD03        : in std_logic;

    --  EEPROM
    EECS        : OUT std_logic;
    EECK        : OUT std_logic;
    EEDI        : OUT std_logic;
    EEDO        : in std_logic;

    -- DEBUG
    J2_2        : OUT std_logic;
    J2_3        : OUT std_logic;
    J2_4        : OUT std_logic;
    J2_5        : OUT std_logic
);
end top;

architecture rtl of top is

  -- Clock and reset
  signal sysclk     : std_logic;
  signal locked     : std_logic;
  signal reset      : std_logic;
  signal clken1ms_i : std_logic;

  -- Clock divider for 3.58 MHz clock
  signal clkena_3m58   : std_logic;
  signal clkena_21m48  : std_logic;
  signal clockdiv21m48 : unsigned(15 downto 0);
  signal clockdiv3m58  : unsigned(15 downto 0);
  signal flankdet21m48 : std_logic;
  signal flankdet3m58  : std_logic;

  -- Avalon memory master
  signal mem_read_i           : std_logic;
  signal mem_write_i          : std_logic;
  signal mem_address_i        : std_logic_vector(16 downto 0);
  signal mem_writedata_i      : std_logic_vector(7 downto 0);
  signal mem_readdata_i       : std_logic_vector(8 downto 0);
  signal mem_readdatavalid_i  : std_logic;
  signal mem_waitrequest_i    : std_logic;

  -- Avalon io master
  signal iom_read_i           : std_logic;
  signal iom_write_i          : std_logic;
  signal iom_address_i        : std_logic_vector(7 downto 0);
  signal iom_writedata_i      : std_logic_vector(7 downto 0);
  signal iom_readdata_i       : std_logic_vector(8 downto 0);
  signal iom_readdatavalid_i  : std_logic;
  signal iom_waitrequest_i    : std_logic;

    -- io sniffer for writes
  signal ism_address_i              : std_logic_vector(8 downto 0);
  signal ism_write_i                : std_logic;
  signal ism_writedata_i            : std_logic_vector(7 downto 0);
  signal ism_waitrequest_i          : std_logic;

  -- Keyboard sniffer
  signal key_num_i                  : std_logic_vector(9 downto 0);
  signal key_shift_i                : std_logic;
  signal key_ctrl_i                 : std_logic;
  signal key_graph_i                : std_logic;
  signal key_code_i                 : std_logic;

  -- Synchronous resets
  signal slot_reset_i               : std_logic;
  signal soft_reset_i               : std_logic;

  -- Slot IRQ
  signal slot_irq_i                 : std_logic;
  
  -- Misc card
  signal our_slot_i                 : std_logic_vector(1 downto 0);
  signal enable_shadow_ram_i        : std_logic;
  signal slot_wait_i                : std_logic;

  -- SCC mode registers
  signal EseScc_MA19_i              : std_logic; -- EseScc_xxx was SccModeA
  signal EseScc_MA20_i              : std_logic;
  signal SccPlus_Enable_i           : std_logic; -- SccPlus_xxx was SccModeB
  signal SccPlus_AllRam_i           : std_logic;
  signal SccPlus_B0Ram_i            : std_logic;
  signal SccPlus_B1Ram_i            : std_logic;
  signal SccPlus_B2Ram_i            : std_logic;

  -- Functions
  signal beep_i                     : std_logic;
  signal enable_expand_i            : std_logic;
  signal enable_sd_a_i, enable_sd_b_i       : std_logic;
  signal enable_mapper_a_i, enable_mapper_b_i : std_logic;
  signal enable_fmpac_a_i, enable_fmpac_b_i   : std_logic;
  signal enable_scc_a_i, enable_scc_b_i       : std_logic;

  -- ESP avalon I/O port
  signal iom_esp_read               : std_logic;
  signal iom_esp_write              : std_logic;
  signal iom_esp_address            : std_logic_vector(7 downto 0);
  signal iom_esp_writedata          : std_logic_vector(7 downto 0);
  signal iom_esp_readdata           : std_logic_vector(8 downto 0);
  signal iom_esp_readdatavalid      : std_logic;
  signal iom_esp_waitrequest        : std_logic;

  -- Flash avalon slave port
  signal mem_flash_read_i           : std_logic;
  signal mem_flash_address_i        : std_logic_vector(22 downto 0);
  signal mem_flash_readdata_i       : std_logic_vector(7 downto 0);
  signal mem_flash_readdatavalid_i  : std_logic;
  signal mem_flash_waitrequest_i    : std_logic;

  -- RAM avalon slave port
  signal mem_ram_read_i             : std_logic;
  signal mem_ram_write_i            : std_logic;
  signal mem_ram_address_i          : std_logic_vector(20 downto 0);
  signal mem_ram_writedata_i        : std_logic_vector(7 downto 0);
  signal mem_ram_readdata_i         : std_logic_vector(7 downto 0);
  signal mem_ram_readdatavalid_i    : std_logic;
  signal mem_ram_waitrequest_i      : std_logic;

  -- Flash+RAM avalon slave port
  signal mem_flashram_read_i          : std_logic;
  signal mem_flashram_write_i         : std_logic;
  signal mem_flashram_address_i       : std_logic_vector(23 downto 0);
  signal mem_flashram_writedata_i     : std_logic_vector(7 downto 0);
  signal mem_flashram_readdata_i      : std_logic_vector(7 downto 0);
  signal mem_flashram_readdatavalid_i : std_logic;
  signal mem_flashram_waitrequest_i   : std_logic;

  -- Avalon bus: ESP32
  signal iom_esp_read_i               : std_logic;
  signal iom_esp_write_i              : std_logic;
  signal iom_esp_address_i            : std_logic_vector(7 downto 0);
  signal iom_esp_writedata_i          : std_logic_vector(7 downto 0);
  signal iom_esp_readdata_i           : std_logic_vector(8 downto 0);
  signal iom_esp_readdatavalid_i      : std_logic;
  signal iom_esp_waitrequest_i        : std_logic;

  -- Avalon bus: audiodev
  signal iom_audiodev_read_i          : std_logic;
  signal iom_audiodev_write_i         : std_logic;
  signal iom_audiodev_address_i       : std_logic_vector(7 downto 0);
  signal iom_audiodev_writedata_i     : std_logic_vector(7 downto 0);
  signal iom_audiodev_readdata_i      : std_logic_vector(8 downto 0);
  signal iom_audiodev_readdatavalid_i : std_logic;
  signal iom_audiodev_waitrequest_i   : std_logic;

  -- Avalon bus: Memory mapper
  signal mem_mapper_read_i          : std_logic;
  signal mem_mapper_write_i         : std_logic;
  signal mem_mapper_address_i       : std_logic_vector(15 downto 0);
  signal mem_mapper_writedata_i     : std_logic_vector(7 downto 0);
  signal mem_mapper_readdata_i      : std_logic_vector(7 downto 0);
  signal mem_mapper_readdatavalid_i : std_logic;
  signal mem_mapper_waitrequest_i   : std_logic;
  signal iom_mapper_read_i          : std_logic;
  signal iom_mapper_write_i         : std_logic;
  signal iom_mapper_address_i       : std_logic_vector(1 downto 0);
  signal iom_mapper_writedata_i     : std_logic_vector(7 downto 0);
  signal iom_mapper_readdata_i      : std_logic_vector(7 downto 0);
  signal iom_mapper_readdatavalid_i : std_logic;
  signal iom_mapper_waitrequest_i   : std_logic;
  -- RAM
  signal ram_mapper_read_i           : std_logic;
  signal ram_mapper_write_i          : std_logic;
  signal ram_mapper_address_i        : std_logic_vector(19 downto 0);
  signal ram_mapper_writedata_i      : std_logic_vector(7 downto 0);
  signal ram_mapper_readdata_i       : std_logic_vector(7 downto 0);
  signal ram_mapper_readdatavalid_i  : std_logic;
  signal ram_mapper_waitrequest_i    : std_logic;

  -- Avalon bus: FM-Pack (only the ROM)
  signal mem_fmpac_read_i           : std_logic;
  signal mem_fmpac_write_i          : std_logic;
  signal mem_fmpac_address_i        : std_logic_vector(13 downto 0);
  signal mem_fmpac_writedata_i      : std_logic_vector(7 downto 0);
  signal mem_fmpac_readdata_i       : std_logic_vector(7 downto 0);
  signal mem_fmpac_readdatavalid_i  : std_logic;
  signal mem_fmpac_waitrequest_i    : std_logic;
  -- ROM
  signal rom_fmpac_read_i           : std_logic;
  signal rom_fmpac_address_i        : std_logic_vector(13 downto 0);
  signal rom_fmpac_readdata_i       : std_logic_vector(7 downto 0);
  signal rom_fmpac_readdatavalid_i  : std_logic;
  signal rom_fmpac_waitrequest_i    : std_logic;

  -- Avalon bus: SCC
  signal mem_scc_read_i             : std_logic;
  signal mem_scc_write_i            : std_logic;
  signal mem_scc_address_i          : std_logic_vector(15 downto 0);
  signal mem_scc_writedata_i        : std_logic_vector(7 downto 0);
  signal mem_scc_readdata_i         : std_logic_vector(7 downto 0);
  signal mem_scc_readdatavalid_i    : std_logic;
  signal mem_scc_waitrequest_i      : std_logic;
  -- ROM
  signal mem_mega_read_i            : std_logic;
  signal mem_mega_write_i           : std_logic;
  signal mem_mega_address_i         : std_logic_vector(15 downto 0);
  signal mem_mega_writedata_i       : std_logic_vector(7 downto 0);
  signal mem_mega_readdata_i        : std_logic_vector(7 downto 0);
  signal mem_mega_readdatavalid_i   : std_logic;
  signal mem_mega_waitrequest_i     : std_logic;
  -- Audio
  signal scc_amp_i                  : std_logic_vector(15 downto 0);

  -- Avalon bus: MegaSD
  signal mem_sd_read_i              : std_logic;
  signal mem_sd_write_i             : std_logic;
  signal mem_sd_address_i           : std_logic_vector(15 downto 0);
  signal mem_sd_writedata_i         : std_logic_vector(7 downto 0);
  signal mem_sd_readdata_i          : std_logic_vector(7 downto 0);
  signal mem_sd_readdatavalid_i     : std_logic;
  signal mem_sd_waitrequest_i       : std_logic;
  -- ROM
  signal rom_sd_read_i              : std_logic;
  signal rom_sd_address_i           : std_logic_vector(16 downto 0);
  signal rom_sd_readdata_i          : std_logic_vector(7 downto 0);
  signal rom_sd_readdatavalid_i     : std_logic;
  signal rom_sd_waitrequest_i       : std_logic;

  -- Mega mapper
  signal iom_mega_read_i            : std_logic;
  signal iom_mega_write_i           : std_logic;
  signal iom_mega_address_i         : std_logic_vector(1 downto 0);
  signal iom_mega_writedata_i       : std_logic_vector(7 downto 0);
  signal iom_mega_readdata_i        : std_logic_vector(7 downto 0);
  signal iom_mega_readdatavalid_i   : std_logic;
  signal iom_mega_waitrequest_i     : std_logic;

  -- Audio
  signal audio_ack_i                : std_logic;
  signal audio_output_left_i        : std_logic_vector(15 downto 0);
  signal audio_output_right_i       : std_logic_vector(15 downto 0);
  signal audio_keyclick_i           : std_logic_vector(15 downto 0);

  -- I2S
  signal i2s_sclk_i                 : std_logic;
  signal i2s_bclk_i                 : std_logic;
  signal i2s_lrclk_i                : std_logic;
  signal i2s_din_i                  : std_logic;
  signal i2s_dout_i                 : std_logic;
  signal audio_sample_i             : std_logic_vector(15 downto 0);

  -- Debug
  signal count                      : unsigned(1 downto 0) := "00";

begin

  -- ADC
  adc_md <= "00";

  -- DAC
  dac_xsmt <= '1';
  dac_flt  <= '0';
  dac_demp <= '0';

  -- Debug
  J2_2 <= count(0);
  J2_3 <= count(1);
  J2_4 <= '0';
  J2_5 <= '0';

  -- Interrupt to the Z80
  pSltInt_n <= '0' when slot_irq_i = '1' else 'Z';

  -- Make '0' to unlock the Z80 bus, 'Z' to keep Z80 waiting till we're ready
  pSltReady_n <= slot_wait_i;
  pSltWait_n <= 'Z';

  process(sysclk)
  begin
    if rising_edge(sysclk) then
      if reset = '1' then
        count <= (others => '0');
      else
        count <= count + 1;
      end if;
    end if;
  end process;

  --------------------------------------------------------------------
  -- Clock / reset
  --------------------------------------------------------------------

  i_pll1 : entity work.mpll1(syn)
  port map
  (
    areset  => '0',
    inclk0  => clk50,
    c0      => sysclk,
    locked  => locked
  );

  i_clock_reset : entity work.generate_clock_enables(rtl)
  generic map(
    FREQ_MHZ => C_SYSTEM_CLOCK_KHZ / 1000
  )
  port map
  (
    clk => sysclk,
    pll_locked => locked,
    reset => reset,
    clken1ms => clken1ms_i
  );

  --------------------------------------------------------------------
  -- Clock divider for 21.48 MHz and 3.58 MHz clock
  --------------------------------------------------------------------

  clk3m58_i : process(sysclk, reset)
  begin
    if rising_edge(sysclk) then
      if (reset = '1') then
        clkena_3m58 <= '0';
        clkena_21m48 <= '0';
        clockdiv21m48 <= (others => '0');
        clockdiv3m58 <= (others => '0');
      else
        -- Clock enable for 21.48MHz -> 14075 / 65536 * 100 = 21.4767
        clkena_21m48 <= '0';
        clockdiv21m48 <= clockdiv21m48 + to_unsigned(14075, 16);
        flankdet21m48 <= clockdiv21m48(15);
        if (flankdet21m48 = '1' and clockdiv21m48(15) = '0') then
          clkena_21m48 <= '1';
        end if;

        -- Clock enable for 3.58MHz -> 2346 / 65536 * 100 = 3.5797
        clkena_3m58 <= '0';
        clockdiv3m58 <= clockdiv3m58 + to_unsigned(2346, 16);
        flankdet3m58 <= clockdiv3m58(15);
        if (flankdet3m58 = '1' and clockdiv3m58(15) = '0') then
          clkena_3m58 <= '1';
        end if;
      end if;
    end if;
  end process;

  --------------------------------------------------------------------
  -- Flash/RAM interface
  --------------------------------------------------------------------

  i_flash_ram_interface : entity work.flash_ram_interface(rtl)
  port map
  (
    -- clock and reset
    clock             => sysclk,
    slot_reset        => slot_reset_i,

    -- avalon slave ports for flash
    mes_port_a_read           => mem_flash_read_i,
    mes_port_a_write          => '0',
    mes_port_a_address        => enable_shadow_ram_i & mem_flash_address_i,
    mes_port_a_writedata      => (others => '0'),
    mes_port_a_readdata       => mem_flash_readdata_i,
    mes_port_a_readdatavalid  => mem_flash_readdatavalid_i,
    mes_port_a_waitrequest    => mem_flash_waitrequest_i,

    -- avalon slave ports for ram
    mes_port_b_read           => mem_ram_read_i,
    mes_port_b_write          => mem_ram_write_i,
    mes_port_b_address        => "100" & mem_ram_address_i,
    mes_port_b_writedata      => mem_ram_writedata_i,
    mes_port_b_readdata       => mem_ram_readdata_i,
    mes_port_b_readdatavalid  => mem_ram_readdatavalid_i,
    mes_port_b_waitrequest    => mem_ram_waitrequest_i,

    -- avalon slave ports for flash+ram
    mes_port_c_read           => mem_flashram_read_i,
    mes_port_c_write          => mem_flashram_write_i,
    mes_port_c_address        => mem_flashram_address_i,
    mes_port_c_writedata      => mem_flashram_writedata_i,
    mes_port_c_readdata       => mem_flashram_readdata_i,
    mes_port_c_readdatavalid  => mem_flashram_readdatavalid_i,
    mes_port_c_waitrequest    => mem_flashram_waitrequest_i,

    -- Parallel flash interface
    pFlAdr    => pFlAdr,
    pFlDat    => pFlDat,
    pFlCS_n   => pFlCS_n,
    pFlOE_n   => pFlOE_n,
    pFlW_n    => pFlW_n,
    pFlRP_n   => pFlRP_n,
    pFlRB_b   => pFlRB_b,
    pFlVpp    => pFlVpp,

    -- SRAM interface
    pRAMCS_n  => pRAMCS_n
  );

  i_flash_layout : work.flash_layout(rtl)
  port map
  (
    -- clock
    clock             => sysclk,
    slot_reset        => slot_reset_i,

    -- Flash memory
    mem_flash_read            => mem_flash_read_i,
    mem_flash_write           => open,
    mem_flash_address         => mem_flash_address_i,
    mem_flash_writedata       => open,
    mem_flash_readdata        => mem_flash_readdata_i,
    mem_flash_readdatavalid   => mem_flash_readdatavalid_i,
    mem_flash_waitrequest     => mem_flash_waitrequest_i,

    -- FM-Pack ROM
    mes_fmpac_read            => rom_fmpac_read_i,
    mes_fmpac_address         => rom_fmpac_address_i,
    mes_fmpac_readdata        => rom_fmpac_readdata_i,
    mes_fmpac_readdatavalid   => rom_fmpac_readdatavalid_i,
    mes_fmpac_waitrequest     => rom_fmpac_waitrequest_i,

    -- SD ROM
    mes_sd_read               => rom_sd_read_i,
    mes_sd_address            => rom_sd_address_i,
    mes_sd_readdata           => rom_sd_readdata_i,
    mes_sd_readdatavalid      => rom_sd_readdatavalid_i,
    mes_sd_waitrequest        => rom_sd_waitrequest_i
  );

  i_ram_layout : work.ram_layout(rtl)
  port map
  (
    -- clock
    clock                     => sysclk,
    slot_reset                => slot_reset_i,

    -- RAM memory
    mem_ram_read              => mem_ram_read_i,
    mem_ram_write             => mem_ram_write_i,
    mem_ram_address           => mem_ram_address_i,
    mem_ram_writedata         => mem_ram_writedata_i,
    mem_ram_readdata          => mem_ram_readdata_i,
    mem_ram_readdatavalid     => mem_ram_readdatavalid_i,
    mem_ram_waitrequest       => mem_ram_waitrequest_i,

    -- Memory mapper
    mes_mapper_read           => ram_mapper_read_i,
    mes_mapper_write          => ram_mapper_write_i,
    mes_mapper_address        => ram_mapper_address_i,
    mes_mapper_writedata      => ram_mapper_writedata_i,
    mes_mapper_readdata       => ram_mapper_readdata_i,
    mes_mapper_readdatavalid  => ram_mapper_readdatavalid_i,
    mes_mapper_waitrequest    => ram_mapper_waitrequest_i
  );

  --------------------------------------------------------------------
  -- ESP32 interface
  --------------------------------------------------------------------

  i_audiodev : entity work.audiodev(rtl)
  port map(
    -- clock and reset
    clock              => sysclk,
    slot_reset         => slot_reset_i,
    clkena_3m58        => clkena_3m58,

    -- IRQ
    irq                => slot_irq_i,

    -- Audio data
    audio_data         => audio_sample_i,

    -- io slave port   =>
    ios_read           => iom_esp_read_i,
    ios_write          => iom_esp_write_i,
    ios_address        => iom_esp_address_i,
    ios_writedata      => iom_esp_writedata_i,
    ios_readdata       => iom_esp_readdata_i,
    ios_readdatavalid  => iom_esp_readdatavalid_i,
    ios_waitrequest    => iom_esp_waitrequest_i,

    -- io master port  =>
    iom_read           => iom_audiodev_read_i,
    iom_write          => iom_audiodev_write_i,
    iom_address        => iom_audiodev_address_i,
    iom_writedata      => iom_audiodev_writedata_i,
    iom_readdata       => iom_audiodev_readdata_i,
    iom_readdatavalid  => iom_audiodev_readdatavalid_i,
    iom_waitrequest    => iom_audiodev_waitrequest_i
  );

  esp32 : entity work.spi_ipc(rtl)
  port map(
    -- Clock and reset
    clock                      => sysclk,
    slot_reset                 => slot_reset_i,
    slot_irq                   => open, --slot_irq_i,
    -- IO bus
    ios_read                   => iom_audiodev_read_i,
    ios_write                  => iom_audiodev_write_i,
    ios_address                => iom_audiodev_address_i,
    ios_writedata              => iom_audiodev_writedata_i,
    ios_readdata               => iom_audiodev_readdata_i,
    ios_readdatavalid          => iom_audiodev_readdatavalid_i,
    ios_waitrequest            => iom_audiodev_waitrequest_i,
    -- QSPI
    spi_cs_n                   => ESP_GPIO4,
    spi_clk                    => ESP_GPIO5,
    spi_data(0)                => ESP_GPIO6,
    spi_data(1)                => ESP_GPIO7,
    spi_data(2)                => ESP_GPIO15,
    spi_data(3)                => ESP_GPIO16,
    spi_irq                    => ESP_GPIO17
  );

  --------------------------------------------------------------------
  -- Cartridge slot interface
  --------------------------------------------------------------------

  slot : entity work.card_bus_slave(rtl)
  port map
  (
    -- System Clock
    clock             => sysclk,
    reset             => reset,

    -- MSX-Slot
    slt_reset_n       => pSltRst1_n,
    slt_sltsl_n       => pSltSltsls_n,
    slt_iorq_n        => pSltIorq_n,
    slt_rd_n          => pSltRd_n,
    slt_wr_n          => pSltWr_n,
    slt_addr          => pSltAdr,
    slt_data          => pSltDat,
    slt_bdir_n        => pSltBdir_n,
    slt_wait          => slot_wait_i,
    slt_m1_n          => pSltM1_n,
    slt_merq_n        => pSltMerq_n,

    -- Synchronous resets
    slot_reset        => slot_reset_i,
    soft_reset        => soft_reset_i,

    -- Misc
    our_slot          => our_slot_i,

    -- avalon memory master
    mem_address       => mem_address_i,
    mem_write         => mem_write_i,
    mem_writedata     => mem_writedata_i,
    mem_read          => mem_read_i,
    mem_readdata      => mem_readdata_i,
    mem_readdatavalid => mem_readdatavalid_i,
    mem_waitrequest   => mem_waitrequest_i,

    -- avalon io master
    iom_address       => iom_address_i,
    iom_write         => iom_write_i,
    iom_writedata     => iom_writedata_i,
    iom_read          => iom_read_i,
    iom_readdata      => iom_readdata_i,
    iom_readdatavalid => iom_readdatavalid_i,
    iom_waitrequest   => iom_waitrequest_i,

    -- io sniffer
    ism_address      => ism_address_i,
    ism_write        => ism_write_i,
    ism_writedata    => ism_writedata_i,
    ism_waitrequest  => ism_waitrequest_i
  );

  ----------------------------------------------------------------
  -- Keyboard sniffer
  ----------------------------------------------------------------
  key_sniff : entity work.keyboard_sniffer(rtl)
  port map(
    -- Clock and reset
    clock             => sysclk,
    slot_reset        => slot_reset_i,

    -- avalon slave ports for flash    -- io sniffer
    iss_address        => ism_address_i,
    iss_write          => ism_write_i,
    iss_writedata      => ism_writedata_i,
    iss_waitrequest    => ism_waitrequest_i,

    -- Keys
    key_num     => key_num_i,
    key_shift   => key_shift_i,
    key_ctrl    => key_ctrl_i,
    key_graph   => key_graph_i,
    key_code    => key_code_i
  );

  ----------------------------------------------------------------
  -- Configuration manager
  ----------------------------------------------------------------
  i_config_manager : entity work.config_manager(rtl)
  port map(
    -- Clock
    clock             => sysclk,
    slot_reset        => slot_reset_i,
    clken1ms          => clken1ms_i,

    -- Keys
    key_num           => key_num_i,
    key_shift         => key_shift_i,
    key_ctrl          => key_ctrl_i,
    key_graph         => key_graph_i,
    key_code          => key_code_i,

    -- Beep
    beep              => beep_i,

    -- Functions
    enable_sd         => enable_sd_a_i,
    enable_mapper     => enable_mapper_a_i,
    enable_fmpac      => enable_fmpac_a_i,
    enable_scc        => enable_scc_a_i
  );

  --------------------------------------------------------------------
  -- Address decoding
  --------------------------------------------------------------------
  i_address_decoding : entity work.address_decoding(rtl)
  port map
  (
    -- Clock and reset
    clock             => sysclk,
    slot_reset        => slot_reset_i,

    -- Avalon memory slave
    mes_read          => mem_read_i,
    mes_write         => mem_write_i,
    mes_address       => mem_address_i,
    mes_writedata     => mem_writedata_i,
    mes_readdata      => mem_readdata_i,
    mes_readdatavalid => mem_readdatavalid_i,
    mes_waitrequest   => mem_waitrequest_i,

    -- Avalon io slave
    ios_read          => iom_read_i,
    ios_write         => iom_write_i,
    ios_address       => iom_address_i,
    ios_writedata     => iom_writedata_i,
    ios_readdata      => iom_readdata_i,
    ios_readdatavalid => iom_readdatavalid_i,
    ios_waitrequest   => iom_waitrequest_i,

    -- Functions
    test_reg          => open,
    enable_expand     => enable_expand_i,
    enable_sd         => enable_sd_a_i and enable_sd_b_i,
    enable_mapper     => enable_mapper_a_i and enable_mapper_b_i,
    enable_fmpac      => enable_fmpac_a_i and enable_fmpac_b_i,
    enable_scc        => '1',

    -- ESP32
    iom_esp_read             => iom_esp_read_i,
    iom_esp_write            => iom_esp_write_i,
    iom_esp_address          => iom_esp_address_i,
    iom_esp_writedata        => iom_esp_writedata_i,
    iom_esp_readdata         => iom_esp_readdata_i,
    iom_esp_readdatavalid    => iom_esp_readdatavalid_i,
    iom_esp_waitrequest      => iom_esp_waitrequest_i,

    -- Memory mapper
    mem_mapper_read          => mem_mapper_read_i,
    mem_mapper_write         => mem_mapper_write_i,
    mem_mapper_address       => mem_mapper_address_i,
    mem_mapper_writedata     => mem_mapper_writedata_i,
    mem_mapper_readdata      => mem_mapper_readdata_i,
    mem_mapper_readdatavalid => mem_mapper_readdatavalid_i,
    mem_mapper_waitrequest   => mem_mapper_waitrequest_i,
    iom_mapper_read          => iom_mapper_read_i,
    iom_mapper_write         => iom_mapper_write_i,
    iom_mapper_address       => iom_mapper_address_i,
    iom_mapper_writedata     => iom_mapper_writedata_i,
    iom_mapper_readdata      => iom_mapper_readdata_i,
    iom_mapper_readdatavalid => iom_mapper_readdatavalid_i,
    iom_mapper_waitrequest   => iom_mapper_waitrequest_i,

    -- SD
    mem_sd_read              => mem_sd_read_i,
    mem_sd_write             => mem_sd_write_i,
    mem_sd_address           => mem_sd_address_i,
    mem_sd_writedata         => mem_sd_writedata_i,
    mem_sd_readdata          => mem_sd_readdata_i,
    mem_sd_readdatavalid     => mem_sd_readdatavalid_i,
    mem_sd_waitrequest       => mem_sd_waitrequest_i,

    -- FM-Pack
    mem_fmpac_read           => mem_fmpac_read_i,
    mem_fmpac_write          => mem_fmpac_write_i,
    mem_fmpac_address        => mem_fmpac_address_i,
    mem_fmpac_writedata      => mem_fmpac_writedata_i,
    mem_fmpac_readdata       => mem_fmpac_readdata_i,
    mem_fmpac_readdatavalid  => mem_fmpac_readdatavalid_i,
    mem_fmpac_waitrequest    => mem_fmpac_waitrequest_i,

    -- SCC
    mem_scc_read             => mem_scc_read_i,
    mem_scc_write            => mem_scc_write_i,
    mem_scc_address          => mem_scc_address_i,
    mem_scc_writedata        => mem_scc_writedata_i,
    mem_scc_readdata         => mem_scc_readdata_i,
    mem_scc_readdatavalid    => mem_scc_readdatavalid_i,
    mem_scc_waitrequest      => mem_scc_waitrequest_i,

    -- Mega mapper (I/O #f0)
    iom_mega_read            => iom_mega_read_i,
    iom_mega_write           => iom_mega_write_i,
    iom_mega_address         => iom_mega_address_i,
    iom_mega_writedata       => iom_mega_writedata_i,
    iom_mega_readdata        => iom_mega_readdata_i,
    iom_mega_readdatavalid   => iom_mega_readdatavalid_i,
    iom_mega_waitrequest     => iom_mega_waitrequest_i
  );

  ----------------------------------------------------------------
  -- Memory mapper (1MB)
  ----------------------------------------------------------------

  i_memory_mapper : entity work.memory_mapper(rtl)
  port map
  (
    -- clock and reset
    clock             => sysclk,
    slot_reset        => slot_reset_i,

    -- Avalon slave ports
    mes_mapper_read           => mem_mapper_read_i,
    mes_mapper_write          => mem_mapper_write_i,
    mes_mapper_address        => mem_mapper_address_i,
    mes_mapper_writedata      => mem_mapper_writedata_i,
    mes_mapper_readdata       => mem_mapper_readdata_i,
    mes_mapper_readdatavalid  => mem_mapper_readdatavalid_i,
    mes_mapper_waitrequest    => mem_mapper_waitrequest_i,
    ios_mapper_read           => iom_mapper_read_i,
    ios_mapper_write          => iom_mapper_write_i,
    ios_mapper_address        => iom_mapper_address_i,
    ios_mapper_writedata      => iom_mapper_writedata_i,
    ios_mapper_readdata       => iom_mapper_readdata_i,
    ios_mapper_readdatavalid  => iom_mapper_readdatavalid_i,
    ios_mapper_waitrequest    => iom_mapper_waitrequest_i,

    -- RAM master port
    ram_mapper_read           => ram_mapper_read_i,
    ram_mapper_write          => ram_mapper_write_i,
    ram_mapper_address        => ram_mapper_address_i,
    ram_mapper_writedata      => ram_mapper_writedata_i,
    ram_mapper_readdata       => ram_mapper_readdata_i,
    ram_mapper_readdatavalid  => ram_mapper_readdatavalid_i,
    ram_mapper_waitrequest    => ram_mapper_waitrequest_i
  );

  ----------------------------------------------------------------
  -- FM-PAC
  ----------------------------------------------------------------

  i_fmpac : entity work.fmpac(rtl)
  port map
  (
    -- clock and reset
    clock             => sysclk,
    slot_reset        => slot_reset_i,
    clkena_3m58       => clkena_3m58,

    -- Avalon slave ports
    mes_fmpac_read           => mem_fmpac_read_i,
    mes_fmpac_write          => mem_fmpac_write_i,
    mes_fmpac_address        => mem_fmpac_address_i,
    mes_fmpac_writedata      => mem_fmpac_writedata_i,
    mes_fmpac_readdata       => mem_fmpac_readdata_i,
    mes_fmpac_readdatavalid  => mem_fmpac_readdatavalid_i,
    mes_fmpac_waitrequest    => mem_fmpac_waitrequest_i,

    -- rom master port
    rom_fmpac_read           => rom_fmpac_read_i,
    rom_fmpac_address        => rom_fmpac_address_i,
    rom_fmpac_readdata       => rom_fmpac_readdata_i,
    rom_fmpac_readdatavalid  => rom_fmpac_readdatavalid_i,
    rom_fmpac_waitrequest    => rom_fmpac_waitrequest_i
  );

  ----------------------------------------------------------------
  -- SCC
  ----------------------------------------------------------------

  i_scc : entity work.scc(rtl)
  port map
  (
    -- clock and reset
    clock                 => sysclk,
    slot_reset            => slot_reset_i,
    clkena_3m58           => clkena_3m58,

    -- Configuration
    SccEna                => enable_scc_a_i and enable_scc_b_i,

    -- Avalon slave ports
    mes_scc_read          => mem_scc_read_i,
    mes_scc_write         => mem_scc_write_i,
    mes_scc_address       => mem_scc_address_i,
    mes_scc_writedata     => mem_scc_writedata_i,
    mes_scc_readdata      => mem_scc_readdata_i,
    mes_scc_readdatavalid => mem_scc_readdatavalid_i,
    mes_scc_waitrequest   => mem_scc_waitrequest_i,
    -- avalon master port
    mem_scc_read          => mem_mega_read_i,
    mem_scc_write         => mem_mega_write_i,
    mem_scc_address       => mem_mega_address_i,
    mem_scc_writedata     => mem_mega_writedata_i,
    mem_scc_readdata      => mem_mega_readdata_i,
    mem_scc_readdatavalid => mem_mega_readdatavalid_i,
    mem_scc_waitrequest   => mem_mega_waitrequest_i,

    -- SCC mode registers
    EseScc_MA19            => EseScc_MA19_i,
    EseScc_MA20            => EseScc_MA20_i,
    SccPlus_Enable         => SccPlus_Enable_i,
    SccPlus_AllRam         => SccPlus_AllRam_i,
    SccPlus_B0Ram          => SccPlus_B0Ram_i,
    SccPlus_B1Ram          => SccPlus_B1Ram_i,
    SccPlus_B2Ram          => SccPlus_B2Ram_i,

    -- Audio output
    SccAmp    => scc_amp_i
  );


  ----------------------------------------------------------------
  -- mega-ram like mapper
  ----------------------------------------------------------------

  i_mega_ram : entity work.mega_ram(rtl)
  port map
  (
    -- clock and reset
    clock                  => sysclk,
    slot_reset             => slot_reset_i,
    soft_reset             => soft_reset_i,

    -- Functions
    enable_expand          => enable_expand_i,
    enable_sd              => enable_sd_b_i,
    enable_mapper          => enable_mapper_b_i,
    enable_fmpac           => enable_fmpac_b_i,
    enable_scc             => enable_scc_b_i,

    -- EEPROM
    EECS                   => EECS,
    EECK                   => EECK,
    EEDI                   => EEDI,
    EEDO                   => EEDO,

    -- Misc
    our_slot               => our_slot_i,
    enable_shadow_ram      => enable_shadow_ram_i,

    -- SCC mode registers
    EseScc_MA19            => EseScc_MA19_i,
    EseScc_MA20            => EseScc_MA20_i,
    SccPlus_Enable         => SccPlus_Enable_i,
    SccPlus_AllRam         => SccPlus_AllRam_i,
    SccPlus_B0Ram          => SccPlus_B0Ram_i,
    SccPlus_B1Ram          => SccPlus_B1Ram_i,
    SccPlus_B2Ram          => SccPlus_B2Ram_i,

    -- avalon slave port
    mes_mega_read          => mem_mega_read_i,
    mes_mega_write         => mem_mega_write_i,
    mes_mega_address       => mem_mega_address_i,
    mes_mega_writedata     => mem_mega_writedata_i,
    mes_mega_readdata      => mem_mega_readdata_i,
    mes_mega_readdatavalid => mem_mega_readdatavalid_i,
    mes_mega_waitrequest   => mem_mega_waitrequest_i,
    -- 0xf0
    ios_mega_read          => iom_mega_read_i,
    ios_mega_write         => iom_mega_write_i,
    ios_mega_address       => iom_mega_address_i,
    ios_mega_writedata     => iom_mega_writedata_i,
    ios_mega_readdata      => iom_mega_readdata_i,
    ios_mega_readdatavalid => iom_mega_readdatavalid_i,
    ios_mega_waitrequest   => iom_mega_waitrequest_i,

    -- avalon master port
    mem_mega_read          => mem_flashram_read_i,
    mem_mega_write         => mem_flashram_write_i,
    mem_mega_address       => mem_flashram_address_i,
    mem_mega_writedata     => mem_flashram_writedata_i,
    mem_mega_readdata      => mem_flashram_readdata_i,
    mem_mega_readdatavalid => mem_flashram_readdatavalid_i,
    mem_mega_waitrequest   => mem_flashram_waitrequest_i
  );

  ----------------------------------------------------------------
  -- MegaSD
  ----------------------------------------------------------------

  i_megasd : entity work.megasd(rtl)
  port map
  (
    -- clock and reset
    clock                 => sysclk,
    slot_reset            => slot_reset_i,

    -- Avalon slave ports
    mes_sd_read           => mem_sd_read_i,
    mes_sd_write          => mem_sd_write_i,
    mes_sd_address        => mem_sd_address_i,
    mes_sd_writedata      => mem_sd_writedata_i,
    mes_sd_readdata       => mem_sd_readdata_i,
    mes_sd_readdatavalid  => mem_sd_readdatavalid_i,
    mes_sd_waitrequest    => mem_sd_waitrequest_i,

    -- rom master port
    rom_sd_read           => rom_sd_read_i,
    rom_sd_address        => rom_sd_address_i,
    rom_sd_readdata       => rom_sd_readdata_i,
    rom_sd_readdatavalid  => rom_sd_readdatavalid_i,
    rom_sd_waitrequest    => rom_sd_waitrequest_i,

    -- SD/EPC
    mmc_ck  => SD_CLK,
    mmc_cs  => SD_CS,
    mmc_di  => SD_MOSI,
    mmc_do  => SD_MISO
  );

  --------------------------------------------------------------------
  -- PSG + 1-bit keyclick
  --------------------------------------------------------------------

  i_psg : entity work.psg(rtl)
  port map
  (
    -- clock and reset
    clock          => sysclk,
    slot_reset     => slot_reset_i,
    clkena_21m48   => clkena_21m48,
    clkena_3m58    => clkena_3m58,
    clkena_sample  => audio_ack_i,

    -- io slave port (write-only)
    ios_write      => iom_esp_write_i,
    ios_address    => iom_esp_address_i,
    ios_writedata  => iom_esp_writedata_i,

    -- Output
    sample_out     => audio_keyclick_i
  );

  --------------------------------------------------------------------
  -- Waveform generator
  --------------------------------------------------------------------

  i_waveform_generator_left : entity work.waveform_generator(rtl)
  port map
  (
    clk => sysclk,
    reset => reset,
    audio_strobe => audio_ack_i,
    tone_enable => beep_i,
    tone_select => '1',
    audio_input => audio_keyclick_i,
    audio_output => audio_output_left_i
  );

  i_waveform_generator_right : entity work.waveform_generator(rtl)
  port map
  (
    clk => sysclk,
    reset => reset,
    audio_strobe => audio_ack_i,
    tone_enable => beep_i,
    tone_select => '1',
    audio_input => scc_amp_i,
    audio_output => audio_output_right_i
  );

  --------------------------------------------------------------------
  -- Audio
  --------------------------------------------------------------------

  i_i2s_decoder : entity work.i2s_decoder(rtl)
  port map
  (
    -- System clock
    clock               => sysclk,
    reset               => slot_reset_i,

    -- i2s interface
    i2s_bclk            => i2s_bclk_i,
    i2s_lrclk           => i2s_lrclk_i,
    i2s_din             => i2s_din_i,
    i2s_dout            => i2s_dout_i,

    -- Audio input
    audio_tx_left       => audio_output_left_i,
    audio_tx_right      => audio_output_right_i,
    audio_tx_ack        => audio_ack_i,

    -- Decoded output
    audio_rx_strobe     => open,
    audio_rx_left       => audio_sample_i,
    audio_rx_right      => open
  );

  i2s_sclk_i <= ESP_GPIO18;
  i2s_bclk_i <= ESP_GPIO8;
  i2s_lrclk_i <= ESP_GPIO3;
  i2s_din_i <= ESP_GPIO46;
  ESP_GPIO9 <= i2s_dout_i;

  dac_sck <= i2s_sclk_i;
  dac_bck <= i2s_bclk_i;
  dac_lrck <= i2s_lrclk_i;
  dac_din <= i2s_din_i;

  adc_scki <= i2s_sclk_i;
  adc_bck <= i2s_bclk_i;
  adc_lrck <= i2s_lrclk_i;

end rtl;
