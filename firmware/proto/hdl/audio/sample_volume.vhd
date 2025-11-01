library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.std_logic_unsigned.all;

entity sample_volume is
port(
  clock   : IN std_logic;
  sin16   : IN std_logic_vector(15 downto 0);
  sout16  : OUT std_logic_vector(15 downto 0);
  level   : IN std_logic_vector(2 downto 0)
);
end sample_volume;

architecture rtl of sample_volume is

  signal c1_sgin   : std_logic;
  signal c1_uin16  : std_logic_vector(15 downto 0);
  signal c1_M5     : std_logic_vector(4 downto 0);

  signal c2_sgin   : std_logic;
  signal c2_uout21 : std_logic_vector(20 downto 0);

  signal c3_sout16 : std_logic_vector(15 downto 0);

begin

  sout16 <= c3_sout16;

  process(clock)
    variable sgin : std_logic;
  begin
    if rising_edge(clock) then
      -- Clock 1

      sgin := sin16(15);
      c1_sgin <= sgin;

      if sgin = '0' then
        c1_uin16 <= sin16;
      else
        c1_uin16 <= "0000000000000000" - sin16;
      end if;

      case (level) is
        when "000" =>
          c1_M5 <= "00101";
        when "001" =>
          c1_M5 <= "00110";
        when "010" =>
          c1_M5 <= "00111";
        when "011" =>
          c1_M5 <= "01000";
        when "100" =>
          c1_M5 <= "01010";
        when "101" =>
          c1_M5 <= "01100";
        when "110" =>
          c1_M5 <= "01110";
        when others =>
          c1_M5 <= "10000";
      end case;

      -- Clock 2
      c2_sgin <= c1_sgin;
      c2_uout21 <= c1_m5 * c1_uin16;

      -- Clock 3
      if c2_sgin = '0' then
        c3_sout16 <= c2_uout21(19 downto 4);
      else
        c3_sout16 <= "0000000000000000" - c2_uout21(19 downto 4);
      end if;
    end if;
  end process;

end rtl;