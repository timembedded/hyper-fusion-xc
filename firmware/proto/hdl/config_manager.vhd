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
-- Configuration manager
------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity config_manager is
  port(
    -- Clock
    clock                     : in std_logic;
    slot_reset                : in std_logic;
    clken1ms                  : in std_logic;

    -- Keys
    key_num                   : in std_logic_vector(9 downto 0);
    key_shift                 : in std_logic;
    key_ctrl                  : in std_logic;
    key_graph                 : in std_logic;
    key_code                  : in std_logic;

    -- Beep
    beep                      : out std_logic;

    -- Functions
    enable_sd                 : out std_logic;
    enable_mapper             : out std_logic;
    enable_fmpac              : out std_logic;
    enable_scc                : out std_logic
);
end config_manager;

architecture rtl of config_manager is

  -- State
  type state_t is (S_RESET, S_WAIT, S_BEEP, S_DONE);
  signal state_x, state_r : state_t;

  -- Time
  signal time_count_x, time_count_r         : integer range 0 to 511;

  -- Audio feedback
  signal conf_changed_x, conf_changed_r   : std_logic;
  signal beep_x, beep_r                   : std_logic;

  -- Functions
  signal enable_sd_x, enable_sd_r         : std_logic;
  signal enable_mapper_x, enable_mapper_r : std_logic;
  signal enable_fmpac_x, enable_fmpac_r   : std_logic;

begin

  beep <= beep_r;
  enable_sd    <= enable_sd_r;
  enable_mapper <= enable_mapper_r;
  enable_fmpac  <= enable_fmpac_r;
  enable_scc <= '1'; -- Always enabled for now

  --------------------------------------------------------------------
  -- Config
  --------------------------------------------------------------------

  process(all)
  begin
    state_x <= state_r;
    time_count_x <= time_count_r;
    beep_x <= beep_r;
    conf_changed_x <= conf_changed_r;
    enable_sd_x <= enable_sd_r;
    enable_mapper_x <= enable_mapper_r;
    enable_fmpac_x <= enable_fmpac_r;

    if (clken1ms = '1') then

      case (state_r) is
        when S_RESET =>
          if (time_count_r /= 511) then
            time_count_x <= time_count_r + 1;
          else
            time_count_x <= 0;
            state_x <= S_WAIT;
          end if;
          if (key_graph = '1' and key_num(1) = '1') then
            -- Config 1 - MegaSD disabled
            enable_sd_x <= '0';
            enable_mapper_x <= '1';
            enable_fmpac_x <= '1';
            conf_changed_x <= '1';
          elsif (key_graph = '1' and key_num(2) = '1') then
            -- Config 2 - Mapper disabled
            enable_sd_x <= '1';
            enable_mapper_x <= '0';
            enable_fmpac_x <= '1';
            conf_changed_x <= '1';
          elsif (key_graph = '1' and key_num(3) = '1') then
            -- Config 2 - FM-PAC disabled
            enable_sd_x <= '1';
            enable_mapper_x <= '1';
            enable_fmpac_x <= '0';
            conf_changed_x <= '1';
          end if;
        when S_WAIT =>
          -- Wait for audio DAC to be stable
          if (time_count_r /= 511) then
            time_count_x <= time_count_r + 1;
          else
            time_count_x <= 0;
            state_x <= S_BEEP;
          end if;
        when S_BEEP =>
          -- Generate beep to confirm config
          if (time_count_r /= 100) then
            beep_x <= conf_changed_r;
            time_count_x <= time_count_r + 1;
          else
            beep_x <= '0';
            time_count_x <= 0;
            state_x <= S_DONE;
          end if;
        when S_DONE =>
          -- just do nothing
      end case;
    end if;
  end process;

  --------------------------------------------------------------------
  -- Registers
  --------------------------------------------------------------------
  process(clock)
  begin
    if rising_edge(clock) then
      if (slot_reset = '1') then
        state_r <= S_RESET;
        time_count_r <= 0;
        beep_r <= '0';
        conf_changed_r <= '0';
        enable_sd_r <= '1';
        enable_mapper_r <= '1';
        enable_fmpac_r <= '1';
      else
        state_r <= state_x;
        time_count_r <= time_count_x;
        beep_r <= beep_x;
        conf_changed_r <= conf_changed_x;
        enable_sd_r <= enable_sd_x;
        enable_mapper_r <= enable_mapper_x;
        enable_fmpac_r <= enable_fmpac_x;
      end if;
    end if;
  end process;

end rtl;
