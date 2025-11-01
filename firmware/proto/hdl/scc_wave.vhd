----------------------------------------------------------------
--  Title     : scc_wave.vhd
--  Function  : Sound Creation Chip (KONAMI)
--  Date      : 28th,August,2000
--  Revision  : 1.01
--  Author    : Kazuhiro TSUJIKAWA (ESE Artists' factory)
--              Tim Brugman (modified to run at high clock speeds)
----------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity scc_wave is
  port(
    -- clock and reset
    clock         : in std_logic;
    slot_reset    : in std_logic;
    clkena_3m58   : in std_logic;

    pSltAdr       : IN std_logic_vector(7 downto 0);
    pSltDat       : IN std_logic_vector(7 downto 0);

    SccRegWe      : IN std_logic;
    SccModWe      : IN std_logic;
    SccWavRd      : IN std_logic;
    SccWavWe      : IN std_logic;
    SccWavWx      : IN std_logic;
    SccWavAdr     : IN std_logic_vector(4 downto 0);
    SccWavDatIn   : IN std_logic_vector(7 downto 0);
    SccWavDatVld  : OUT std_logic;
    SccWavDatOut  : OUT std_logic_vector(7 downto 0);

    SccAmp        : OUT std_logic_vector(10 downto 0)
 );
end scc_wave;

architecture RTL of scc_wave is

  -- Wave memory
  type waveram_t is array (0 to 255) of std_logic_vector(7 downto 0);
  signal waveram            : waveram_t;
  signal waveram_inclock    : std_logic;
  signal SccWavRd_d1    : std_logic;
  signal SccWavRd_d2    : std_logic;

  -- Wave memory control
  signal WaveWe      : std_logic;
  signal WaveWrAdr   : std_logic_vector(7 downto 0);
  signal WaveRdAdr   : std_logic_vector(7 downto 0);
  signal WaveRdAdr_r : std_logic_vector(7 downto 0);
  signal iWaveDat    : std_logic_vector(7 downto 0);
  signal oWaveDat    : std_logic_vector(7 downto 0);

  -- SCC resisters
  signal SccFreqChA  : unsigned(11 downto 0);
  signal SccFreqChB  : unsigned(11 downto 0);
  signal SccFreqChC  : unsigned(11 downto 0);
  signal SccFreqChD  : unsigned(11 downto 0);
  signal SccFreqChE  : unsigned(11 downto 0);
  signal SccVolChA   : unsigned(3 downto 0);
  signal SccVolChB   : unsigned(3 downto 0);
  signal SccVolChC   : unsigned(3 downto 0);
  signal SccVolChD   : unsigned(3 downto 0);
  signal SccVolChE   : unsigned(3 downto 0);
  signal SccChanSel  : std_logic_vector(4 downto 0);
  signal SccModeSel  : std_logic_vector(7 downto 0);

  -- SCC temporaries
  signal SccChRdWav  : std_logic;
  signal SccChRdWav_d1  : std_logic;
  signal SccChRdWav_d2  : std_logic;
  signal SccRstChA   : std_logic;
  signal SccRstChB   : std_logic;
  signal SccRstChC   : std_logic;
  signal SccRstChD   : std_logic;
  signal SccRstChE   : std_logic;

  signal SccPtrChA   : unsigned(4 downto 0);
  signal SccPtrChB   : unsigned(4 downto 0);
  signal SccPtrChC   : unsigned(4 downto 0);
  signal SccPtrChD   : unsigned(4 downto 0);
  signal SccPtrChE   : unsigned(4 downto 0);

  signal SccChNum    : integer range 0 to 7;
 
  -- Mixer
  signal SccMixIn    : std_logic_vector(7 downto 0);
  signal SccMixEn    : std_logic;
  signal SccMixRst   : std_logic;
  signal SccMixRst1  : std_logic := '0';
  signal SccMixRst2  : std_logic := '0';
  signal SccMixRun   : std_logic;
  signal SccMixRun1  : std_logic := '0';
  signal SccMixRun2  : std_logic := '0';
  signal SccMixVol   : unsigned(3 downto 0);
  signal SccMixWav   : unsigned(10 downto 0);
  signal SccMixMul   : unsigned(14 downto 0);
  signal SccMix      : unsigned(14 downto 0);

begin

  ----------------------------------------------------------------
  -- Wave memory
  ----------------------------------------------------------------
  process (clock)
  begin
    if rising_edge(clock) then
      if (WaveWe = '1') then
        waveram(to_integer(unsigned(WaveWrAdr))) <= iWaveDat;
      end if;
      WaveRdAdr_r <= WaveRdAdr;
    end if;
  end process;

  oWaveDat <= waveram(to_integer(unsigned(WaveRdAdr_r))) when rising_edge(clock);

  ----------------------------------------------------------------
  -- Wave memory control
  ----------------------------------------------------------------
  WaveWrAdr  <= ("100" & SccWavAdr) when SccWavWx = '1' else pSltAdr;

  WaveRdAdr  <= pSltAdr(7 downto 0) when SccWavRd = '1' else
              ("000" & std_logic_vector(SccPtrChA)) when SccChNum = 0 else
              ("001" & std_logic_vector(SccPtrChB)) when SccChNum = 1 else
              ("010" & std_logic_vector(SccPtrChC)) when SccChNum = 2 else
              ("011" & std_logic_vector(SccPtrChD)) when SccChNum = 3 else
              ("100" & std_logic_vector(SccPtrChE));

  iWaveDat <= SccWavDatIn when SccWavWx = '1' else pSltDat;
  WaveWe   <= '1' when SccWavWe = '1' or SccWavWx = '1' else '0';

  -- read
  SccWavRd_d1 <= SccWavRd when rising_edge(clock);
  SccWavRd_d2 <= SccWavRd_d1 when rising_edge(clock);
  SccWavDatOut <= oWaveDat;
  SccWavDatVld <= SccWavRd_d2;

  ----------------------------------------------------------------
  -- Schedule sound processing
  ----------------------------------------------------------------
  process(clock, slot_reset)
    variable UpdatePending : std_logic;
  begin
    if (slot_reset = '1') then
      UpdatePending := '0';
      SccChRdWav <= '0';
      SccChRdWav_d1 <= '0';
      SccChRdWav_d2 <= '0';
      SccChNum <= 0;
    elsif (rising_edge(clock)) then
      SccChRdWav_d1 <= SccChRdWav;
      SccChRdWav_d2 <= SccChRdWav_d1;

      if (SccChRdWav_d2 = '1') then
        if (SccChNum = 7) then
          SccChNum <= 0;
        else
          SccChNum <= SccChNum + 1;
        end if;
      end if;

      if (UpdatePending = '1' and SccWavRd = '0') then
        UpdatePending := '0';
        SccChRdWav <= '1';
      else
        SccChRdWav <= '0';
      end if;

      if (clkena_3m58 = '1') then
        UpdatePending := '1';
      end if;

    end if;
  end process;

  ----------------------------------------------------------------
  -- SCC resister access
  ----------------------------------------------------------------
  process(clock, slot_reset)
  begin
    if (slot_reset = '1') then

      SccFreqChA <= (others => '0');
      SccFreqChB <= (others => '0');
      SccFreqChC <= (others => '0');
      SccFreqChD <= (others => '0');
      SccFreqChE <= (others => '0');
      SccVolChA  <= (others => '0');
      SccVolChB  <= (others => '0');
      SccVolChC  <= (others => '0');
      SccVolChD  <= (others => '0');
      SccVolChE  <= (others => '0');
      SccChanSel <= (others => '0');

      SccModeSel <= (others => '0');

      SccRstChA <= '0';
      SccRstChB <= '0';
      SccRstChC <= '0';
      SccRstChD <= '0';
      SccRstChE <= '0';

    elsif (rising_edge(clock)) then

      -- Mapped I/O port access on 9880-988Fh / B8A0-B8AF ... Resister write
      SccRstChA <= '0';
      SccRstChB <= '0';
      SccRstChC <= '0';
      SccRstChD <= '0';
      SccRstChE <= '0';
      if (SccRegWe = '1') then
        case pSltAdr(3 downto 0) is
          when "0000" => SccFreqChA(7 downto 0)  <= unsigned(pSltDat(7 downto 0)); SccRstChA <= SccModeSel(5);
          when "0001" => SccFreqChA(11 downto 8) <= unsigned(pSltDat(3 downto 0)); SccRstChA <= SccModeSel(5);
          when "0010" => SccFreqChB(7 downto 0)  <= unsigned(pSltDat(7 downto 0)); SccRstChB <= SccModeSel(5);
          when "0011" => SccFreqChB(11 downto 8) <= unsigned(pSltDat(3 downto 0)); SccRstChB <= SccModeSel(5);
          when "0100" => SccFreqChC(7 downto 0)  <= unsigned(pSltDat(7 downto 0)); SccRstChC <= SccModeSel(5);
          when "0101" => SccFreqChC(11 downto 8) <= unsigned(pSltDat(3 downto 0)); SccRstChC <= SccModeSel(5);
          when "0110" => SccFreqChD(7 downto 0)  <= unsigned(pSltDat(7 downto 0)); SccRstChD <= SccModeSel(5);
          when "0111" => SccFreqChD(11 downto 8) <= unsigned(pSltDat(3 downto 0)); SccRstChD <= SccModeSel(5);
          when "1000" => SccFreqChE(7 downto 0)  <= unsigned(pSltDat(7 downto 0)); SccRstChE <= SccModeSel(5);
          when "1001" => SccFreqChE(11 downto 8) <= unsigned(pSltDat(3 downto 0)); SccRstChE <= SccModeSel(5);
          when "1010" => SccVolChA(3 downto 0)   <= unsigned(pSltDat(3 downto 0));
          when "1011" => SccVolChB(3 downto 0)   <= unsigned(pSltDat(3 downto 0));
          when "1100" => SccVolChC(3 downto 0)   <= unsigned(pSltDat(3 downto 0));
          when "1101" => SccVolChD(3 downto 0)   <= unsigned(pSltDat(3 downto 0));
          when "1110" => SccVolChE(3 downto 0)   <= unsigned(pSltDat(3 downto 0));
          when others => SccChanSel(4 downto 0)  <= pSltDat(4 downto 0);
        end case;
      end if;

      -- Mapped I/O port access on 98C0-98FFh / B8C0-B8DFh ... Resister write
      if (SccModWe = '1') then
        SccModeSel <= pSltDat;
      end if;

    end if;

  end process;

  ----------------------------------------------------------------
  -- Tone generator
  ----------------------------------------------------------------
  process(clock, slot_reset)

    variable SccCntChA : unsigned(11 downto 0);
    variable SccCntChB : unsigned(11 downto 0);
    variable SccCntChC : unsigned(11 downto 0);
    variable SccCntChD : unsigned(11 downto 0);
    variable SccCntChE : unsigned(11 downto 0);

  begin

    if (slot_reset = '1') then

      SccCntChA := (others => '0');
      SccCntChB := (others => '0');
      SccCntChC := (others => '0');
      SccCntChD := (others => '0');
      SccCntChE := (others => '0');

      SccPtrChA <= (others => '0');
      SccPtrChB <= (others => '0');
      SccPtrChC <= (others => '0');
      SccPtrChD <= (others => '0');
      SccPtrChE <= (others => '0');

    elsif (rising_edge(clock)) then
      if (SccChRdWav = '1') then

        if (SccFreqChA(11 downto 3) = "000000000" or SccRstChA = '1') then
          SccPtrChA <= "00000";
          SccCntChA := SccFreqChA;
        elsif (SccCntChA = "000000000000") then
          SccPtrChA <= SccPtrChA + 1;
          SccCntChA := SccFreqChA;
        else
          SccCntChA := SccCntChA - 1;
        end if;

        if (SccFreqChB(11 downto 3) = "000000000" or SccRstChB = '1') then
          SccPtrChB <= "00000";
          SccCntChB := SccFreqChB;
        elsif (SccCntChB = "000000000000") then
          SccPtrChB <= SccPtrChB + 1;
          SccCntChB := SccFreqChB;
        else
          SccCntChB := SccCntChB - 1;
        end if;

        if (SccFreqChC(11 downto 3) = "000000000" or SccRstChC = '1') then
          SccPtrChC <= "00000";
          SccCntChC := SccFreqChC;
        elsif (SccCntChC = "000000000000") then
          SccPtrChC <= SccPtrChC + 1;
          SccCntChC := SccFreqChC;
        else
          SccCntChC := SccCntChC - 1;
        end if;

        if (SccFreqChD(11 downto 3) = "000000000" or SccRstChD = '1') then
          SccPtrChD <= "00000";
          SccCntChD := SccFreqChD;
        elsif (SccCntChD = "000000000000") then
          SccPtrChD <= SccPtrChD + 1;
          SccCntChD := SccFreqChD;
        else
          SccCntChD := SccCntChD - 1;
        end if;

        if (SccFreqChE(11 downto 3) = "000000000" or SccRstChE = '1') then
          SccPtrChE <= "00000";
          SccCntChE := SccFreqChE;
        elsif (SccCntChE = "000000000000") then
          SccPtrChE <= SccPtrChE + 1;
          SccCntChE := SccFreqChE;
        else
          SccCntChE := SccCntChE - 1;
        end if;

      end if;
    end if;

  end process;

  ----------------------------------------------------------------
  -- Mixer control
  ----------------------------------------------------------------
  process(clock, slot_reset)
  begin
    if (slot_reset = '1') then
      SccAmp <= (others => '0');
    elsif (rising_edge(clock)) then
      SccMixIn <= oWaveDat;
      SccMixRst <= '0';
      SccMixRun <= '0';
      SccMixEn <= '0';
      SccMixVol <= (others => '-');

      if (SccChRdWav_d2 = '1') then
        case SccChNum is
          when 0  =>
            SccMixRst <= '1';
            SccMixRun <= '1';
            SccMixEn <= SccChanSel(0);
            SccMixVol <= SccVolChA;
          when 1  =>
            SccMixRun <= '1';
            SccMixEn <= SccChanSel(1);
            SccMixVol <= SccVolChB;
          when 2  =>
            SccMixRun <= '1';
            SccMixEn <= SccChanSel(2);
            SccMixVol <= SccVolChC;
          when 3  =>
            SccMixRun <= '1';
            SccMixEn <= SccChanSel(3);
            SccMixVol <= SccVolChD;
          when 4  =>
            SccMixRun <= '1';
            SccMixEn <= SccChanSel(4);
            SccMixVol <= SccVolChE;
          when 7  =>
            SccAmp <= std_logic_vector(SccMix(14 downto 4));
          when others =>
        end case;
      end if;
    end if;
  end process;

  ----------------------------------------------------------------
  -- Mixer
  ----------------------------------------------------------------
  process(clock)
  begin
    if (rising_edge(clock)) then

      -- Clock 1 - Input
      SccMixRun1 <= SccMixRun;
      SccMixRst1 <= SccMixRst;
      if (SccMixEn = '1') then
        SccMixWav <= unsigned("000" & unsigned(SccMixIn xor x"80"));
      else
        SccMixWav <= "000" & x"80";
      end if;

      -- Clock 2 - Multiply
      SccMixRun2 <= SccMixRun1;
      SccMixRst2 <= SccMixRst1;
      SccMixMul <= unsigned(SccMixWav) * SccMixVol;

      -- Clock 3 - Add
      if (SccMixRun2 = '1') then
        if (SccMixRst2 = '1') then
          SccMix <= SccMixMul;
        else
          SccMix <= SccMix + SccMixMul;
        end if;
      end if;
    end if;
  end process;

end RTL;
