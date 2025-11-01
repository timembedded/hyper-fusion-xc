----------------------------------------------------------------
-- SCC
----------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity scc_dummy is
  port(
    -- clock and reset
    clock                 : in std_logic;
    slot_reset            : in std_logic;
    clkena_3m58           : in std_logic;

    -- Configuration
    SccEna                : in std_logic;

    -- avalon slave port
    mes_scc_read          : in std_logic;
    mes_scc_write         : in std_logic;
    mes_scc_address       : in std_logic_vector(15 downto 0);
    mes_scc_writedata     : in std_logic_vector(7 downto 0);
    mes_scc_readdata      : out std_logic_vector(7 downto 0);
    mes_scc_readdatavalid : out std_logic;
    mes_scc_waitrequest   : out std_logic;

    -- avalon master port
    mem_scc_read          : out std_logic;
    mem_scc_write         : out std_logic;
    mem_scc_address       : out std_logic_vector(15 downto 0);
    mem_scc_writedata     : out std_logic_vector(7 downto 0);
    mem_scc_readdata      : in std_logic_vector(7 downto 0);
    mem_scc_readdatavalid : in std_logic;
    mem_scc_waitrequest   : in std_logic;

    -- SCC mode registers
    EseScc_MA19           : out std_logic; -- EseScc_xxx was SccModeA
    EseScc_MA20           : out std_logic;
    SccPlus_Enable        : out std_logic; -- SccPlus_xxx was SccModeB
    SccPlus_AllRam        : out std_logic;
    SccPlus_B0Ram         : out std_logic;
    SccPlus_B1Ram         : out std_logic;
    SccPlus_B2Ram         : out std_logic;

    -- Audio output
    SccAmp                : out std_logic_vector(10 downto 0)
  );
end scc_dummy;

architecture rtl of scc_dummy is
begin

  mem_scc_read <= mes_scc_read;
  mem_scc_write <= mes_scc_write;
  mem_scc_address <= mes_scc_address;
  mem_scc_writedata <= mes_scc_writedata;

  mes_scc_readdata <= mem_scc_readdata;
  mes_scc_readdatavalid <= mem_scc_readdatavalid;
  mes_scc_waitrequest <= mem_scc_waitrequest;

  EseScc_MA19    <= '0';
  EseScc_MA20    <= '0';
  SccPlus_Enable <= '0';
  SccPlus_AllRam <= '0';
  SccPlus_B0Ram  <= '0';
  SccPlus_B1Ram  <= '0';
  SccPlus_B2Ram  <= '0';

  -- Audio output
  SccAmp         <= (others => '0');

end rtl;
