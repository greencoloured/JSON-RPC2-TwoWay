package JSON::RPC2::TwoWay::Connection;

use 5.10.0;
use strict;
use warnings;

our $VERSION = '0.01';

# standard perl
use Carp;
use Data::Dumper;
use Digest::MD5 qw(md5_base64);
use Scalar::Util qw(refaddr);

# cpan
use JSON::MaybeXS;

use constant ERR_REQ    => -32600;

sub new {
	my ($class, %opt) = @_;
	croak 'no rpc?' unless $opt{rpc} and $opt{rpc}->isa('JSON::RPC2::TwoWay');
	#croak 'no stream?' unless $opt->{stream} and $opt->{stream}->can('write');
	croak 'no write?' unless $opt{write} and ref $opt{write} eq 'CODE';
	my $self = {
		calls => {},
		debug => $opt{debug} // 0,
		next_id => 1,
		owner => $opt{owner},
		rpc => $opt{rpc},
		state => undef,
		#stream => $opt->{stream},
		write => $opt{write},
	};
	return bless $self, $class;
}

sub call {
	my ($self, $name, $args, $cb) = @_;
	croak 'no self?' unless $self;
	croak 'args should be a array or hash reference'
		unless ref $args eq 'ARRAY' or ref $args eq 'HASH';
	croak 'callback should be a code reference' if defined $cb and ref $cb ne 'CODE';	
	$cb = \&dinges unless $cb;
	my $id = md5_base64($self->{next_id}++ . $name . encode_json($args) . refaddr($cb));
	croak 'this should not happen' if $self->{calls}->{$id};
	my $request = encode_json({
		jsonrpc => '2.0',
		method => $name,
		params => $args,
		id  => $id,
	});
	$self->{calls}->{$id} = $cb; # more?
	#say STDERR "call: $request" if $self->{debug};
	$self->_write($request);
}

sub notify {
	my ($self, $name, $args, $cb) = @_;
	croak 'no self?' unless $self;
	croak 'args should be a array of hash reference'
		unless ref $args eq 'ARRAY' or ref $args eq 'HASH';
	my $request = encode_json({
		jsonrpc => '2.0',
		method => $name,
		params => $args,
	});
	#say STDERR "notify: $request" if $self->{debug};
	$self->_write($request);
}

sub handle {
	my ($self, $json) = @_;
	my @err = $self->_handle($json);
	$self->{rpc}->_error($self, undef, ERR_REQ, 'Invalid Request: ' . $err[0]) if $err[0];
        return @err;
}

sub _handle {
	my ($self, $json) = @_;
	say STDERR '    handle: ', $json if $self->{debug};
	local $@;
	my $r = eval { decode_json($json) };
	return "json decode failed: $@" if $@;
	return 'not a json object' if ref $r ne 'HASH';
	return 'expected jsonrpc version 2.0' unless defined $r->{jsonrpc} and $r->{jsonrpc} eq '2.0';
	return 'id is not a string or number' if exists $r->{id} and (not defined $r->{id} or ref $r->{id});
	if (defined $r->{method}) {
		return $self->{rpc}->_handle_request($self, $r);
	} elsif (defined $r->{id} and (exists $r->{result} or defined $r->{error})) {
		return $self->_handle_response($r);
	} else {
		return 'invalid jsonnrpc object';
	}
}

sub _handle_response {
	my ($self, $r) = @_;
	#say STDERR '_handle_response: ', Dumper($r) if $self->{debug};
	my $id = $r->{id};
	my $cb = delete $self->{calls}->{$id};
	return undef, 'unknown call' unless $cb and ref $cb eq 'CODE';
	if (defined $r->{error}) {
		my $e = $r->{error};
		return 'error is not an object' unless ref $e eq 'HASH';
		return 'error code is not a integer' unless defined $e->{code} and $e->{code} =~ /^-?\d+$/;
        	return 'error message is not a string' if ref $e->{message};
        	return 'extra members in error object' if (keys %$e == 3 and !exists $e->{data}) or (keys %$e > 2);
        	$cb->($r->{error});
	} else {
		$cb->(0, $r->{result});
	}
	return;
}

