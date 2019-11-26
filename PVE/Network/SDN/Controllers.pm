package PVE::Network::SDN::Controllers;

use strict;
use warnings;

use Data::Dumper;
use JSON;

use PVE::Tools qw(extract_param dir_glob_regex run_command);
use PVE::Cluster qw(cfs_read_file cfs_write_file cfs_lock_file);

use PVE::Network::SDN::Vnets;
use PVE::Network::SDN::Zones;

use PVE::Network::SDN::Controllers::EvpnPlugin;
use PVE::Network::SDN::Controllers::FaucetPlugin;
use PVE::Network::SDN::Controllers::Plugin;
PVE::Network::SDN::Controllers::EvpnPlugin->register();
PVE::Network::SDN::Controllers::FaucetPlugin->register();
PVE::Network::SDN::Controllers::Plugin->init();


sub sdn_controllers_config {
    my ($cfg, $id, $noerr) = @_;

    die "no sdn controller ID specified\n" if !$id;

    my $scfg = $cfg->{ids}->{$id};
    die "sdn '$id' does not exists\n" if (!$noerr && !$scfg);

    return $scfg;
}

sub config {
    my $config = cfs_read_file("sdn/controllers.cfg.new");
    $config = cfs_read_file("sdn/controllers.cfg") if !keys %{$config->{ids}};
    return $config;
}

sub write_config {
    my ($cfg) = @_;

    cfs_write_file("sdn/controllers.cfg.new", $cfg);
}

sub lock_sdn_controllers_config {
    my ($code, $errmsg) = @_;

    cfs_lock_file("sdn/controllers.cfg.new", undef, $code);
    if (my $err = $@) {
        $errmsg ? die "$errmsg: $err" : die $err;
    }
}

sub sdn_controllers_ids {
    my ($cfg) = @_;

    return keys %{$cfg->{ids}};
}

sub complete_sdn_controller {
    my ($cmdname, $pname, $cvalue) = @_;

    my $cfg = PVE::Network::SDN::config();

    return  $cmdname eq 'add' ? [] : [ PVE::Network::SDN::sdn_controllers_ids($cfg) ];
}

sub generate_controller_config {

    my $vnet_cfg = PVE::Cluster::cfs_read_file('sdn/vnets.cfg');
    my $transport_cfg = PVE::Cluster::cfs_read_file('sdn/zones.cfg');
    my $controller_cfg = PVE::Cluster::cfs_read_file('sdn/controllers.cfg');
    return if !$vnet_cfg && !$transport_cfg && !$controller_cfg;

    #read main config for physical interfaces
    my $current_config_file = "/etc/network/interfaces";
    my $fh = IO::File->new($current_config_file);
    my $interfaces_config = PVE::INotify::read_etc_network_interfaces(1,$fh);
    $fh->close();

    #check uplinks
    my $uplinks = {};
    foreach my $id (keys %{$interfaces_config->{ifaces}}) {
	my $interface = $interfaces_config->{ifaces}->{$id};
	if (my $uplink = $interface->{'uplink-id'}) {
	    die "uplink-id $uplink is already defined on $uplinks->{$uplink}" if $uplinks->{$uplink};
	    $interface->{name} = $id;
	    $uplinks->{$interface->{'uplink-id'}} = $interface;
	}
    }

    #generate configuration
    my $config = {};

    foreach my $id (keys %{$controller_cfg->{ids}}) {
	my $plugin_config = $controller_cfg->{ids}->{$id};
	my $plugin = PVE::Network::SDN::Controllers::Plugin->lookup($plugin_config->{type});
	$plugin->generate_controller_config($plugin_config, $plugin_config, $id, $uplinks, $config);
    }

    foreach my $id (keys %{$transport_cfg->{ids}}) {
	my $plugin_config = $transport_cfg->{ids}->{$id};
	my $controllerid = $plugin_config->{controller};
	next if !$controllerid;
	my $controller = $transport_cfg->{ids}->{$controllerid};
	if ($controller) {
	    my $controller_plugin = PVE::Network::SDN::Controllers::Plugin->lookup($controller->{type});
	    $controller_plugin->generate_controller_transport_config($plugin_config, $controller, $id, $uplinks, $config);
	}
    }

    foreach my $id (keys %{$vnet_cfg->{ids}}) {
	my $plugin_config = $vnet_cfg->{ids}->{$id};
	my $transportid = $plugin_config->{zone};
	next if !$transportid;
	my $transport = $transport_cfg->{ids}->{$transportid};
	next if !$transport;
	my $controllerid = $transport->{controller};
	next if !$controllerid;
	my $controller = $controller_cfg->{ids}->{$controllerid};
	if ($controller) {
	    my $controller_plugin = PVE::Network::SDN::Controllers::Plugin->lookup($controller->{type});
	    $controller_plugin->generate_controller_vnet_config($plugin_config, $controller, $transportid, $id, $config);
	}
    }

    return $config;
}


sub reload_controller {

    my $controller_cfg = PVE::Cluster::cfs_read_file('sdn/controllers.cfg');
    return if !$controller_cfg;

    foreach my $id (keys %{$controller_cfg->{ids}}) {
	my $plugin_config = $controller_cfg->{ids}->{$id};
	my $plugin = PVE::Network::SDN::Controllers::Plugin->lookup($plugin_config->{type});
	$plugin->reload_controller();
    }
}

sub write_controller_config {
    my ($config) = @_;

    my $controller_cfg = PVE::Cluster::cfs_read_file('sdn/controllers.cfg');
    return if !$controller_cfg;

    foreach my $id (keys %{$controller_cfg->{ids}}) {
	my $plugin_config = $controller_cfg->{ids}->{$id};
	my $plugin = PVE::Network::SDN::Controllers::Plugin->lookup($plugin_config->{type});
	$plugin->write_controller_config($plugin_config, $config);
    }
}

1;

