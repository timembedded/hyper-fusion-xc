library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
library work;
use work.ipc.all;
LIBRARY altera_mf;
use altera_mf.altera_mf_components.all;

entity spi_ipc is
  port(
    -- Clock and reset
    clock                       : in  std_logic;
    slot_reset                  : in  std_logic;
    -- IO bus
    ios_read                    : in  std_logic;
    ios_write                   : in  std_logic;
    ios_address                 : in  std_logic_vector(7 downto 0);
    ios_writedata               : in  std_logic_vector(7 downto 0);
    ios_readdata                : out std_logic_vector(8 downto 0);
    ios_readdatavalid           : out std_logic;
    ios_waitrequest             : out std_logic;
    -- QSPI
    spi_cs_n                    : in std_logic;
    spi_clk                     : in std_logic;
    spi_data                    : inout std_logic_vector(3 downto 0);
    spi_irq                     : out std_logic
  );
end entity spi_ipc;

architecture rtl of spi_ipc is

  type write_state_t is (WS_RESET, WS_IDLE, WS_FIFO_READ, WS_WRITE_START, WS_READ_START);
  signal write_state_x, write_state_r : write_state_t;
  signal io_enabled_x, io_enabled_r : std_logic;
  signal pending_read_x, pending_read_r : std_logic;
  signal pending_address_x, pending_address_r : std_logic_vector(7 downto 0);

  signal ios_address_x, ios_address_r     : std_logic_vector(7 downto 0);
  signal ios_writedata_x, ios_writedata_r : std_logic_vector(7 downto 0);
  
  type ioram_t is array(0 to 255) of std_logic_vector(11 downto 0);
  signal ioram_memory             : ioram_t;
  signal ioram_write              : std_logic;
  signal ioram_address            : std_logic_vector(7 downto 0);
  signal ioram_wrdata             : std_logic_vector(11 downto 0);
  signal ioram_rddata             : std_logic_vector(11 downto 0);
  signal ioram_rddata_i           : ioram_data_t;
  signal ioram_wrdata_i           : ioram_data_t;

  signal ififo_data	              : std_logic_vector (IFIFO_BIT_WIDTH-1 downto 0);
  signal ififo_rdclk	            : std_logic;
  signal ififo_rdreq	            : std_logic;
  signal ififo_wrclk	            : std_logic;
  signal ififo_wrreq	            : std_logic;
  signal ififo_q	                : std_logic_vector (IFIFO_BIT_WIDTH-1 downto 0);
  signal ififo_rdempty	          : std_logic;
  signal ififo_data_i             : ififo_data_t;
  signal ififo_q_i                : ififo_data_t;

  signal ofifo_data	              : std_logic_vector (OFIFO_BIT_WIDTH-1 downto 0);
  signal ofifo_rdclk	            : std_logic;
  signal ofifo_rdreq	            : std_logic;
  signal ofifo_wrclk	            : std_logic;
  signal ofifo_wrreq	            : std_logic;
  signal ofifo_q	                : std_logic_vector (OFIFO_BIT_WIDTH-1 downto 0);
  signal ofifo_rdempty	          : std_logic;
  signal ofifo_wrfull	            : std_logic;
  signal ofifo_data_i             : ofifo_data_t;

  type spi_state_t is (SS_C0, SS_C1, SS_C2, SS_IFIFO_C3, SS_IFIFO_C4, SS_IFIFO_C5, SS_IFIFO_C6,
                       SS_OFIFO_C3, SS_OFIFO_C4, SS_OFIFO_C5, SS_OFIFO_C6, SS_OFIFO_C7,
                       SS_OFIFO_C8, SS_OFIFO_C9);
  signal spi_state_x, spi_state_r     : spi_state_t;
  signal spi_out_x, spi_out_r         : std_logic_vector(3 downto 0);
  signal spi_oe_x, spi_oe_r           : std_logic;
  signal spi_command_x, spi_command_r : std_logic_vector(3 downto 0);
  signal spi_address_x, spi_address_r : std_logic_vector(7 downto 0);
  signal spi_dvalid_x, spi_dvalid_r   : std_logic;
  signal spi_data_x, spi_data_r       : std_logic_vector(7 downto 0);
  signal spi_irq_set_i, spi_irq_set_ff : std_logic;
  signal spi_irq_reset_i              : std_logic;

