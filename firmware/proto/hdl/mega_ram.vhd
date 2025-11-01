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
-- Mega-RAM mapper
------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity mega_ram is
  port(
    -- clock and reset
    clock                  : in std_logic;
    slot_reset             : in std_logic;
    soft_reset             : in std_logic;

    -- EEPROM
    EECS                   : out std_logic;
    EECK                   : out std_logic;
    EEDI                   : out std_logic;
    EEDO                   : in std_logic;

    -- Config
    enable_expand          : out std_logic;
    enable_sd              : out std_logic;
    enable_mapper          : out std_logic;
    enable_fmpac           : out std_logic;
    enable_scc             : out std_logic;

    -- Misc
    our_slot               : in std_logic_vector(1 downto 0);
    enable_shadow_ram      : out std_logic;

    -- SCC mode registers
    EseScc_MA19            : in std_logic;
    EseScc_MA20            : in std_logic;
    SccPlus_Enable         : in std_logic;
    SccPlus_AllRam         : in std_logic;
    SccPlus_B0Ram          : in std_logic;
    SccPlus_B1Ram          : in std_logic;
    SccPlus_B2Ram          : in std_logic;

    -- avalon slave port
    mes_mega_read          : in std_logic;
    mes_mega_write         : in std_logic;
    mes_mega_address       : in std_logic_vector(15 downto 0);
    mes_mega_writedata     : in std_logic_vector(7 downto 0);
    mes_mega_readdata      : out std_logic_vector(7 downto 0);
    mes_mega_readdatavalid : out std_logic;
    mes_mega_waitrequest   : out std_logic;
    -- 0xf0
    ios_mega_read          : in std_logic;
    ios_mega_write         : in std_logic;
    ios_mega_address       : in std_logic_vector(1 downto 0);
    ios_mega_writedata     : in std_logic_vector(7 downto 0);
    ios_mega_readdata      : out std_logic_vector(7 downto 0);
    ios_mega_readdatavalid : out std_logic;
    ios_mega_waitrequest   : out std_logic;

    -- avalon master port
    mem_mega_read          : out std_logic;
    mem_mega_write         : out std_logic;
    mem_mega_address       : out std_logic_vector(23 downto 0);
    mem_mega_writedata     : out std_logic_vector(7 downto 0);
    mem_mega_readdata      : in std_logic_vector(7 downto 0);
    mem_mega_readdatavalid : in std_logic;
    mem_mega_waitrequest   : in std_logic
  );
end mega_ram;

architecture rtl of mega_ram is

  signal EECS1                      : std_logic;
  signal EECK1                      : std_logic;
  signal EEDI1                      : std_logic;

  type map_bank_t is record
    Mask     : std_logic_vector(7 downto 0);
    Addr     : std_logic_vector(7 downto 0);
    Reg      : std_logic_vector(7 downto 0);
    Mult     : std_logic_vector(7 downto 0);
    MaskR    : std_logic_vector(7 downto 0);
    AdrD     : std_logic_vector(7 downto 0);
  end record;

  signal aMconf                     : std_logic_vector(7 downto 0);
  signal Mconf                      : std_logic_vector(7 downto 0);
  signal DecMDR                     : std_logic;
  signal RloadEn                    : std_logic;
  signal NSC, NSC_SCCP              : std_logic; -- Non standard
  signal PF0_RV                     : std_logic_vector(1 downto 0);
  signal PFXN                       : std_logic_vector(1 downto 0):= "00";

  signal CardMDR                    : std_logic_vector(7 downto 0);
  signal AddrM0                     : std_logic_vector(7 downto 0);
  signal AddrM1                     : std_logic_vector(7 downto 0);
  signal AddrM2                     : std_logic_vector(6 downto 0);
  signal AddrFR                     : std_logic_vector(6 downto 0);

  signal R1                         : map_bank_t;
  signal R2                         : map_bank_t;
  signal R3                         : map_bank_t;
  signal R4                         : map_bank_t;

  type page_size_t is (PAGE_64k, PAGE_32k, PAGE_16k, PAGE_8k, PAGE_NONE);
  signal MR1A_c1_i, MR1A_c1_r       : page_size_t;
  signal MR2A_c1_i, MR2A_c1_r       : page_size_t;
  signal MR3A_c1_i, MR3A_c1_r       : page_size_t;
  signal MR4A_c1_i, MR4A_c1_r       : page_size_t;

  signal card_seq_r                 : integer range 0 to 3;
  signal card_det_r                 : std_logic;
  signal card_info_x, card_info_r   : std_logic_vector(23 downto 0);
  signal card_info_latch_r          : std_logic;

  signal ios_mega_readdata_i        : std_logic_vector(7 downto 0);

  signal mes_mega_reg_addr_i        : std_logic_vector(5 downto 0);
  signal mes_mega_reg_addr_r        : std_logic_vector(5 downto 0);
  signal mes_mega_reg_readdata_x    : std_logic_vector(7 downto 0);
  signal mes_mega_reg_readdata_r    : std_logic_vector(7 downto 0);

  signal mem_mega_read_c1_i         : std_logic;
  signal mem_mega_write_c1_i        : std_logic;

  signal mem_mega_read_c1_r         : std_logic;
  signal mem_mega_write_c1_r        : std_logic;
  signal mem_mega_address_c1_r      : std_logic_vector(15 downto 0);
  signal mem_mega_writedata_c1_r    : std_logic_vector(7 downto 0);
  signal mem_mega_page_i            : std_logic_vector(10 downto 0);
  signal mem_mega_use_ram_i         : std_logic;

  signal mem_mega_read_c2_i         : std_logic;
  signal mem_mega_rdff_c2_i         : std_logic;
  signal mem_mega_read_c2_r         : std_logic;
  signal mem_mega_rdff_c2_r         : std_logic;
  signal mem_mega_write_c2_i        : std_logic;
  signal mem_mega_write_c2_r        : std_logic;
  signal mem_mega_address_c2_r      : std_logic_vector(15 downto 0);
  signal mem_mega_writedata_c2_r    : std_logic_vector(7 downto 0);
  signal mem_mega_page_c2_r         : std_logic_vector(10 downto 0);
  signal mem_mega_use_ram_c2_r      : std_logic;

  signal mem_mega_map_i                               : std_logic_vector(10 downto 0);
  signal mem_mega_address_i                           : std_logic_vector(23 downto 0);
  signal mem_mega_read_r, mem_mega_read_x             : std_logic;
  signal mem_mega_write_r, mem_mega_write_x           : std_logic;
  signal mem_mega_address_r, mem_mega_address_x       : std_logic_vector(23 downto 0);
  signal mem_mega_writedata_r, mem_mega_writedata_x   : std_logic_vector(7 downto 0);

  signal mem_memreg_write_r, mem_memreg_write_x         : std_logic;
  signal mem_memreg_writedata_r, mem_memreg_writedata_x : std_logic_vector(7 downto 0);

  signal mem_ioreg_write_r, mem_ioreg_write_x         : std_logic;
  signal mem_ioreg_writedata_r, mem_ioreg_writedata_x : std_logic_vector(7 downto 0);
  signal mem_ioreg_address_r, mem_ioreg_address_x     : std_logic_vector(1 downto 0);

  signal mem_nonreg_write_r, mem_nonreg_write_x       : std_logic;
  signal mem_nonreg_writedata_r, mem_nonreg_writedata_x : std_logic_vector(7 downto 0);
  signal mem_nonreg_address_r, mem_nonreg_address_x   : std_logic_vector(15 downto 0);

  signal mes_mega_readdata_r, mes_mega_readdata_x     : std_logic_vector(7 downto 0);
  signal mes_mega_readdatavalid_r, mes_mega_readdatavalid_x : std_logic;
  type mes_read_state_t is (MR_IDLE, MR_REG, MR_CARD, MR_MEM);
  signal mes_read_state_r, mes_read_state_x           : mes_read_state_t;

