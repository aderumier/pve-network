package PVE::Network::SDN::Zones::SimplePlugin;

use strict;
use warnings;
use PVE::Network::SDN::Zones::Plugin;
use PVE::Exception qw(raise raise_param_exc);
use PVE::Cluster;
use PVE::Tools;

use base('PVE::Network::SDN::Zones::Plugin');

sub type {
    return 'simple';
}

sub options {
    return {
	nodes => { optional => 1},
	mtu => { optional => 1 }
    };
}

# Plugin implementation
sub generate_sdn_config {
    my ($class, $plugin_config, $zoneid, $vnetid, $vnet, $controller, $subnet_cfg, $interfaces_config, $config) = @_;

    return $config if$config->{$vnetid}; # nothing to do

    my $ipv4 = $vnet->{ipv4};
    my $ipv6 = $vnet->{ipv6};
    my $mac = $vnet->{mac};
    my $alias = $vnet->{alias};
    my $mtu = $plugin_config->{mtu} if $plugin_config->{mtu};

    # vnet bridge
    my @iface_config = ();

    my $address = {};
    my $subnets = PVE::Network::SDN::Vnets::get_subnets($vnetid);
    foreach my $subnetid (sort keys %{$subnets}) {
	my $subnet = $subnets->{$subnetid};
	my $cidr = $subnetid =~ s/-/\//r; 
	my $gateway = $subnet->{gateway};
	if ($gateway) {
	    push @iface_config, "address $gateway" if !defined($address->{$gateway});
	    $address->{$gateway} = 1;
	}
	#add route for /32 pointtopoint
	my ($ip, $mask) = split(/\//, $cidr);
	push @iface_config, "up ip route add $cidr dev $vnetid" if $mask == 32;
	if ($subnet->{snat}) {
	    #find outgoing interface
	    my ($outip, $outiface) = PVE::Network::SDN::Zones::Plugin::get_local_route_ip('8.8.8.8');
	    if ($outip && $outiface) {
		#use snat, faster than masquerade
		push @iface_config, "post-up iptables -t nat -A POSTROUTING -s '$cidr' -o $outiface -j SNAT --to-source $outip";
		push @iface_config, "post-down iptables -t nat -D POSTROUTING -s '$cidr' -o $outiface -j SNAT --to-source $outip";
		#add conntrack zone once on outgoing interface
		push @iface_config, "post-up iptables -t raw -I PREROUTING -i fwbr+ -j CT --zone 1";
		push @iface_config, "post-down iptables -t raw -D PREROUTING -i fwbr+ -j CT --zone 1";
	    }
	}
    }

    push @iface_config, "hwaddress $mac" if $mac;
    push @iface_config, "bridge_ports none";
    push @iface_config, "bridge_stp off";
    push @iface_config, "bridge_fd 0";
    if ($vnet->{vlanaware}) {
        push @iface_config, "bridge-vlan-aware yes";
        push @iface_config, "bridge-vids 2-4094";
    }
    push @iface_config, "mtu $mtu" if $mtu;
    push @iface_config, "alias $alias" if $alias;

    push @{$config->{$vnetid}}, @iface_config;

    return $config;
}

sub status {
    my ($class, $plugin_config, $zone, $vnetid, $vnet, $status) = @_;

    # ifaces to check
    my $ifaces = [ $vnetid ];
    my $err_msg = [];
    foreach my $iface (@{$ifaces}) {
	if (!$status->{$iface}->{status}) {
	    push @$err_msg, "missing $iface";
	} elsif ($status->{$iface}->{status} ne 'pass') {
	    push @$err_msg, "error iface $iface";
	}
    }
    return $err_msg;
}


sub vnet_update_hook {
    my ($class, $vnet) = @_;

    raise_param_exc({ tag => "vlan tag is not allowed on simple bridge"}) if defined($vnet->{tag});

    if (!defined($vnet->{mac})) {
        my $dc = PVE::Cluster::cfs_read_file('datacenter.cfg');
        $vnet->{mac} = PVE::Tools::random_ether_addr($dc->{mac_prefix});
    }
}

1;


