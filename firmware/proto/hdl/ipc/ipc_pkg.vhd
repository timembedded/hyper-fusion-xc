--------------------------------------------------------------------
-- Author: Tim Brugman
--
-- IPC communication over QSPI
--------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package ipc is

  constant OFIFO_BIT_WIDTH : integer := 19;
  constant IFIFO_BIT_WIDTH : integer := 18;

  -- Data RAM for properties and readdata
  -------------------------------------------

  type read_mode_t is (t_rdmode_disabled, t_rdmode_cache, t_rdmode_cache_notify, t_rdmode_ipc);

  type ioram_properties_t is record
      write_cache     : std_logic;
      write_ipc       : std_logic;
      read_mode       : read_mode_t;
  end record;

  type ioram_data_t is record
      properties      : ioram_properties_t;
      readdata        : std_logic_vector(7 downto 0);
  end record;

  -- Conversion functions
  function to_std_logic_vector(i : ioram_properties_t)
    return std_logic_vector;
  function from_std_logic_vector(i : std_logic_vector(3 downto 0))
    return ioram_properties_t;
  function to_std_logic_vector(i : ioram_data_t)
    return std_logic_vector;
  function from_std_logic_vector(i : std_logic_vector(11 downto 0))
    return ioram_data_t;

  -- Command over fifo host->remote
  -------------------------------------

  type ofifo_command_t is (t_remote_reset, t_remote_notify, t_remote_write, t_remote_read, t_remote_loopback, t_remote_invalid);

  function to_std_logic_vector(i : ofifo_command_t)
    return std_logic_vector;
  function from_std_logic_vector(i : std_logic_vector(1 downto 0))
    return ofifo_command_t;

  type ofifo_data_t is record
      command         : ofifo_command_t;
      writeaddress    : std_logic_vector(7 downto 0);
      writedata       : std_logic_vector(7 downto 0);
  end record;

  function to_std_logic_vector(i : ofifo_data_t)
    return std_logic_vector;
  function from_std_logic_vector(i : std_logic_vector(OFIFO_BIT_WIDTH-1 downto 0))
    return ofifo_data_t;

  -- fifo remote->host
  -------------------------------------

  type ififo_command_t is (t_incmd_loopback, t_incmd_update, t_incmd_set_properties, t_incmd_set_irq);

  function to_std_logic_vector(i : ififo_command_t)
    return std_logic_vector;
  function from_std_logic_vector(i : std_logic_vector(0 downto 0))
    return ififo_command_t;

  type ififo_data_t is record
      command : ififo_command_t;
      address : std_logic_vector(7 downto 0);
      data    : std_logic_vector(7 downto 0);
  end record;

  function to_std_logic_vector(i : ififo_data_t)
    return std_logic_vector;
  function from_std_logic_vector(i : std_logic_vector(IFIFO_BIT_WIDTH-1 downto 0))
    return ififo_data_t;

end package ipc;