begin

  -- Connect QSPI
  spi_data <= spi_out_r when spi_oe_r = '1' else (others => 'Z');

  -- IRQ generation
  process(clock, spi_irq_reset_i)
  begin
    if (spi_irq_reset_i = '1') then
      spi_irq <= '0';
      spi_irq_set_ff <= '0';
    elsif rising_edge(clock) then
      spi_irq_set_ff <= spi_irq_set_i;
      if (spi_irq_set_ff = '1') then
        spi_irq <= '1';
      end if;
    end if;
  end process;

  -- RAMs:
  --
  --                  Host   Remote
  -- IO properties    R      W
  -- Write-data       R(W)   R
  -- Read-data        R(W)   W
  
  --  
  -- Global properties:
  --
  -- bits  name
  --  1    enable
  --
  -- I/O properties per address:
  --
  -- bits  name
  --  1    write_cache
  --  1    write_ipc
  --  2    read_mode
  --         0 - Read disabled
  --         1 - Read from cache
  --         2 - Read from cache, notify over IPC (don't wait)
  --         3 - Read from IPC (slow)

  -- RAM holding IO cache and settings
  process(all)
  begin
      if rising_edge(clock) then
          if (ioram_write = '1') then
              ioram_memory(to_integer(unsigned(ioram_address))) <= ioram_wrdata;
          end if;
          ioram_rddata <= ioram_memory(to_integer(unsigned(ioram_address)));
      end if;
  end process;

  ioram_wrdata <= to_std_logic_vector(ioram_wrdata_i);

  -- Input FIFO
	i_in_dcfifo : dcfifo
	generic map (
		intended_device_family => "Cyclone II",
		lpm_numwords => 256,
		lpm_showahead => "OFF",
		lpm_type => "dcfifo",
		lpm_width => IFIFO_BIT_WIDTH,
		lpm_widthu => 8,
		overflow_checking => "ON",
		rdsync_delaypipe => 2,
		read_aclr_synch => "ON",
		underflow_checking => "ON",
		use_eab => "ON",
		write_aclr_synch => "OFF",
		wrsync_delaypipe => 2
	)
	port map (
		aclr => '0',
		data => ififo_data,
		rdclk => ififo_rdclk,
		rdreq => ififo_rdreq,
		wrclk => ififo_wrclk,
		wrreq => ififo_wrreq,
		q => ififo_q,
		rdempty => ififo_rdempty,
		rdfull => open,
		rdusedw => open,
		wrempty => open,
		wrfull => open,
		wrusedw => open
	);
  ififo_rdclk <= clock;
  ififo_wrclk <= spi_clk;
  ififo_q_i <= from_std_logic_vector(ififo_q);

  -- Output FIFO
	i_out_dcfifo : dcfifo
	generic map (
		intended_device_family => "Cyclone II",
		lpm_numwords => 256,
		lpm_showahead => "OFF",
		lpm_type => "dcfifo",
		lpm_width => OFIFO_BIT_WIDTH,
		lpm_widthu => 8,
		overflow_checking => "ON",
		rdsync_delaypipe => 2,
		read_aclr_synch => "ON",
		underflow_checking => "ON",
		use_eab => "ON",
		write_aclr_synch => "OFF",
		wrsync_delaypipe => 2
	)
	port map (
		aclr => '0',
		data => ofifo_data,
		rdclk => ofifo_rdclk,
		rdreq => ofifo_rdreq,
		wrclk => ofifo_wrclk,
		wrreq => ofifo_wrreq,
		q => ofifo_q,
		rdempty => ofifo_rdempty,
		rdfull => open,
		rdusedw => open,
		wrempty => open,
		wrfull => ofifo_wrfull,
		wrusedw => open
	);

  ofifo_rdclk <= spi_clk;
  ofifo_wrclk <= clock;
  ofifo_data <= to_std_logic_vector(ofifo_data_i);

  -- Connection from local CPU to RAM
  process(all)
  begin
    -- State machine
    write_state_x <= write_state_r;
    io_enabled_x <= io_enabled_r;
    pending_read_x <= pending_read_r;
    pending_address_x <= pending_address_r;

    -- IO slave bus
    ios_waitrequest <= '1';
    ios_readdata <= "0--------";
    ios_readdatavalid <= '0';
    ios_address_x <= ios_address_r;
    ios_writedata_x <= ios_writedata_r;

    -- to RAM
    ioram_write <= '0';
    ioram_address <= ios_address;
    ioram_wrdata_i <= ioram_rddata_i;

    -- from RAM
    ioram_rddata_i <= from_std_logic_vector(ioram_rddata);

    -- input fifo
    ififo_rdreq <= '0';

    -- output fifo
    ofifo_wrreq <= '0';
    ofifo_data_i.writeaddress <= ios_address_r;
    ofifo_data_i.writedata <= ios_writedata_r;
    ofifo_data_i.command <= t_remote_write;

    -- IRQ
    spi_irq_set_i <= '0';

    -- State machine
    case (write_state_r) is
    when WS_RESET =>
      ofifo_data_i.command <= t_remote_reset;
      if (slot_reset = '0' and ofifo_wrfull = '0') then
        ofifo_wrreq <= '1';
        spi_irq_set_i <= '1';
        write_state_x <= WS_IDLE;
      end if;

    when WS_IDLE =>
      ios_waitrequest <= '0';
      ios_address_x <= ios_address;
      ios_writedata_x <= ios_writedata;
      if (ios_read = '1') then
          write_state_x <= WS_READ_START;
      elsif (io_enabled_r = '1' and ios_write = '1') then
          write_state_x <= WS_WRITE_START;
      elsif (ififo_rdempty = '0') then
          ififo_rdreq <= '1';
          write_state_x <= WS_FIFO_READ;
      end if;

    when WS_FIFO_READ =>
      ioram_address <= ififo_q_i.address;
      case (ififo_q_i.command) is
      when t_incmd_update =>
          -- Update data in RAM, clear pending bit
          ioram_write <= '1';
          ioram_wrdata_i.readdata <= ififo_q_i.data;
          -- IF this matches a pending read, return the data
          if (pending_read_r = '1' and pending_address_r = ios_address_r) then
            pending_read_x <= '0';
            ios_readdatavalid <= '1';
            ios_readdata <= '1' & ififo_q_i.data;
          end if;
      when t_incmd_set_properties =>
          -- Write properties
          ioram_write <= '1';
          ioram_wrdata_i.properties <= from_std_logic_vector(ififo_q_i.data(3 downto 0));
          if (ififo_q_i.address = x"ff") then
            if (ififo_q_i.data = x"55" ) then
              io_enabled_x <= '1';
            else
              io_enabled_x <= '0';
            end if;
          end if;
      when t_incmd_loopback =>
          ofifo_data_i.command <= t_remote_loopback;
          ofifo_data_i.writeaddress <= ififo_q_i.address;
          ofifo_data_i.writedata <= ififo_q_i.data;
          ofifo_wrreq <= not ofifo_wrfull;
          spi_irq_set_i <= not ofifo_wrfull;
      end case;
      write_state_x <= WS_IDLE;

    when WS_WRITE_START =>
      ioram_address <= ios_address_r;
      if (ioram_rddata_i.properties.write_cache = '1') then
          ioram_wrdata_i.readdata <= ios_writedata_r;
          ioram_write <= '1';
      end if;
      if (ioram_rddata_i.properties.write_ipc = '1') then
        ofifo_data_i.command <= t_remote_write;
        if (ofifo_wrfull = '0') then
            ofifo_wrreq <= '1';
            spi_irq_set_i <= '1';
            write_state_x <= WS_IDLE;
        end if;
      else
        write_state_x <= WS_IDLE;
      end if;

    when WS_READ_START =>
      ioram_address <= ios_address_r;
      if (io_enabled_r = '0') then
        -- not enabled, return nothing
        ios_readdatavalid <= '1';
        write_state_x <= WS_IDLE;
      else
        -- return data depending on the read_mode
        case (ioram_rddata_i.properties.read_mode) is
        when t_rdmode_disabled =>
            -- return nothing
            ios_readdatavalid <= '1';
            write_state_x <= WS_IDLE;
        when t_rdmode_cache =>
            -- return data from RAM
            ios_readdatavalid <= '1';
            ios_readdata <= '1' & ioram_rddata_i.readdata;
            write_state_x <= WS_IDLE;
        when t_rdmode_cache_notify =>
            -- return data from RAM + notify
            ios_readdatavalid <= '1';
            ios_readdata <= '1' & ioram_rddata_i.readdata;
            if (ofifo_wrfull = '0') then
              spi_irq_set_i <= '1';
              ofifo_wrreq <= '1';
              ofifo_data_i.command <= t_remote_notify;
              ofifo_data_i.writedata <= ioram_rddata_i.readdata;
              write_state_x <= WS_IDLE;
            end if;
        when t_rdmode_ipc =>
            -- read over IPC, send read command to remote
            ofifo_data_i.command <= t_remote_read;
            pending_read_x <= '1';
            pending_address_x <= ios_address_r;
            if (ofifo_wrfull = '0') then
              spi_irq_set_i <= '1';
              ofifo_wrreq <= '1';
              ioram_write <= '1';
              write_state_x <= WS_IDLE;
            end if;
        end case;
      end if;

    end case;

  end process;

  -- QSPI at remote side
  --
  -- Write to IFIFO transaction
  --
  -- Clock Phase    Dir
  --  C0   command  In
  --  C1   address  In
  --  C2   address  In
  --  C3   data     In
  --  C4   data     In
  --  C5   dummy    -   Data is written to FIFO
  --
  -- Read from OFIFO transaction
  --
  -- Clock Phase    Dir  Note
  --  C0   command  In
  --  C1   dummy    -    Data is read from fifo
  --  C2   dummy    -    First data is latched to outputs
  --  C3   data     OUT
  --  C4   data     OUT
  --  C5   data     OUT
  --  C6   data     OUT
  --  C7   data     OUT
  --
  process(all)
  begin
    spi_state_x <= spi_state_r;

    ofifo_rdreq <= '0';
    ififo_wrreq <= '0';

    spi_out_x <= (others => '0');
    spi_oe_x <= '0';
    spi_irq_reset_i <= '0';

    spi_command_x <= spi_command_r;
    spi_address_x <= spi_address_r;
    spi_data_x <= spi_data_r;
    spi_dvalid_x <= spi_dvalid_r;

    ififo_data_i.command <= from_std_logic_vector(spi_command_r(1 downto 0));
    ififo_data_i.address <= spi_address_r;
    ififo_data_i.data <= spi_data_r;
    ififo_data <= to_std_logic_vector(ififo_data_i);

    case (spi_state_r) is
    when SS_C0 =>
      spi_command_x <= spi_data;
      spi_state_x <= SS_C1;
    when SS_C1 =>
      spi_state_x <= SS_C2;
      spi_address_x(7 downto 4) <= spi_data;
    when SS_C2 =>
      spi_address_x(3 downto 0) <= spi_data;
      if( spi_command_r(3) = '1' ) then
        -- Read from OFIFO
        if (ofifo_rdempty = '0') then
          ofifo_rdreq <= '1';
          spi_dvalid_x <= '1';
        else
          spi_dvalid_x <= '0';
          spi_irq_reset_i <= '1';
        end if;
        spi_state_x <= SS_OFIFO_C3;
      else
        -- Write to IFIFO
        spi_state_x <= SS_IFIFO_C3;
      end if;

    -- Write to IFIFO
    when SS_IFIFO_C3 =>
      spi_data_x(7 downto 4) <= spi_data;
      spi_state_x <= SS_IFIFO_C4;
    when SS_IFIFO_C4 =>
      spi_data_x(3 downto 0) <= spi_data;
      spi_state_x <= SS_IFIFO_C5;
    when SS_IFIFO_C5 =>
      ififo_wrreq <= '1';
      spi_state_x <= SS_IFIFO_C6;
    when SS_IFIFO_C6 =>
      spi_state_x <= SS_IFIFO_C6;

    -- Read from OFIFO
    -- Note: Bytes are little endian, bits are msb-first
    when SS_OFIFO_C3 => -- bits 7..4
      spi_oe_x <= '1';
      spi_out_x <= ofifo_q(7 downto 4);
      spi_state_x <= SS_OFIFO_C4;
    when SS_OFIFO_C4 => -- bits 3..0
      spi_oe_x <= '1';
      spi_out_x <= ofifo_q(3 downto 0);
      spi_state_x <= SS_OFIFO_C5;
    when SS_OFIFO_C5 => -- bits 15..12
      spi_oe_x <= '1';
      spi_out_x <= ofifo_q(15 downto 12);
      spi_state_x <= SS_OFIFO_C6;
    when SS_OFIFO_C6 => -- bits 11..8
      spi_oe_x <= '1';
      spi_out_x <= ofifo_q(11 downto 8);
      spi_state_x <= SS_OFIFO_C7;
    when SS_OFIFO_C7 => -- bits 23..20
      spi_oe_x <= '1';
      spi_out_x <= spi_dvalid_r & "000";
      spi_state_x <= SS_OFIFO_C8;
    when SS_OFIFO_C8 => -- bits 19..16
      spi_oe_x <= '1';
      spi_out_x <= '0' & ofifo_q(OFIFO_BIT_WIDTH-1 downto 16);
      spi_state_x <= SS_OFIFO_C9;
    when SS_OFIFO_C9 =>
      spi_state_x <= SS_OFIFO_C9;
 
    end case;
  end process;

  -- SPI Registers
  process(spi_clk, spi_cs_n)
  begin
    if (spi_cs_n = '1') then
      spi_state_r <= SS_C0;
      spi_oe_r <= '0';
    elsif rising_edge(spi_clk) then
      spi_state_r <= spi_state_x;
      spi_oe_r <= spi_oe_x;
      spi_out_r <= spi_out_x;
      spi_command_r <= spi_command_x;
      spi_address_r <= spi_address_x;
      spi_data_r <= spi_data_x;
      spi_dvalid_r <= spi_dvalid_x;
    end if;
  end process;

  -- Registers
  process(clock)
  begin
    if rising_edge(clock) then
      if (slot_reset = '1') then
        io_enabled_r <= '0';
        pending_read_r <= '0';
        write_state_r <= WS_RESET;
      else
        io_enabled_r <= io_enabled_x;
        pending_read_r <= pending_read_x;
        pending_address_r <= pending_address_x;
        write_state_r <= write_state_x;
        ios_address_r <= ios_address_x;
        ios_writedata_r <= ios_writedata_x;
      end if;
    end if;
  end process;

end architecture RTL;
