package PVE::API2::Network::SDN::Vnets;

use strict;
use warnings;

use PVE::SafeSyslog;
use PVE::Tools qw(extract_param);
use PVE::Cluster qw(cfs_read_file cfs_write_file);
use PVE::Network::SDN;
use PVE::Network::SDN::Zones;
use PVE::Network::SDN::Zones::Plugin;
use PVE::Network::SDN::Vnets;
use PVE::Network::SDN::VnetPlugin;
use PVE::Network::SDN::Subnets;
use PVE::API2::Network::SDN::Subnets;

use Storable qw(dclone);
use PVE::JSONSchema qw(get_standard_option);
use PVE::RPCEnvironment;
use PVE::Exception qw(raise raise_param_exc);

use PVE::RESTHandler;

use base qw(PVE::RESTHandler);

__PACKAGE__->register_method ({
    subclass => "PVE::API2::Network::SDN::Subnets",
    path => '{vnet}/subnets',
});

my $api_sdn_vnets_config = sub {
    my ($cfg, $id) = @_;

    my $scfg = dclone(PVE::Network::SDN::Vnets::sdn_vnets_config($cfg, $id));
    $scfg->{vnet} = $id;
    $scfg->{digest} = $cfg->{digest};
    
    return $scfg;
};

my $api_sdn_vnets_deleted_config = sub {
    my ($cfg, $running_cfg, $id) = @_;

    if (!$cfg->{ids}->{$id}) {

	my $vnet_cfg = dclone(PVE::Network::SDN::Vnets::sdn_vnets_config($running_cfg->{vnets}, $id));
	$vnet_cfg->{state} = "deleted";
	$vnet_cfg->{vnet} = $id;
	return $vnet_cfg;
    }
};

__PACKAGE__->register_method ({
    name => 'index',
    path => '',
    method => 'GET',
    description => "SDN vnets index.",
    permissions => {
	description => "Only list entries where you have 'SDN.Audit' or 'SDN.Allocate'"
	    ." permissions on '/sdn/vnets/<vnet>'",
	user => 'all',
    },
    parameters => {
	additionalProperties => 0,
	properties => {
            running => {
                type => 'boolean',
                optional => 1,
                description => "Display running config.",
            },
	    pending => {
		type => 'boolean',
		optional => 1,
		description => "Display pending config.",
	    },
	},
    },
    returns => {
	type => 'array',
	items => {
	    type => "object",
	    properties => {},
	},
	links => [ { rel => 'child', href => "{vnet}" } ],
    },
    code => sub {
	my ($param) = @_;

	my $rpcenv = PVE::RPCEnvironment::get();
	my $authuser = $rpcenv->get_user();

	my $cfg = {};
	if($param->{pending}) {
	    my $running_cfg = PVE::Network::SDN::config();
	    my $config = PVE::Network::SDN::Vnets::config();
	    $cfg = PVE::Network::SDN::pending_config($running_cfg, $config, 'vnets');
	} elsif ($param->{running}) {
	    my $running_cfg = PVE::Network::SDN::config();
	    $cfg = $running_cfg->{vnets};
	} else {
	    $cfg = PVE::Network::SDN::Vnets::config();
	}

	my @sids = PVE::Network::SDN::Vnets::sdn_vnets_ids($cfg);
	my $res = [];
	foreach my $id (@sids) {
	    my $privs = [ 'SDN.Audit', 'SDN.Allocate' ];
	    next if !$rpcenv->check_any($authuser, "/sdn/vnets/$id", $privs, 1);

	    my $scfg = &$api_sdn_vnets_config($cfg, $id);
	    push @$res, $scfg;
	}

	return $res;
    }});

__PACKAGE__->register_method ({
    name => 'read',
    path => '{vnet}',
    method => 'GET',
    description => "Read sdn vnet configuration.",
    permissions => {
	check => ['perm', '/sdn/vnets/{vnet}', ['SDN.Allocate']],
   },
    parameters => {
	additionalProperties => 0,
	properties => {
	    vnet => get_standard_option('pve-sdn-vnet-id', {
		completion => \&PVE::Network::SDN::Vnets::complete_sdn_vnets,
	    }),
            running => {
                type => 'boolean',
                optional => 1,
                description => "Display running config.",
            },
	    pending => {
		type => 'boolean',
		optional => 1,
		description => "Display pending config.",
	    },
	},
    },
    returns => { type => 'object' },
    code => sub {
	my ($param) = @_;

	my $cfg = {};
	if($param->{pending}) {
	    my $running_cfg = PVE::Network::SDN::config();
	    my $config = PVE::Network::SDN::Vnets::config();
	    $cfg = PVE::Network::SDN::pending_config($running_cfg, $config, 'vnets');
	} elsif ($param->{running}) {
	    my $running_cfg = PVE::Network::SDN::config();
	    $cfg = $running_cfg->{vnets};
	} else {
	    $cfg = PVE::Network::SDN::Vnets::config();
	}

	return $api_sdn_vnets_config->($cfg, $param->{vnet});
    }});