package body ipc is

  -- Data RAM for properties and readdata
  -------------------------------------------

  function to_std_logic_vector(i : ioram_properties_t) return std_logic_vector is
      variable o : std_logic_vector(3 downto 0);
  begin
      o(3) := i.write_cache;
      o(2) := i.write_ipc;
      case (i.read_mode) is
      when t_rdmode_disabled =>
          o(1 downto 0) := "00";
      when t_rdmode_cache =>
          o(1 downto 0) := "01";
      when t_rdmode_cache_notify =>
          o(1 downto 0) := "10";
      when t_rdmode_ipc =>
          o(1 downto 0) := "11";
      end case;
      return o;
  end;

  function from_std_logic_vector(i : std_logic_vector(3 downto 0)) return ioram_properties_t is
      variable o : ioram_properties_t;
  begin
      o.write_cache := i(3);
      o.write_ipc := i(2);
      case (i(1 downto 0)) is
      when "00" =>
          o.read_mode := t_rdmode_disabled;
      when "01" =>
          o.read_mode := t_rdmode_cache;
      when "10" =>
          o.read_mode := t_rdmode_cache_notify;
      when others =>
          o.read_mode := t_rdmode_ipc;
      end case;
      return o;
  end;

  function to_std_logic_vector(i : ioram_data_t) return std_logic_vector is
      variable o : std_logic_vector(11 downto 0);
  begin
      o(11 downto 8) := to_std_logic_vector(i.properties);
      o(7 downto 0) := i.readdata;
      return o;
  end;

  function from_std_logic_vector(i : std_logic_vector(11 downto 0)) return ioram_data_t is
      variable o : ioram_data_t;
  begin
      o.properties := from_std_logic_vector(i(11 downto 8));
      o.readdata := i(7 downto 0);
      return o;
  end;

  -- Command over fifo host->remote
  -------------------------------------

  function to_std_logic_vector(i : ofifo_command_t) return std_logic_vector is
      variable o : std_logic_vector(2 downto 0);
  begin
      case (i) is
      when t_remote_reset =>
          o(2 downto 0) := "001";
      when t_remote_loopback =>
          o(2 downto 0) := "010";
      when t_remote_notify =>
          o(2 downto 0) := "100";
      when t_remote_write =>
          o(2 downto 0) := "101";
      when t_remote_read =>
          o(2 downto 0) := "110";
      when t_remote_invalid =>
          o(2 downto 0) := "111";
      end case;
      return o;
  end;

  function from_std_logic_vector(i : std_logic_vector(2 downto 0)) return ofifo_command_t is
      variable o : ofifo_command_t;
  begin
      case (i(2 downto 0)) is
      when "001" =>
          o := t_remote_reset;
      when "010" =>
          o := t_remote_loopback;
      when "100" =>
          o := t_remote_notify;
      when "101" =>
          o := t_remote_write;
      when "110" =>
          o := t_remote_read;
      when others =>
          o := t_remote_invalid;
      end case;
      return o;
  end;

  function to_std_logic_vector(i : ofifo_data_t) return std_logic_vector is
      variable o : std_logic_vector(OFIFO_BIT_WIDTH-1 downto 0);
  begin
      o(7 downto 0) := i.writeaddress;
      o(15 downto 8) := i.writedata;
      o(18 downto 16) := to_std_logic_vector(i.command);
      return o;
  end;

  function from_std_logic_vector(i : std_logic_vector(OFIFO_BIT_WIDTH-1 downto 0)) return ofifo_data_t is
      variable o : ofifo_data_t;
  begin
      o.writeaddress := i(7 downto 0);
      o.writedata := i(15 downto 8);
      o.command := from_std_logic_vector(i(18 downto 16));
      return o;
  end;

  -- fifo remote->host
  -------------------------------------

  function to_std_logic_vector(i : ififo_command_t) return std_logic_vector is
      variable o : std_logic_vector(1 downto 0);
  begin
      case (i) is
      when t_incmd_loopback =>
          o := "00";
      when t_incmd_update =>
          o := "01";
      when t_incmd_set_properties =>
          o := "10";
      when t_incmd_set_irq =>
          o := "11";
      end case;
      return o;
  end;

  function from_std_logic_vector(i : std_logic_vector(1 downto 0)) return ififo_command_t is
      variable o : ififo_command_t;
  begin
      case (i) is
      when "00" =>
          o := t_incmd_loopback;
      when "01" =>
          o := t_incmd_update;
      when "10" =>
          o := t_incmd_set_properties;
      when others =>
          o := t_incmd_set_irq;
      end case;
      return o;
  end;

  function to_std_logic_vector(i : ififo_data_t) return std_logic_vector is
      variable o : std_logic_vector(IFIFO_BIT_WIDTH-1 downto 0);
  begin
      o(7 downto 0) := i.address;
      o(15 downto 8) := i.data;
      o(17 downto 16) := to_std_logic_vector(i.command);
      return o;
  end;

  function from_std_logic_vector(i : std_logic_vector(IFIFO_BIT_WIDTH-1 downto 0)) return ififo_data_t is
      variable o : ififo_data_t;
  begin
      o.address := i(7 downto 0);
      o.data := i(15 downto 8);
      o.command := from_std_logic_vector(i(17 downto 16));
      return o;
  end;

end package body ipc;