begin

  -- Config register documentation
  -- -----------------------------
  --
  -- CardMDR
  --   bit 7    - disable is conf.regs;
  --   bit 6..5 - addr r.conf=0F80/4F80/8F80/CF80
  --   bit 4    - enable SCC,
  --   bit 3    - delayed reconfiguration (bank registers only)
  --   bit 2    - select activate bank configurations 0=of start/jmp0/rst0 1= read(400Xh)
  --   bit 1    - Shadow BIOS ( to RAM )
  --   bit 0    - Disable read direct card vector port and card configuration register (4F80..)
  --
  -- Mconf
  --   bit 7    - enable Expand Slot
  --   bit 6    - enable Read mapper port ( FC FD FE FF )
  --   bit 5    - enable YM2413 (FM Pack syntesator)
  --   bit 4    - enable control MMM port (3C)
  --   bit 3    - enable x3 Expand slot FM Pack BIOS ROM
  --   bit 2    - enable x2 Expand slot MMM RAM mapper
  --   bit 1    - enable x1 Expand slot CF card disk interface
  --   bit 0    - enable x0 Expand slot SCC Cartridge
  --
  -- Rx.Mult
  --   bit 7    - enable page register bank 1
  --   bit 6    -
  --   bit 5    - RAM (select RAM or atlernative ROM...)
  --   bit 4    - enable write to bank
  --   bit 3    - disable bank ( read and write )
  --   bit 2..0 - bank size
  --              111 - 64kbyte
  --              110 - 32
  --              101 - 16
  --              100 - 8
  --              011 - 4
  --              other - disable bank

  -- Config output
  enable_expand <= Mconf(7);
  enable_scc <= Mconf(0) and CardMDR(4);
  enable_sd <= Mconf(1);
  enable_mapper <= Mconf(2);
  enable_fmpac <= Mconf(3);

  -- EEPROM Output
  EECS <= '1' when EECS1 = '1' else '0';
  EECK <= '1' when EECK1 = '1' else '0';
  EEDI <= '1' when EEDI1 = '1' else '0';

  enable_shadow_ram  <= CardMDR(1);

  mem_mega_read      <= mem_mega_read_r;
  mem_mega_write     <= mem_mega_write_r;
  mem_mega_address   <= mem_mega_address_r;
  mem_mega_writedata <= mem_mega_writedata_r;


  ----------------------------------------------------------
  -- I/O port register read (0xF0)
  ----------------------------------------------------------

  ios_mega_readdata_i <= 
      "00110010"  when (ios_mega_address = PFXN and PF0_RV = "01") else    -- char "2"
      "001100"& our_slot
                  when (ios_mega_address = PFXN and PF0_RV(1) = '1') else  -- char "2"
      x"ff";

  ios_mega_readdata <= ios_mega_readdata_i when rising_edge(clock);
  ios_mega_readdatavalid <= ios_mega_read when rising_edge(clock);
  ios_mega_waitrequest <= '0';


  ----------------------------------------------------------
  -- Memory-mapped register read
  ----------------------------------------------------------

  mes_mega_reg_addr_i <= mes_mega_address(5 downto 0);

  mes_mega_reg_readdata_x <=
      CardMDR     when mes_mega_reg_addr_i = "000000" else
      AddrM0      when mes_mega_reg_addr_i = "000001" else
      AddrM1      when mes_mega_reg_addr_i = "000010" else
      "0"&AddrM2  when mes_mega_reg_addr_i = "000011" else
      "0"&AddrFR  when mes_mega_reg_addr_i = "000101" else

      R1.Mask     when mes_mega_reg_addr_i = "000110" else
      R1.Addr     when mes_mega_reg_addr_i = "000111" else
      R1.Reg      when mes_mega_reg_addr_i = "001000" else
      R1.Mult     when mes_mega_reg_addr_i = "001001" else
      R1.MaskR    when mes_mega_reg_addr_i = "001010" else
      R1.AdrD     when mes_mega_reg_addr_i = "001011" else

      R2.Mask     when mes_mega_reg_addr_i = "001100" else
      R2.Addr     when mes_mega_reg_addr_i = "001101" else
      R2.Reg      when mes_mega_reg_addr_i = "001110" else
      R2.Mult     when mes_mega_reg_addr_i = "001111" else
      R2.MaskR    when mes_mega_reg_addr_i = "010000" else
      R2.AdrD     when mes_mega_reg_addr_i = "010001" else

      R3.Mask     when mes_mega_reg_addr_i = "010010" else
      R3.Addr     when mes_mega_reg_addr_i = "010011" else
      R3.Reg      when mes_mega_reg_addr_i = "010100" else
      R3.Mult     when mes_mega_reg_addr_i = "010101" else
      R3.MaskR    when mes_mega_reg_addr_i = "010110" else
      R3.AdrD     when mes_mega_reg_addr_i = "010111" else

      R4.Mask     when mes_mega_reg_addr_i = "011000" else
      R4.Addr     when mes_mega_reg_addr_i = "011001" else
      R4.Reg      when mes_mega_reg_addr_i = "011010" else
      R4.Mult     when mes_mega_reg_addr_i = "011011" else
      R4.MaskR    when mes_mega_reg_addr_i = "011100" else
      R4.AdrD     when mes_mega_reg_addr_i = "011101" else

      Mconf       when mes_mega_reg_addr_i = "011110" else
      CardMDR     when mes_mega_reg_addr_i = "011111" else

      "0000" & EECS1 & EECK1 & EEDI1 & EEDO 
                  when mes_mega_reg_addr_i = "100011" else

      "111100" & PFXN 
                  when mes_mega_reg_addr_i = "110101" else
      (others => '0');

  mes_mega_readdatavalid <= mes_mega_readdatavalid_r;
  mes_mega_readdata <= mes_mega_readdata_r;

  process(all)
  begin
    card_info_x <= card_info_r;
    mes_read_state_x <= mes_read_state_r;
    mes_mega_readdata_x <= (others => '-');
    mes_mega_readdatavalid_x <= '0';
    mes_mega_waitrequest <= '1';
    mem_mega_read_c1_i <= '0';

    if (card_info_latch_r = '1') then
      card_info_x <= x"435632";
    end if;

    case (mes_read_state_r) is
      when MR_IDLE =>
        -- Accept transfers when not busy writing
        mes_mega_waitrequest <= mem_mega_write_c1_r or mem_mega_write_c2_r or mem_mega_write_r;
        -- Handle read requests
        if (mes_mega_read = '1') then
          if (DecMDR = '1' and CardMDR(0) = '0' and
              mes_mega_address(5 downto 0) /= "000100" -- DatM0
              ) then 
            -- Read registers
            mes_read_state_x <= MR_REG;
          elsif (card_det_r = '1' and mes_mega_address = x"4000") then
            -- Read card detect register
            mes_read_state_x <= MR_CARD;
          else
            -- Read from mapped ram/flash
            mem_mega_read_c1_i <= '1';
            mes_read_state_x <= MR_MEM;
          end if;
        end if;

      when MR_REG =>
        -- Read register data
        mes_mega_readdata_x <= mes_mega_reg_readdata_r;
        mes_mega_readdatavalid_x <= '1';
        mes_read_state_x <= MR_IDLE;

      when MR_CARD =>
        -- Read card detect register
        mes_mega_readdata_x <= card_info_r(card_info_r'high downto card_info_r'high - 7);
        card_info_x <= card_info_r(card_info_r'high - 8 downto 0) & x"00";
        mes_mega_readdatavalid_x <= '1';
        mes_read_state_x <= MR_IDLE;

      when MR_MEM =>
        -- Read memory, wait till data is returned
        if (mem_mega_rdff_c2_r = '1') then
          -- Bank disabled, return 0xff
          mes_mega_readdata_x <= x"ff";
          mes_mega_readdatavalid_x <= '1';
          mes_read_state_x <= MR_IDLE;
        elsif (mem_mega_readdatavalid = '1') then
          mes_mega_readdata_x <= mem_mega_readdata;
          mes_mega_readdatavalid_x <= '1';
          mes_read_state_x <= MR_IDLE;
        end if;
    end case;
  end process;


  ----------------------------------------------------------
  -- Memory-mapped and I/O register write
  ----------------------------------------------------------

  DecMDR <= '1' when mes_mega_address(13 downto 6) = "00111110" and
                     CardMDR(7) = '0' and mes_mega_address(15 downto 14) = CardMDR(6 downto 5) else '0';

  RloadEn <= '1' when CardMDR(3) = '0' or soft_reset = '1' else '0';

  -- Registers
  process(all)
  begin
    if rising_edge(clock) then
      if (slot_reset = '1') then
        -- Reset values
        PF0_RV    <= "00";
        CardMDR   <= "00110000"; -- Config at 4F80, SCC enabled
        aMconf    <= "11111111"; -- All features enabled
        AddrM0    <= "00000000";
        AddrM1    <= "00000000";
        AddrM2    <= "0000000";
        AddrFR    <= "0000000";  -- shift addr Flash Rom x 64κ
        -- Bank 1
        R1.Mask   <= "11111000"; -- 0000h-07FFh + |
        R1.Addr   <= "01010000"; -- 5000h         | = 5000h-57FFh
        R1.Reg    <= "00000000"; -- Page 0 (Relative)
        R1.Mult   <= "10000101"; -- Enable page registers, 16kB pages
        R1.MaskR  <= "00111111"; -- Size "Cartrige" 64 Pages
        R1.AdrD   <= "01000000"; -- Bank Addr 4000h
        -- Bank 2
        R2.Mask   <= "11111000"; -- 0000h-07FFh + |
        R2.Addr   <= "01110000"; -- 7000h         | = 7000h-77FFh
        R2.Reg    <= "00000001"; -- Page 1 (Relative)
        R2.Mult   <= "10001100"; -- Enable page registers, disable bank, 8kB pages
        R2.MaskR  <= "00111111"; -- Size "Cartrige" 64 Pages
        R2.AdrD   <= "01100000"; -- Bank Addr 6000h
        -- Bank 3
        R3.Mask   <= "11111000"; -- 0000h-07FFh + |
        R3.Addr   <= "10010000"; -- 9000h         | = 9000h-97FFh
        R3.Reg    <= "00000010"; -- Page 2 (Relative)
        R3.Mult   <= "10001100"; -- Enable page registers, disable bank, 8kB pages
        R3.MaskR  <= "00111111"; -- Size "Cartrige" 64 Pages
        R3.AdrD   <= "10000000"; -- Bank Addr 8000h
        -- Bank 4
        R4.Mask   <= "11111000"; -- 0000h-07FFh + |
        R4.Addr   <= "10110000"; -- B000h         | = B000h-B7FFh
        R4.Reg    <= "00000011"; -- Page 3 (Relative)
        R4.Mult   <= "10001100"; -- Enable page registers, disable bank, 8kB pages
        R4.MaskR  <= "00111111"; -- Size "Cartrige" 64 Pages
        R4.AdrD   <= "10100000"; -- Bank Addr A000h
        -- EEPROM
        EECS1 <= '0'; EECK1 <= '0'; EEDI1 <= '0';
      else

        -- Load registers
        if (RloadEn = '1') then
          Mconf <= aMconf;
        end if;

        -- Port #F0 decription
        if (mem_ioreg_write_r = '1' and mem_ioreg_address_r = PFXN) then -- #F0
          case mem_ioreg_writedata_r(7 downto 0) is
            when "01000011" => PF0_RV <= "01";    -- char C - get version (detect)
            when "01010010" => CardMDR(7) <= '0'; -- char R - enable control registers 
            when "01001000" => CardMDR(7) <= '1'; -- char H - disable control registers 
            when "01010011" => PF0_RV <= "10";    -- char S - get slot 
            when "00110000" => CardMDR(6  downto 5) <= "00"; -- char 0 - set register base #0F80
            when "00110001" => CardMDR(6  downto 5) <= "01"; -- char 1 - set register base #4F80
            when "00110010" => CardMDR(6  downto 5) <= "10"; -- char 2 - set register base #8F80
            when "00110011" => CardMDR(6  downto 5) <= "11"; -- char 3 - set register base #CF80
            when "01000001" => Mconf(7)<='0'; Mconf(3 downto 0) <= "0001"; -- char A - set catrige main slot only
            when "01001101" => Mconf(7)<='1'; Mconf(3 downto 0) <= "1111"; -- char M - set default subslot config
            when others     => PF0_RV <= "00";
          end case;
        end if;

        -- Card detect sequence
        card_info_latch_r <= '0';
        if (mem_nonreg_write_r = '1') then
          card_seq_r <= 0;
          card_det_r <= '0';
          if (mem_nonreg_address_r = x"4000") then
            if (mem_nonreg_writedata_r = x"63") then -- 'c'
              card_seq_r <= 1;
            elsif (mem_nonreg_writedata_r = x"76" and card_seq_r = 1) then -- 'v'
              card_seq_r <= 2;
            elsif (mem_nonreg_writedata_r = x"32" and card_seq_r = 2) then -- '2'
              card_seq_r <= 3;
              card_det_r <= '1';
              card_info_latch_r <= '1';
              CardMDR(7) <= '0'; -- enable control registers
            end if;
          end if;
        end if;

        -- Mapped I/O port access on 8F80 ( 0F80, 4F80, CF80 ) Cart mode resister write
        if (mem_memreg_write_r = '1') then
          if (mes_mega_reg_addr_r = "000000") then CardMDR  <= mem_memreg_writedata_r; end if;
          ----------------------------------------------------------------------------------------
          if (mes_mega_reg_addr_r = "000001") then AddrM0   <= mem_memreg_writedata_r ; end if;
          if (mes_mega_reg_addr_r = "000010") then AddrM1   <= mem_memreg_writedata_r ; end if;
          if (mes_mega_reg_addr_r = "000011") then AddrM2   <= mem_memreg_writedata_r(6 downto 0); end if;
          if (mes_mega_reg_addr_r = "000101") then AddrFR   <= mem_memreg_writedata_r(6 downto 0); end if;
          ----------------------------------------------------------------------------------------
          if (mes_mega_reg_addr_r = "000110") then R1.Mask  <= mem_memreg_writedata_r ; end if;
          if (mes_mega_reg_addr_r = "000111") then R1.Addr  <= mem_memreg_writedata_r ; end if;
          if (mes_mega_reg_addr_r = "001000") then R1.Reg   <= mem_memreg_writedata_r ; end if;
          if (mes_mega_reg_addr_r = "001001") then R1.Mult  <= mem_memreg_writedata_r ; end if;
          if (mes_mega_reg_addr_r = "001010") then R1.MaskR <= mem_memreg_writedata_r ; end if;
          if (mes_mega_reg_addr_r = "001011") then R1.AdrD  <= mem_memreg_writedata_r ; end if;
          if (mes_mega_reg_addr_r = "001100") then R2.Mask  <= mem_memreg_writedata_r ; end if;
          if (mes_mega_reg_addr_r = "001101") then R2.Addr  <= mem_memreg_writedata_r ; end if;
          if (mes_mega_reg_addr_r = "001110") then R2.Reg   <= mem_memreg_writedata_r ; end if;
          if (mes_mega_reg_addr_r = "001111") then R2.Mult  <= mem_memreg_writedata_r ; end if;
          if (mes_mega_reg_addr_r = "010000") then R2.MaskR <= mem_memreg_writedata_r ; end if;
          if (mes_mega_reg_addr_r = "010001") then R2.AdrD  <= mem_memreg_writedata_r ; end if;
          if (mes_mega_reg_addr_r = "010010") then R3.Mask  <= mem_memreg_writedata_r ; end if;
          if (mes_mega_reg_addr_r = "010011") then R3.Addr  <= mem_memreg_writedata_r ; end if;
          if (mes_mega_reg_addr_r = "010100") then R3.Reg   <= mem_memreg_writedata_r ; end if;
          if (mes_mega_reg_addr_r = "010101") then R3.Mult  <= mem_memreg_writedata_r ; end if;
          if (mes_mega_reg_addr_r = "010110") then R3.MaskR <= mem_memreg_writedata_r ; end if;
          if (mes_mega_reg_addr_r = "010111") then R3.AdrD  <= mem_memreg_writedata_r ; end if;
          if (mes_mega_reg_addr_r = "011000") then R4.Mask  <= mem_memreg_writedata_r ; end if;
          if (mes_mega_reg_addr_r = "011001") then R4.Addr  <= mem_memreg_writedata_r ; end if;
          if (mes_mega_reg_addr_r = "011010") then R4.Reg   <= mem_memreg_writedata_r ; end if;
          if (mes_mega_reg_addr_r = "011011") then R4.Mult  <= mem_memreg_writedata_r ; end if;
          if (mes_mega_reg_addr_r = "011100") then R4.MaskR <= mem_memreg_writedata_r ; end if;
          if (mes_mega_reg_addr_r = "011101") then R4.AdrD  <= mem_memreg_writedata_r ; end if;
          ----------------------------------------------------------------------------------------
          if (mes_mega_reg_addr_r = "011110" and (mem_memreg_writedata_r(7) = '1' or mem_memreg_writedata_r(3 downto 0) /= "1111" ))
                                              then aMconf   <= mem_memreg_writedata_r; end if;
          if (mes_mega_reg_addr_r = "011111") then CardMDR  <= mem_memreg_writedata_r ; end if;
          ----------------------------------------------------------------------------------------
          if (mes_mega_reg_addr_r = "100011") then EECS1 <= mem_memreg_writedata_r(3);
                                        EECK1 <= mem_memreg_writedata_r(2);
                                        EEDI1 <= mem_memreg_writedata_r(1);  end if;
          ----------------------------------------------------------------------------------------
          if (mes_mega_reg_addr_r = "110101") then PFXN    <= mem_memreg_writedata_r(1 downto 0); end if; 
        end if;

        -- Memory mapped I/O port access on R1 Bank resister write
        if (mem_nonreg_write_r = '1' and R1.Mult(7) = '1'
            and ((mem_nonreg_address_r(15 downto 8) and R1.Mask) = (R1.Addr and R1.Mask))
            -- SCC+ options
            and (NSC_SCCP = '0' or (EseScc_MA19 = '0' and EseScc_MA20 = '0' and
                                    SccPlus_AllRam = '0' and SccPlus_B0Ram = '0')))
        then
          R1.Reg <= mem_nonreg_writedata_r;
        end if;

        -- Memory mapped I/O port access on R2 Bank resister write
        if (mem_nonreg_write_r = '1' and R2.Mult(7) = '1'
            and ((mem_nonreg_address_r(15 downto 8) and R2.Mask) = (R2.Addr and R2.Mask))
            -- SCC+ options
            and ( NSC_SCCP = '0' or (EseScc_MA19 = '0' and EseScc_MA20 = '0' and
                                     SccPlus_AllRam = '0' and SccPlus_B1Ram = '0')))
        then
          R2.Reg <= mem_nonreg_writedata_r;
        end if;

        -- Memory mapped I/O port access on R3 Bank resister write
        if (mem_nonreg_write_r = '1' and R3.Mult(7) = '1'
            and ((mem_nonreg_address_r(15 downto 8) and R3.Mask) = (R3.Addr and R3.Mask))
            -- SCC+ options
            and ( NSC_SCCP = '0' or (SccPlus_AllRam = '0' and
                                     (SccPlus_B2Ram = '0' or SccPlus_Enable = '0'))))
        then
          R3.Reg <= mem_nonreg_writedata_r;
        end if;

        -- Memory mapped I/O port access on R4 Bank resister write
        if (mem_nonreg_write_r = '1' and R4.Mult(7) = '1'
            and ((mem_nonreg_address_r(15 downto 8) and R4.Mask) = (R4.Addr and R4.Mask))
            -- SCC+ options
            and ( NSC_SCCP = '0' or (EseScc_MA19 = '0' and EseScc_MA20 = '0' and
                                     SccPlus_AllRam = '0')))
        then
          R4.Reg <= mem_nonreg_writedata_r;
        end if;

      end if;
    end if;
  end process;

  mem_memreg_write_x <= mes_mega_write when DecMDR = '1' else '0';
  mem_memreg_writedata_x <= mes_mega_writedata;

  mem_nonreg_write_x <= mes_mega_write when DecMDR = '0' else '0';
  mem_nonreg_writedata_x <= mes_mega_writedata;
  mem_nonreg_address_x <= mes_mega_address;

  mem_ioreg_write_x <= ios_mega_write;
  mem_ioreg_writedata_x <= ios_mega_writedata;
  mem_ioreg_address_x <= ios_mega_address;


  ----------------------------------------------------------------
  -- Not standart configurations
  ----------------------------------------------------------------
  NSC <= '1' when R4.Mult(2 downto 0) = "001" else '0';
  NSC_SCCP <= '1' when NSC = '1' and  R4.MaskR = "00000001" else '0';


  ----------------------------------------------------------------
  -- Address generation (3 clock pipeline)
  ----------------------------------------------------------------

  -- Clock 1 - Main Cartrige Address
  ---------------------------------------

  mem_mega_write_c1_i <= mes_mega_write;

  MR1A_c1_i <=
    PAGE_64k when R1.Mult(2 downto 0) = "111" and R1.Mult(3) = '0' else
    PAGE_32k when R1.Mult(2 downto 0) = "110" and R1.Mult(3) = '0' and
                  R1.AdrD(7) = mes_mega_address(15) else -- 32k
    PAGE_16k when R1.Mult(2 downto 0) = "101" and R1.Mult(3) = '0' and
                  R1.AdrD(7 downto 6) = mes_mega_address(15 downto 14) else
    PAGE_8k  when R1.Mult(2 downto 0) = "100" and R1.Mult(3) = '0' and
                  (R1.AdrD(7) = mes_mega_address(15) or R1.Mult(6) = '0') and
                  R1.AdrD(6 downto 5) = mes_mega_address(14 downto 13) else
    PAGE_NONE;

  MR2A_c1_i <=
    PAGE_64k when R2.Mult(2 downto 0) = "111" and R2.Mult(3) = '0' else
    PAGE_32k when R2.Mult(2 downto 0) = "110" and R2.Mult(3) = '0' and
                  R2.AdrD(7) = mes_mega_address(15) else
    PAGE_16k when R2.Mult(2 downto 0) = "101" and R2.Mult(3) = '0' and
                  R2.AdrD(7 downto 6) = mes_mega_address(15 downto 14) else
    PAGE_8k  when R2.Mult(2 downto 0) = "100" and R2.Mult(3) = '0' and
                  (R2.AdrD(7) = mes_mega_address(15) or R2.Mult(6) = '0') and
                  R2.AdrD(6 downto 5) = mes_mega_address(14 downto 13) else
    PAGE_NONE;

  MR3A_c1_i <=
    PAGE_64k when R3.Mult(2 downto 0) = "111" and R3.Mult(3) = '0' else
    PAGE_32k when R3.Mult(2 downto 0) = "110" and R3.Mult(3) = '0' and
                  R3.AdrD(0) = mes_mega_address(15) else
    PAGE_16k when R3.Mult(2 downto 0) = "101" and R3.Mult(3) = '0' and
                  R3.AdrD(7 downto 6) = mes_mega_address(15 downto 14) else
    PAGE_8k  when R3.Mult(2 downto 0) = "100" and R3.Mult(3) = '0' and
                  (R3.AdrD(7) = mes_mega_address(15) or R3.Mult(6) = '0') and
                  R3.AdrD(6 downto 5) = mes_mega_address(14 downto 13) else
    PAGE_NONE;

  MR4A_c1_i <=
    PAGE_64k when R4.Mult(2 downto 0) = "111" and R4.Mult(3) = '0' and NSC = '0' else
    PAGE_64k when R3.Mult(2 downto 0) = "111" and R4.Mult(3) = '0' and NSC = '1' else
    PAGE_32k when R4.Mult(2 downto 0) = "110" and R4.Mult(3) = '0' and
                  R4.AdrD(7) = mes_mega_address(15) and NSC = '0' else
    PAGE_32k when R3.Mult(2 downto 0) = "110" and R4.Mult(3) = '0' and
                  R4.AdrD(7) = mes_mega_address(15) and NSC = '1' else
    PAGE_16k when R4.Mult(2 downto 0) = "101" and R4.Mult(3) = '0' and
                  R4.AdrD(7 downto 6) = mes_mega_address(15 downto 14) and NSC = '0' else
    PAGE_16k when R3.Mult(2 downto 0) = "101" and R4.Mult(3) = '0' and
                  R4.AdrD(7 downto 6) = mes_mega_address(15 downto 14) and NSC = '1' else
    PAGE_8k  when R4.Mult(2 downto 0) = "100" and R4.Mult(3) = '0' and
                  (R4.AdrD(7) = mes_mega_address(15) or R4.Mult(6) = '0') and
                  R4.AdrD(6 downto 5) = mes_mega_address(14 downto 13) and NSC = '0' else
    PAGE_8k  when R3.Mult(2 downto 0) = "100" and R4.Mult(3) = '0' and
                  (R4.AdrD(7) = mes_mega_address(15) or R4.Mult(6) = '0') and
                  R4.AdrD(6 downto 5) = mes_mega_address(14 downto 13) and NSC = '1' else
    PAGE_NONE;

  addr_pipe_c1: process(clock)
  begin
    if rising_edge(clock) then
      MR1A_c1_r <= MR1A_c1_i;
      MR2A_c1_r <= MR2A_c1_i;
      MR3A_c1_r <= MR3A_c1_i;
      MR4A_c1_r <= MR4A_c1_i;
      mem_mega_read_c1_r <= mem_mega_read_c1_i;
      mem_mega_write_c1_r <= mem_mega_write_c1_i;
      mem_mega_address_c1_r <= mes_mega_address;
      mem_mega_writedata_c1_r <= mes_mega_writedata;
    end if;
  end process;


  -- Clock 2 - Memory page
  ---------------------------------------

  mem_mega_page_i <=
    (R1.MaskR(6 downto 0) and R1.Reg(6 downto 0)) & mem_mega_address_c1_r(15 downto 12) when MR1A_c1_r = PAGE_64k else
    (R1.MaskR and R1.Reg) & mem_mega_address_c1_r(14 downto 12) when MR1A_c1_r = PAGE_32k else
    "0" & (R1.MaskR and R1.Reg) & mem_mega_address_c1_r(13 downto 12) when MR1A_c1_r = PAGE_16k else
    "00" & (R1.MaskR and R1.Reg) & mem_mega_address_c1_r(12) when MR1A_c1_r = PAGE_8k else

    (R2.MaskR(6 downto 0) and R2.Reg(6 downto 0)) & mem_mega_address_c1_r(15 downto 12) when MR2A_c1_r = PAGE_64k else
    (R2.MaskR and R2.Reg) & mem_mega_address_c1_r(14 downto 12) when MR2A_c1_r = PAGE_32k else
    "0" & (R2.MaskR and R2.Reg) & mem_mega_address_c1_r(13 downto 12) when MR2A_c1_r = PAGE_16k else
    "00" & (R2.MaskR and R2.Reg) & mem_mega_address_c1_r(12) when MR2A_c1_r = PAGE_8k else

    (R3.MaskR(6 downto 0) and R3.Reg(6 downto 0)) & mem_mega_address_c1_r(15 downto 12) when MR3A_c1_r = PAGE_64k else
    (R3.MaskR and R3.Reg) & mem_mega_address_c1_r(14 downto 12) when MR3A_c1_r = PAGE_32k else
    "0" & (R3.MaskR and R3.Reg) & mem_mega_address_c1_r(13 downto 12) when MR3A_c1_r = PAGE_16k else
    "00" & (R3.MaskR and R3.Reg) & mem_mega_address_c1_r(12) when MR3A_c1_r = PAGE_8k else

    (R4.MaskR(6 downto 0) and R4.Reg(6 downto 0)) & mem_mega_address_c1_r(15 downto 12) when MR4A_c1_r = PAGE_64k and NSC = '0' else
    (R3.MaskR(6 downto 0) and R4.Reg(6 downto 0)) & mem_mega_address_c1_r(15 downto 12) when MR4A_c1_r = PAGE_64k and NSC = '1' else
    (R4.MaskR and R4.Reg) & mem_mega_address_c1_r(14 downto 12) when MR4A_c1_r = PAGE_32k and NSC = '0' else
    (R3.MaskR and R4.Reg) & mem_mega_address_c1_r(14 downto 12) when MR4A_c1_r = PAGE_32k and NSC = '1' else
    "0" & (R4.MaskR and R4.Reg) & mem_mega_address_c1_r(13 downto 12) when MR4A_c1_r = PAGE_16k and NSC = '0' else
    "0" & (R3.MaskR and R4.Reg) & mem_mega_address_c1_r(13 downto 12) when MR4A_c1_r = PAGE_16k and NSC = '1' else
    "00" & (R4.MaskR and R4.Reg) & mem_mega_address_c1_r(12) when MR4A_c1_r = PAGE_8k and NSC = '0' else
    "00" & (R3.MaskR and R4.Reg) & mem_mega_address_c1_r(12) when MR4A_c1_r = PAGE_8k and NSC = '1' else
    (others => '0');

  mem_mega_use_ram_i <=
    R1.Mult(5) when MR1A_c1_r /= PAGE_NONE else
    R2.Mult(5) when MR2A_c1_r /= PAGE_NONE else
    R3.Mult(5) when MR3A_c1_r /= PAGE_NONE else
    R4.Mult(5) when MR4A_c1_r /= PAGE_NONE else '0';

  mem_mega_write_c2_i <= mem_mega_write_c1_r when
                           ((DecMDR = '1' and mem_mega_address_c1_r(5 downto 0) = "000100") -- DatM0
                            or (MR1A_c1_r /= PAGE_NONE and R1.Mult(4) = '1' and DecMDR = '0'
                                and (NSC_SCCP = '0' or -- scc+
                                     SccPlus_AllRam = '1' or EseScc_MA20 = '1' or SccPlus_B0Ram = '1')) -- Bank1
                            or (MR2A_c1_r /= PAGE_NONE and R2.Mult(4) = '1' and DecMDR = '0'
                                and (NSC_SCCP = '0' or -- scc+
                                     SccPlus_AllRam = '1' or SccPlus_B1Ram = '1' or (EseScc_MA20 = '1' and mem_mega_address_c1_r(12 downto 1) /= "111111111111"))) -- Bank2
                            or (MR3A_c1_r /= PAGE_NONE and R3.Mult(4) = '1' and DecMDR = '0'
                                and (NSC_SCCP = '0' or -- scc+
                                     SccPlus_AllRam = '1' or (SccPlus_B2Ram = '1' and SccPlus_Enable = '1') )) -- Bank3
                            or (MR4A_c1_r /= PAGE_NONE and R4.Mult(4) = '1' and DecMDR = '0'
                                and (NSC_SCCP = '0' or -- scc+
                                     (SccPlus_AllRam = '1' and mem_mega_address_c1_r(12 downto 1) /= "111111111111"))) ) -- Bank4 
                         else '0';

  mem_mega_read_c2_i <= mem_mega_read_c1_r when MR1A_c1_r /= PAGE_NONE or MR2A_c1_r /= PAGE_NONE or MR3A_c1_r /= PAGE_NONE or MR4A_c1_r /= PAGE_NONE else '0';
  mem_mega_rdff_c2_i <= mem_mega_read_c1_r when MR1A_c1_r = PAGE_NONE and MR2A_c1_r = PAGE_NONE and MR3A_c1_r = PAGE_NONE and MR4A_c1_r = PAGE_NONE else '0';

  addr_pipe_c2: process(clock)
  begin
    if rising_edge(clock) then
      mem_mega_page_c2_r <= mem_mega_page_i;
      mem_mega_use_ram_c2_r <= mem_mega_use_ram_i;
      mem_mega_read_c2_r <= mem_mega_read_c2_i;
      mem_mega_rdff_c2_r <= mem_mega_rdff_c2_i;
      mem_mega_write_c2_r <= mem_mega_write_c2_i;
      mem_mega_address_c2_r <= mem_mega_address_c1_r;
      mem_mega_writedata_c2_r <= mem_mega_writedata_c1_r;
    end if;
  end process;

  -- Clock 3 - Final adress Flash/ROM mapping
  ---------------------------------------

  mem_mega_map_i <= std_logic_vector(unsigned(AddrFR) + unsigned(mem_mega_page_c2_r(10 downto 4))) & mem_mega_page_c2_r(3 downto 0);

  mem_mega_address_i <=
    '0' & AddrM2(6 downto 0) & AddrM1(7 downto 0) & AddrM0(7 downto 0) when
      (DecMDR = '1' and CardMDR(0) = '0' and mem_mega_address_c2_r(5 downto 0) = "000100") else -- Direct card vector port
    mem_mega_use_ram_c2_r & mem_mega_map_i & mem_mega_address_c2_r(11 downto 0);

  process(all)
  begin
    if ((mem_mega_read_r = '1' or mem_mega_write_r = '1') and
        mem_mega_waitrequest = '1') then
      -- keep active till accepted
      mem_mega_read_x <= mem_mega_read_r;
      mem_mega_write_x <= mem_mega_write_r;
      mem_mega_address_x <= mem_mega_address_r;
      mem_mega_writedata_x <= mem_mega_writedata_r;
    else
      -- next
      mem_mega_read_x <= mem_mega_read_c2_r;
      mem_mega_write_x <= mem_mega_write_c2_r;
      mem_mega_address_x <= mem_mega_address_i;
      mem_mega_writedata_x <= mem_mega_writedata_c2_r;
    end if;
  end process;

  addr_pipe_c3: process(clock)
  begin
    if rising_edge(clock) then
      mem_mega_read_r <= mem_mega_read_x;
      mem_mega_write_r <= mem_mega_write_x;
      mem_mega_address_r <= mem_mega_address_x;
      mem_mega_writedata_r <= mem_mega_writedata_x;
    end if;
  end process;


  ----------------------------------------------------------------
  -- Registers
  ----------------------------------------------------------------

  process(clock)
  begin
    if rising_edge(clock) then
      if (slot_reset = '1') then
        mes_read_state_r <= MR_IDLE ;
        mes_mega_readdatavalid_r <= '0';
        mem_memreg_write_r <= '0';
        mem_nonreg_write_r <= '0';
        mem_ioreg_write_r <= '0';
      else
        mes_read_state_r <= mes_read_state_x;
        mes_mega_readdatavalid_r <= mes_mega_readdatavalid_x;
        mem_memreg_write_r <= mem_memreg_write_x;
        mem_nonreg_write_r <= mem_nonreg_write_x;
        mem_ioreg_write_r <= mem_ioreg_write_x;
      end if;
      card_info_r <= card_info_x;
      mes_mega_reg_addr_r <= mes_mega_reg_addr_i;
      mes_mega_readdata_r <= mes_mega_readdata_x;
      mes_mega_reg_readdata_r <= mes_mega_reg_readdata_x;
      mem_memreg_writedata_r <= mem_memreg_writedata_x;
      mem_nonreg_writedata_r <= mem_nonreg_writedata_x;
      mem_nonreg_address_r <= mem_nonreg_address_x;
      mem_ioreg_writedata_r <= mem_ioreg_writedata_x;
      mem_ioreg_address_r <= mem_ioreg_address_x;
    end if;
  end process;


end rtl;