sub _write {
	my $self = shift;
	say STDERR '    writing: ', @_ if $self->{debug};
	#$self->{stream}->write(@_);
	$self->{write}->(@_);
}

sub owner {
	my $self = shift;
	$self->{owner} = shift if (@_);
	return $self->{owner};
}

sub state {
	my $self = shift;
	$self->{state} = shift if (@_);
	return $self->{state};
}


sub close {
	my $self = shift;
	%$self = (); # nuke'm all
}

#sub DESTROY {
#	my $self = shift;
#	say STDERR 'destroying ', $self;
#}

1;

=encoding utf8

=head1 NAME

JSON::RPC2::TwoWay::Connection - Transport-independent bidirectional JSON-RPC 2.0 connection

=head1 SYNOPSIS

  $rpc = JSON::RPC2::TwoWay->new();
  $rpc->register('ping', \&handle_ping);

  $con = $rpc->newconnection(
    owner => $owner, 
    write => sub { $stream->write(@_) }
  );
  $err = $con->serve($stream->read);
  die $err if $err;

=head1 DESCRIPTION

L<JSON::RPC2::TwoWay::Connection> is a connection containter for
L<JSON::RPC2::TwoWay>.

=head1 METHODS

=head2 new

$con = JSON::RPC2::TwoWay::Connection->new(option => ...);

Class method that returns a new JSON::RPC2::TwoWay::Connection object.
Use newconnection() on a L<JSON::RPC2::TwoWay> object instead.

Valid arguments are:

=over 4

=item - debug: print debugging to STDERR

(default false)

=item - owner: 'owner' object of this connection.

When provided this object will be asked for the 'state' of the connection.
Otherwise state will always be 0.

=item - rpc: the L<JSON::RPC2::TwoWay> object to handle incoming method calls

(required)

=item - write: a coderef called for writing

This coderef will be called for all output: both requests and responses.
(required)

=back

=head2 call

$con->call('method', { arg => 'foo' }, $cb);

Calls the remote method indicated if the first argument.

The second argument should either be a arrayref or hashref, depending on
wether the remote method requires positional of by-name arguments.  Pass a
empty reference when there are no arguments.

The optional third argument is a callback: when present this callback will
be called with the results of the method and call will return immediately.

=head2 notify

$con->notify('notify_me', { baz => 'foo' })

Calls the remote method as a notification, i.e. no response will be expected.
The notify method returns immediately.

=head2 handle

$con->handle($jsonblob)

Handle the incoming request or response.


$rpc->register('my_method', sub { ... }, { option => ... });

Register a new method to be callable. Calls are passed to the callback.

Valid options are:

=over 4

=item - by_name

When true the arguments to the method will be passed in as a hashref,
otherwise as a arrayref.  (default true)

=item - non_blocking

When true the method callback will receive a callback as its last argument
for passing back the results (default false)

=item - notification

When true the method is a notification and no return value is expected by
the caller.  (Any returned values will be discarded in the handler.)

=item - state

When defined must be a string value defining the state the connection (see
L<newconnection>) must be in for this call to be accepted.

=back

=head1 SEE ALSO

=over

=item *

L<JSON::RPC2::TwoWay>

=item *

L<http://www.jsonrpc.org/specification>: JSON-RPC 2.0 Specification

=back

=head1 ACKNOWLEDGEMENT

This software has been developed with support from L<STRATO|https://www.strato.com/>.
In German: Diese Software wurde mit Unterstützung von L<STRATO|https://www.strato.de/> entwickelt.

=head1 AUTHORS

=over 4

=item *

Wieger Opmeer <wiegerop@cpan.org>

=back

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2016 by Wieger Opmeer.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut

