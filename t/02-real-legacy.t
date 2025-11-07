#!/usr/bin/perl

use strict;
use warnings;
use 5.10.0;

use FindBin;
use lib (
	"$FindBin::Bin/lib",
	"$FindBin::Bin/../lib",
);

use Test::More tests => 44;
use Tests;

my $rpc = JSON::RPC2::TwoWay->new(legacy_mode => 1);

run($rpc);
