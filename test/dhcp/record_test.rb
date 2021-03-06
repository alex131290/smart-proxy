require 'test_helper'
require 'dhcp_common/dhcp_common'
require 'dhcp_common/record'
require 'dhcp_common/subnet'

class Proxy::DHCPRecordTest < Test::Unit::TestCase

  def setup
    @subnet = Proxy::DHCP::Subnet.new("192.168.0.0","255.255.255.0")
    @ip = "123.321.123.321"
    @mac = "aa:bb:CC:dd:ee:ff"
    @record = Proxy::DHCP::Record.new(:subnet => @subnet, :ip => @ip, :mac => @mac)
  end

  def test_record_should_have_a_subnet
    assert_kind_of Proxy::DHCP::Subnet, @record.subnet
  end

  def test_should_convert_to_string
    ip = "1.1.1.1"
    mac = "aa:bb:cc:dd:ea:ff"
    assert_equal Proxy::DHCP::Record.new(:subnet => @subnet, :ip => ip, :mac => mac).to_s, "#{ip} / #{mac}"
  end

  def test_should_not_save_invalid_ip_addresses
    ip = "1..1.1"
    assert_raise Proxy::Validations::Error do
      Proxy::DHCP::Record.new(:subnet => @subnet, :ip => ip,  :mac => @mac)
    end
  end

  def test_mac_should_be_saved_lower_case
    mac = "AA:BB:CC:DD:EE:aF"
    ip = "192.168.0.12"
    assert_equal Proxy::DHCP::Record.new(:subnet => @subnet, :ip => ip, :mac => mac).mac, mac.downcase
  end

  def test_should_not_save_invalid_mac
    mac = "XYZxxVVcc123"
    assert_raise Proxy::Validations::Error do
      Proxy::DHCP::Record.new(:subnet => @subnet, :ip => @ip, :mac => mac)
    end
  end

  def test_should_not_save_invalid_subnets
    subnet = nil
    assert_raise Proxy::Validations::Error do
      Proxy::DHCP::Record.new(:subnet => subnet, :ip => @ip, :mac => @mac)
    end
  end

  def test_equality
    assert_equal Proxy::DHCP::Record.new(:subnet => Proxy::DHCP::Subnet.new("192.168.0.0","255.255.255.0"), :ip => @ip, :mac => @mac, :option1 => 'one'),
                 Proxy::DHCP::Record.new(:subnet => Proxy::DHCP::Subnet.new("192.168.0.0","255.255.255.0"), :ip => @ip, :mac => @mac, :option1 => 'one')
    assert_not_equal Proxy::DHCP::Record.new(:subnet => @subnet, :ip => @ip, :mac => @mac, :option1 => 'one'),
                     Proxy::DHCP::Record.new(:subnet => @subnet, :ip => '1.1.1.1', :mac => @mac, :option1 => 'one')
    assert_not_equal Proxy::DHCP::Record.new(:subnet => @subnet, :ip => @ip, :mac => @mac, :option1 => 'one'),
                     Proxy::DHCP::Record.new(:subnet => @subnet, :ip => @ip, :mac => '00:01:02:03:04:05', :option1 => 'one')
    assert_not_equal Proxy::DHCP::Record.new(:subnet => @subnet, :ip => @ip, :mac => @mac, :option1 => 'one'),
                     Proxy::DHCP::Record.new(:subnet => @subnet, :ip => @ip, :mac => @mac, :option2 => 'two')
    assert_not_equal Proxy::DHCP::Record.new(:subnet => @subnet, :ip => @ip, :mac => @mac, :option1 => 'one'),
                     Proxy::DHCP::Record.new(:subnet => ::Proxy::DHCP::Subnet.new("192.168.0.0","255.255.255.128"), :ip => @ip, :mac => @mac, :option1 => 'one')
  end
end