__PACKAGE__->register_method ({
    name => 'create',
    protected => 1,
    path => '',
    method => 'POST',
    description => "Create a new sdn vnet object.",
    permissions => {
	check => ['perm', '/sdn/vnets', ['SDN.Allocate']],
    },
    parameters => PVE::Network::SDN::VnetPlugin->createSchema(),
    returns => { type => 'null' },
    code => sub {
	my ($param) = @_;

	my $type = extract_param($param, 'type');
	my $id = extract_param($param, 'vnet');

	PVE::Cluster::check_cfs_quorum();
	mkdir("/etc/pve/sdn");

        PVE::Network::SDN::lock_sdn_config(sub {
	    my $cfg = PVE::Network::SDN::Vnets::config();
	    my $opts = PVE::Network::SDN::VnetPlugin->check_config($id, $param, 1, 1);

	    if (PVE::Network::SDN::Vnets::sdn_vnets_config($cfg, $id, 1)) {
		die "sdn vnet object ID '$id' already defined\n";
	    }
	    $cfg->{ids}->{$id} = $opts;

	    my $zone_cfg = PVE::Network::SDN::Zones::config();
	    my $zoneid = $cfg->{ids}->{$id}->{zone};
	    my $plugin_config = $zone_cfg->{ids}->{$zoneid};
	    my $plugin = PVE::Network::SDN::Zones::Plugin->lookup($plugin_config->{type});
            $plugin->vnet_update_hook($cfg, $id, $zone_cfg);

	    PVE::Network::SDN::VnetPlugin->on_update_hook($id, $cfg);

	    PVE::Network::SDN::Vnets::write_config($cfg);

	}, "create sdn vnet object failed");

	return undef;
    }});

__PACKAGE__->register_method ({
    name => 'update',
    protected => 1,
    path => '{vnet}',
    method => 'PUT',
    description => "Update sdn vnet object configuration.",
    permissions => {
	check => ['perm', '/sdn/vnets', ['SDN.Allocate']],
    },
    parameters => PVE::Network::SDN::VnetPlugin->updateSchema(),
    returns => { type => 'null' },
    code => sub {
	my ($param) = @_;

	my $id = extract_param($param, 'vnet');
	my $digest = extract_param($param, 'digest');

	PVE::Network::SDN::lock_sdn_config(sub {
	    my $cfg = PVE::Network::SDN::Vnets::config();

	    PVE::SectionConfig::assert_if_modified($cfg, $digest);


	    my $opts = PVE::Network::SDN::VnetPlugin->check_config($id, $param, 0, 1);
	    raise_param_exc({ zone => "missing zone"}) if !$opts->{zone};
	    my $subnets = PVE::Network::SDN::Vnets::get_subnets($id);
	    raise_param_exc({ zone => "can't change zone if subnets exists"}) if($subnets && $opts->{zone} ne $cfg->{ids}->{$id}->{zone});

	    $cfg->{ids}->{$id} = $opts;

	    my $zone_cfg = PVE::Network::SDN::Zones::config();
	    my $zoneid = $cfg->{ids}->{$id}->{zone};
	    my $plugin_config = $zone_cfg->{ids}->{$zoneid};
	    my $plugin = PVE::Network::SDN::Zones::Plugin->lookup($plugin_config->{type});
	    $plugin->vnet_update_hook($cfg, $id, $zone_cfg);

	    PVE::Network::SDN::VnetPlugin->on_update_hook($id, $cfg);

	    PVE::Network::SDN::Vnets::write_config($cfg);

	}, "update sdn vnet object failed");

	return undef;
    }
});

__PACKAGE__->register_method ({
    name => 'delete',
    protected => 1,
    path => '{vnet}',
    method => 'DELETE',
    description => "Delete sdn vnet object configuration.",
    permissions => {
	check => ['perm', '/sdn/vnets', ['SDN.Allocate']],
    },
    parameters => {
	additionalProperties => 0,
	properties => {
	    vnet => get_standard_option('pve-sdn-vnet-id', {
		completion => \&PVE::Network::SDN::Vnets::complete_sdn_vnets,
	    }),
	},
    },
    returns => { type => 'null' },
    code => sub {
	my ($param) = @_;

	my $id = extract_param($param, 'vnet');

        PVE::Network::SDN::lock_sdn_config(sub {
	    my $cfg = PVE::Network::SDN::Vnets::config();
	    my $scfg = PVE::Network::SDN::Vnets::sdn_vnets_config($cfg, $id); # check if exists
	    my $vnet_cfg = PVE::Network::SDN::Vnets::config();

	    PVE::Network::SDN::VnetPlugin->on_delete_hook($id, $vnet_cfg);

	    delete $cfg->{ids}->{$id};
	    PVE::Network::SDN::Vnets::write_config($cfg);

	}, "delete sdn vnet object failed");


	return undef;
    }
});

1;
