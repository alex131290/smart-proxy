require 'checks'
require 'open3'
require 'dhcp_common/server'

module Proxy::DHCP::NativeMS
  class Provider < ::Proxy::DHCP::Server
    attr_reader :dhcpsapi, :disable_ddns

    def initialize(dhcpsapi, subnets, disable_ddns)
      super('ms dhcp server', subnets, nil)
      @dhcpsapi = dhcpsapi
      @disable_ddns = disable_ddns
    end

    def del_record _, record
      logger.debug "Deleting '#{record}'"
      if record.is_a?(::Proxy::DHCP::Reservation)
        dhcpsapi.delete_reservation(record.ip, record.subnet_address, record.mac)
      else
        dhcpsapi.delete_client_by_ip_address(record.ip)
      end
    end

    def add_record(options)
      to_add = clean_up_add_record_parameters(options)

      validate_ip(to_add[:ip])
      validate_mac(to_add[:mac])
      raise(Proxy::DHCP::Error, "Must provide hostname") unless to_add[:hostname]
      subnet = retrieve_subnet_from_server(to_add[:subnet])

      create_reservation(to_add[:ip], subnet.netmask, to_add[:mac], to_add[:hostname])
      set_option_values(to_add[:ip], subnet.network, build_option_values(to_add))
      dhcpsapi.set_reservation_dns_config(to_add[:ip], subnet.network, false, false, false, false, false) if @disable_ddns
    end

    def create_reservation(ip_address, subnet_mask, mac_address, hostname)
      dhcpsapi.create_reservation(ip_address, subnet_mask, mac_address, hostname)
    rescue  DhcpsApi::Error => e
      raise e if e.error_code != 20_022 # reservation already exists
      begin
        r = dhcpsapi.get_client_by_ip_address(ip_address)
      rescue Exception
        raise e
      end

      if mac_address.casecmp(r[:client_hardware_address]) != 0 ||
          hostname != r[:client_name] || subnet_mask != r[:subnet_mask]
        raise Proxy::DHCP::Collision, "Record #{ip_address}/#{subnet_mask} conflicts with an existing record."
      else
        raise Proxy::DHCP::AlreadyExists, "Record #{ip_address}/#{subnet_mask} already exists."
      end
    end

    def build_option_values(options)
      (options_only = options.clone).delete_if {|k,v| [:ip, :mac, :subnet].include?(k.to_sym) }
      options_only[:PXEClient] = '' unless (dhcpsapi.get_option(Standard[:PXEClient][:code]) rescue nil).nil?
      options_only
    end

    def set_option_values(ip_address, subnet_address, option_values)
      for key, value in option_values
        k = Standard[key] || Standard[key.to_sym]
        next if k.nil?
        dhcpsapi.set_reserved_option_value(
            k[:code],
            ip_address,
            subnet_address,
            dhcps_option_type_from_sunw_kind(k[:kind]),
            [value].flatten)
      end
    end

    def unused_ip(subnet, mac_address, from_address, to_address)
      client = dhcpsapi.get_client_by_mac_address(subnet.network, mac_address) rescue nil
      return client[:client_ip_address] unless client.nil?

      return dhcpsapi.get_free_ip_address(subnet.network, from_address, to_address).first
    end

    def retrieve_subnet_from_server(subnet_address)
      subnet = dhcpsapi.get_subnet(subnet_address)
      # no need for subnet options here, as we only make the call to figure out the subnet mask
      ::Proxy::DHCP::Subnet.new(subnet[:subnet_address], subnet[:subnet_mask])
    end

    def find_vendor(vendor)
      classes = list_vendor_class_names
      shortened_vendor_name = vendor.gsub(/^sun-/i, '')
      classes.find {|cls| cls.include?(shortened_vendor_name)}
    end

    def find_subnet(subnet_address)
      ::Proxy::DHCP::Subnet.new(subnet_address, '255.255.255.0')
    end

    def load_subnets
    end

    def load_subnet_data(subnet)
    end

    def find_record(subnet_address, ip_or_mac_address)
      client = if ip_or_mac_address =~ Resolv::IPv4::Regex
                 dhcpsapi.get_client_by_ip_address(ip_or_mac_address)
               else
                 dhcpsapi.get_client_by_mac_address(subnet_address, ip_or_mac_address)
               end

      reservation_subnet_elements_ips = Set.new(dhcpsapi
                                                    .list_subnet_elements(subnet_address, DhcpsApi::DHCP_SUBNET_ELEMENT_TYPE::DhcpReservedIps)
                                                    .map {|r| r[:element][:reserved_ip_address]})
      if reservation_subnet_elements_ips.include?(client[:client_ip_address])
        standard_option_values = standard_option_values(dhcpsapi.list_reserved_option_values(client[:client_ip_address], subnet_address))
        build_reservation(client, standard_option_values)
      else
        standard_option_values = standard_option_values(dhcpsapi.list_subnet_option_values(subnet_address))
        build_lease(client, standard_option_values)
      end
    rescue DhcpsApi::Error => e
      return nil if e.error_code == 20_013 # not found
      raise e
    end

    def subnets
      subnets = dhcpsapi.list_subnets

      subnets.select {|subnet| managed_subnet?("#{subnet[:subnet_address]}/#{subnet[:subnet_mask]}")}.map do |subnet|
        standard_option_values = standard_option_values(dhcpsapi.list_subnet_option_values(subnet[:subnet_address]))
        Proxy::DHCP::Subnet.new(subnet[:subnet_address], subnet[:subnet_mask], standard_option_values)
      end
    end

    def all_hosts(subnet_address)
      reservation_subnet_elements_ips = Set.new(dhcpsapi
                                                    .list_subnet_elements(subnet_address, DhcpsApi::DHCP_SUBNET_ELEMENT_TYPE::DhcpReservedIps)
                                                    .map {|r| r[:element][:reserved_ip_address]})
      clients = dhcpsapi.list_clients_2008(subnet_address)
      clients.select {|client| reservation_subnet_elements_ips.include?(client[:client_ip_address])}.map {|client| build_reservation(client, {})}.compact
    end

    def build_reservation(client, options)
      opts = {:subnet => client_subnet(client[:client_ip_address], client[:subnet_mask]),
              :ip => client[:client_ip_address],
              :mac => client[:client_hardware_address].downcase, #foreman expects lower-case mac address
              :name => client[:client_name],
              :hostname => client[:client_name],
              :deleteable => true}
      opts.merge!(options)
      logger.debug opts.inspect
      Proxy::DHCP::Reservation.new(opts)
    rescue Exception
      logger.debug("Skipping a reservation as it failed validation: '%s'" % [opts.inspect])
      nil
    end

    def client_subnet(ip_address, ip_mask)
      ::Proxy::DHCP::Subnet.new((IPAddr.new("#{ip_address}/#{ip_mask}") & ip_mask).to_s, ip_mask)
    end

    def all_leases(subnet_address)
      reservation_subnet_elements_ips = Set.new(dhcpsapi
                                                    .list_subnet_elements(subnet_address, DhcpsApi::DHCP_SUBNET_ELEMENT_TYPE::DhcpReservedIps)
                                                    .map {|r| r[:element][:reserved_ip_address]})
      clients = dhcpsapi.list_clients_2008(subnet_address)
      clients.select {|client| !reservation_subnet_elements_ips.include?(client[:client_ip_address])}.map {|client| build_lease(client, {})}.compact
    end

    def build_lease(client, options)
      opts = {:subnet => client_subnet(client[:client_ip_address], client[:subnet_mask]),
              :ip => client[:client_ip_address],
              :mac => client[:client_hardware_address].downcase, #foreman expects lower-case mac address
              :name => (client[:client_name] || '*lease*'),
              :ends => client[:client_lease_expires]}
      opts.merge!(options)
      logger.debug opts.inspect
      Proxy::DHCP::Lease.new(opts)
    rescue Exception
      logger.debug("Skipping a lease as it failed validation: '%s'" % [opts.inspect])
      nil
    end

    def standard_option_values(option_values)
      option_values.inject({}) do |all, current|
        current_values = current[:value].map {|v| v[:element]}
        if standard_option_names.key?(current[:option_id])
          all[n = standard_option_names[current[:option_id]]] = Standard[n][:is_list] ? current_values : current_values.first
        else
          all[current[:option_id]] = current_values.size > 1 ? current_values : current_values.first
        end
        all
      end
    end

    def vendor_option_values(option_values, vendor)
      return {} if vendor.nil?
      to_return = option_values.inject({}) do |all, current|
        current_values = current[:value].map {|v| v[:element]}
        all[sunw_option(current[:option_id]) || current[:option_id]] = (current_values.size > 1 ? current_values : current_values.first)
        all
      end
      to_return.empty? ? to_return : to_return.merge(:vendor => vendor)
    end

    def install_vendor_class(vendor_class)
      dhcpsapi.create_class(vendor_class, "Vendor class for #{vendor_class}", true, "SUNW.#{vendor_class}")
      for option in [:root_server_ip, :root_server_hostname, :root_path_name, :install_server_ip, :install_server_name,
                     :install_path, :sysid_server_path, :jumpstart_server_path]
        dhcpsapi.create_option(SUNW[option][:code], option.to_s, "", dhcps_option_type_from_sunw_kind(SUNW[option][:kind]), false, vendor_class)
      end
      vendor_class
    end

    def dhcps_option_type_from_sunw_kind(kind)
      case kind
      when "IPAddress"
       DhcpsApi::DHCP_OPTION_DATA_TYPE::DhcpIpAddressOption
      when "String"
       DhcpsApi::DHCP_OPTION_DATA_TYPE::DhcpStringDataOption
      else
       raise "Unknown option type '#{kind}'"
      end
    end

    def list_vendor_class_names
      dhcpsapi.list_classes.select {|cls| cls[:is_vendor]}.map {|cls| cls[:class_name]}
    end

    def list_non_standard_vendor_class_names
      list_vendor_class_names - ['Microsoft Windows 2000 Options', 'Microsoft Windows 98 Options', 'Microsoft Options']
    end

    def standard_option_names
      @standard_options_by_id ||= generate_standard_options_by_id
    end

    def generate_standard_options_by_id
      Standard.inject({}) { |all, current| all[current[1][:code]] = current[0]; all }
    end

    def sunw_option(option_id)
      @sunw_options_by_id ||= generate_sunw_options_by_id
      @sunw_options_by_id[option_id]
    end

    def generate_sunw_options_by_id
      SUNW.inject({}) { |all, current| all[current[1][:code]] = current[0]; all }
    end

    def vendor_options_supported?
      true
    end
  end
end
