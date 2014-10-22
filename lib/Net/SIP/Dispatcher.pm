
###########################################################################
# package Net::SIP::Dispatcher
#
# Manages the sending of SIP packets to the legs (and finding out which
# leg can be used) and the receiving of SIP packets and forwarding to
# the upper layer.
# Handles retransmits
###########################################################################

use strict;
use warnings;

package Net::SIP::Dispatcher;
use fields (
	# interface to outside
	'receiver',       # callback into upper layer
	'legs',           # \@list of Net::SIP::Legs managed by dispatcher
	'eventloop',      # Net::SIP::Dispatcher::Eventloop or similar
	'outgoing_proxy', # optional fixed outgoing proxy
	'domain2proxy',   # optional mapping between SIP domains and proxies (otherwise use DNS)
	# internals
	'do_retransmits', # flag if retransmits will be done (false for stateless proxy)
	'outgoing_leg',   # Leg for outgoing_proxy
	'queue',          # \@list of outstanding Net::SIP::Dispatcher::Packet
	'response_cache', # Cache of responses, used to reply to retransmits
);

use Net::SIP::Leg;
use Net::SIP::Util qw( invoke_callback sip_uri2parts );
use Errno qw(EHOSTUNREACH ETIMEDOUT ENOPROTOOPT EINVAL);
use IO::Socket;
use List::Util 'first';
use Net::DNS;
use Carp 'croak';
use Net::SIP::Debug;


###########################################################################
# create new dispatcher
# Args: ($class,$legs,$eventloop;%args)
#  $legs:           \@array, see add_leg()
#  $eventloop:      Net::SIP::Dispatcher::Eventloop or similar
#  %args:
#   outgoing_proxy: optional outgoing proxy (ip:port)
#   do_retransmits: set if the dispatcher has to handle retransmits by itself
#       defaults to true
#   domain2proxy: mappings { domain => proxy } if a fixed proxy is used
#       for specific domains, otherwise lookup will be done per DNS
#       proxy can be ip,ip:port or \@list of [ prio,proto,ip,port ] like
#       in the DNS SRV record.
#       with special domain '*' a default can be specified, so that DNS
#       will not be used at all
# Returns: $self
###########################################################################
sub new {
	my ($class,$legs,$eventloop,%args) = @_;

	my ($outgoing_proxy,$do_retransmits,$domain2proxy)
		= delete @args{qw( outgoing_proxy do_retransmits domain2proxy )};
	die "bad args: ".join( ' ',keys %args ) if %args;

	$eventloop ||= Net::SIP::Dispatcher::Eventloop->new;

	# normalize domain2proxy so that its the same format one gets from
	# the SRV record
	$domain2proxy ||= {};
	foreach ( values %$domain2proxy ) {
		if ( ref($_) ) { # should be \@list of [ prio,proto,ip,port ]
		} elsif ( m{^(?:(udp|tcp):)?([^:]+)(?::(\d+))?$} ) {
			my @proto = $1 ? ( $1 ) : ( 'udp','tcp' );
			my $host = $2;
			my $port = $3 || 5060;
			$_ = [ map { [ -1, $_, $host, $port ] } @proto ];
		} else {
			croak( "invalid entry in domain2proxy: $_" );
		}
	}

	my $self = fields::new($class);
	%$self = (
		legs => [],
		queue  => [],
		outgoing_proxy => undef,
		outgoing_leg => undef,
		response_cache => {},
		do_retransmits => defined( $do_retransmits ) ? $do_retransmits : 1,
		eventloop => $eventloop,
		domain2proxy => $domain2proxy,
	);

	$self->add_leg( @$legs );

	if ( $outgoing_proxy ) {
		my $leg = $self->_find_leg4addr( $outgoing_proxy )
			|| die "cannot find leg for destination $outgoing_proxy";
		$self->{outgoing_proxy} = $outgoing_proxy;
		$self->{outgoing_leg}   = $leg;
	}


	# regularly prune queue
	my $sub = sub {
		my ($self,$loop) = @_;
		$self->queue_expire($loop->looptime);
	};
	$self->add_timer( 1,[ $sub,$self,$eventloop ],1,'disp_expire' );

	return $self;
}

###########################################################################
# set receiver, e.g the upper layer which gets the incoming packets
# received by the dispatcher
# Args: ($self,$receiver)
#   $receiver: object which has receive( Net::SIP::Leg,Net::SIP::Packet )
#     method to handle incoming SIP packets or callback
# Returns: NONE
###########################################################################
sub set_receiver {
	my Net::SIP::Dispatcher $self = shift;
	my $receiver = shift;
	if ( my $sub = UNIVERSAL::can($receiver,'receive' )) {
		# Object with method receive()
		$receiver = [ $sub,$receiver ]
	}
	$self->{receiver} = $receiver;
}

###########################################################################
# adds a leg to the dispatcher
# Args: ($self,@legs)
#  @legs: can be sockets, \%args for constructing or already
#    objects of class Net::SIP::Leg
# Returns: NONE
###########################################################################
sub add_leg {
	my Net::SIP::Dispatcher $self = shift;
	my $legs = $self->{legs};
	foreach my $data (@_) {

		my $leg;
		# if it is not a leg yet create one based
		# on the arguments
		if ( UNIVERSAL::isa( $data,'Net::SIP::Leg' )) {
			# already a leg
			$leg = $data;

		} elsif ( UNIVERSAL::isa( $leg,'IO::Handle' )) {
			# create from socket
			$leg = Net::SIP::Leg->new( sock => $data );

		} elsif ( UNIVERSAL::isa( $leg,'HASH' )) {
			# create from %args
			$leg = Net::SIP::Leg->new( %$data );
		} else {
			croak "invalid spec for leg: $data";
		}

		push @$legs, $leg;

		if ( my $fd = $leg->fd ) {
			my $cb = sub {
				my ($self,$leg) = @_;

				# leg->receive might return undef if the packet wasnt
				# read successfully. for tcp connections the receive
				# on a listening socket might cause a new leg to be added
				# which then will receive the packet (maybe over multiple
				# read attempts)
				my ($packet,$from) = $leg->receive or do {
					DEBUG( 50,"failed to receive on leg" );
					return;
				};

				# handle received packet
				$self->receive( $packet,$leg,$from );
			};
			$self->{eventloop}->addFD( $fd, [ $cb,$self,$leg ]);
		}
	}
}

###########################################################################
# remove a leg from the dispatcher
# Args: ($self,@legs)
#  @legs: Net::SIP::Leg objects
# Returns: NONE
###########################################################################
sub remove_leg {
	my Net::SIP::Dispatcher $self = shift;
	my $legs = $self->{legs};
	foreach my $leg (@_) {
		@$legs = grep { $_ != $leg } @$legs;
		if ( my $fd = $leg->fd ) {
			$self->{eventloop}->delFD( $fd );
		}
	}
}

###########################################################################
# find legs matching specific criterias
# Args: ($self,%args)
#  %args: Hash with some of these keys
#    addr: leg must match addr
#    port: leg must match port
#    proto: leg must match proto
#    sock: leg must match sock
#    sub:  $sub->($leg) must return true
# Returns: @legs
#   @legs: all Legs matching the criteria
# Comment:
# if no criteria given it will return all legs
###########################################################################
sub get_legs {
	my Net::SIP::Dispatcher $self = shift;
	return @{ $self->{legs} } if ! @_; # shortcut

	my %args = @_;
	my @rv;
	foreach my $leg (@{ $self->{legs} }) {
		next if $args{addr} && $args{addr} ne $leg->{addr};
		next if $args{port} && $args{port} != $leg->{port};
		next if $args{proto} && $args{proto} ne $leg->{proto};
		next if $args{sock} && $args{sock} != $leg->{sock};
		next if $args{sub} && !invoke_callback( $args{sub},$leg );
		push @rv,$leg
	}
	return @rv;
}


###########################################################################
# add timer
# propagates to add_timer of eventloop
# Args: ($self,$when,$cb,$repeat)
#   $when: when callback gets called, can be absolute time (epoch, time_t)
#     or relative time (seconds)
#   $cb: callback
#   $repeat: after how much seconds it gets repeated (default 0, e.g never)
# Returns: $timer
#   $timer: Timer object, has method cancel for canceling timer
###########################################################################
sub add_timer {
	my Net::SIP::Dispatcher $self = shift;
	return $self->{eventloop}->add_timer( @_ );
}

###########################################################################
# initiate delivery of a packet, e.g. put packet into delivery queue
# Args: ($self,$packet,%more_args)
#   $packet: Net::SIP::Packet which needs to be delivered
#   %more_args: hash with some of the following keys
#     id:        id for packet, used in cancel_delivery
#     callback:  [ \&sub,@arg ] for calling back on definite delivery
#       success (tcp only) or error (timeout,no route,...)
#     leg:       specify outgoing leg, needed for responses
#     dst_addr:  specify outgoing addr [ip,port] or sockaddr, needed
#       for responses
#     do_retransmits: if retransmits should be done, default from
#        global value (see new())
# Returns: NONE
# Comment: no return value, but die()s on errors
###########################################################################
sub deliver {
	my Net::SIP::Dispatcher $self = shift;
	my ($packet,%more_args) = @_;
	my $now = delete $more_args{now};
	my $do_retransmits = delete $more_args{do_retransmits};
	$do_retransmits = $self->{do_retransmits} if !defined $do_retransmits;

	DEBUG( 100,"deliver $packet" );

	if ( $packet->is_response ) {
		# cache response for 32 sec (64*T1)
		my $cid = $packet->get_header( 'cseq' )
			."\0".$packet->get_header( 'call-id' );
		$self->{response_cache}{$cid} = {
			packet => $packet,
			expire => ( $now ||= time()) +32
		};
	}

	my $new_entry = Net::SIP::Dispatcher::Packet->new(
		packet => $packet,
		%more_args
	);

	$new_entry->prepare_retransmits( $now ) if $do_retransmits;

	push @{ $self->{queue}}, $new_entry;
	$self->__deliver( $new_entry );
}

###########################################################################
# cancel delivery of all packets with specific id
# Args: ($self,$id)
#   $id: id to cancel, can also be queue entry
# Returns: NONE
###########################################################################
sub cancel_delivery {
	my Net::SIP::Dispatcher $self = shift;
	my ($id) = @_;
	my $q = $self->{queue};
	if ( ref($id)) {
		# it's a *::Dispatcher::Packet
		DEBUG( 100,"cancel packet $id: $id->{id}" );
		@$q = grep { $_ != $id } @$q;
	} else {
		no warnings; # $_->{id} can be undef
		DEBUG( 100, "cancel packet $id" );
		@$q = grep { $_->{id} ne $id } @$q;
	}
}



###########################################################################
# Receive a packet from a leg and forward it to the upper layer
# if the packet is a request and I have a cached response resend it
# w/o involving the upper layer
# Args: ($self,$packet,$leg,$from)
#   $packet: Net::SIP::Packet
#   $leg:    through which leg it was received
#   $from:   where the packet comes from (ip:port)
# Returns: NONE
# Comment: if no receiver is defined using set_receiver the packet
#   will be silently dropped
###########################################################################
sub receive {
	my Net::SIP::Dispatcher $self = shift;
	my ($packet,$leg,$from) = @_;

	if ( $packet->is_request ) {
		my $cid = $packet->get_header( 'cseq' )
			."\0".$packet->get_header( 'call-id' );

		if ( my $response = $self->{response_cache}{$cid} ) {
			# I have a cached response, use it
			$self->deliver($response->{packet}, leg => $leg, dst_addr => $from);
			return;
		}
	}

	invoke_callback( $self->{receiver},$packet,$leg,$from );
}

###########################################################################
# expire the entries on the queue, eg removes expired entries and
# calls callback if necessary
# expires also the response cache
# Args: ($self;$time)
#   $time: expire regarding $time, if not given use time()
# Returns: undef|$min_expire
#   $min_expire: time when next thing expires (undef if nothing to expire)
###########################################################################
sub queue_expire {
	my Net::SIP::Dispatcher $self = shift;
	my $now = shift || $self->{eventloop}->looptime;

	# expire queue
	my $queue = $self->{queue};
	my (@nq,$changed,$min_expire);
	foreach my $qe (@$queue) {

		my $retransmit;
		if ( my $retransmits = $qe->{retransmits} ) {
			while ( @$retransmits && $retransmits->[0] < $now ) {
				$retransmit = shift(@$retransmits);
			}

			if ( !@$retransmits ) {
				# completly expired
				DEBUG( 50,"entry %s expired because expire=%.2f but now=%d", $qe->tid,$retransmit,$now );
				$changed++;
				$qe->trigger_callback( ETIMEDOUT );

				# don't put into new queue
				next;
			}

			if ( $retransmit ) {
				# need to retransmit the packet
				$self->__deliver( $qe );
			}

			my $next_retransmit = $retransmits->[0];
			if ( !defined($min_expire) || $next_retransmit<$min_expire ) {
				$min_expire = $next_retransmit
			}
		}
		push @nq,$qe;

	}
	$self->{queue} = \@nq if $changed;

	# expire response cache
	my $cache = $self->{response_cache};
	foreach my $cid ( keys %$cache ) {
		my $expire = $cache->{$cid}{expire};
		if ( $expire < $now ) {
			delete $cache->{$cid};
		} elsif ( !defined($min_expire) || $expire<$min_expire ) {
			$min_expire = $expire
		}
	}

	# return time to next expire for optimizations
	return $min_expire;
}


###########################################################################
# the real delivery of a queue entry:
# if no leg,addr try to determine them from request-URI
# prepare timeout handling
# Args: ($self,$qentry)
#   $qentry: Net::SIP::Dispatcher::Packet
# Returns: NONE
# Comment:
# this might be called several times for a queue entry, eg as a callback
# at the various stages (find leg,addr for URI needs DNS lookup which
# might be done asynchronous, eg callback driven, send might be callback
# driven for tcp connections which need connect, multiple writes...)
###########################################################################
sub __deliver {
	my Net::SIP::Dispatcher $self = shift;
	my $qentry = shift;

	# loop until leg und dst_addr are known, when we call leg->deliver
	my $leg = $qentry->{leg}[0];
	my $dst_addr = $qentry->{dst_addr}[0];

	if ( ! $dst_addr || ! $leg) {

		DEBUG( 100,"no dst_addr or leg yet" );

		my $callback = sub {
			my ($self,$qentry,@error) = @_;
			if ( @error ) {
				$qentry->trigger_callback(@error);
				return $self->cancel_delivery( $qentry );
			} else {
				$self->__deliver($qentry);
			}
		};
		return $self->resolve_uri(
			$qentry->{packet}->uri,
			$qentry->{dst_addr},
			$qentry->{leg},
			[ $callback, $self,$qentry ],
			$qentry->{proto},
		);
	}

	# I have leg and addr, send packet thru leg to addr
	my $cb = sub {
		my ($self,$qentry,$error) = @_;
		if ( !$error  && $qentry->{retransmits} ) {
			# remove from queue even if timeout
			$self->cancel_delivery( $qentry );
		}
		$qentry->trigger_callback( $error );
	};

	# adds via on cloned packet, calls cb if definite success (tcp)
	# or error
	DEBUG( 50,"deliver through leg $leg \@$dst_addr" );
	$leg->deliver( $qentry->{packet},$dst_addr, [ $cb,$self,$qentry ] );

	if ( !$qentry->{retransmits} ) {
		# remove from queue if no timeout
		$self->cancel_delivery( $qentry );
	}
}



###########################################################################
# resolve URI, determine dst_addr and outgoing leg
# Args: ($self,$uri,$dst_addr,$legs,$callback;$allowed_proto,$allowed_legs)
#   $uri: URI to resolve
#   $dst_addr: reference to list where to put dst_addr
#   $legs: reference to list where to put leg
#   $callback: called with () if resolved successfully, else called
#      with @error
#   $allowed_proto: optional \@list of protocols (default udp,tcp). If given only
#      only these protocols will be considered and in this order.
#   $allowed_legs: optional list of legs which are allowed
# Returns: NONE
###########################################################################
sub resolve_uri {
	my Net::SIP::Dispatcher $self = shift;
	my ($uri,$dst_addr,$legs,$callback,$allowed_proto,$allowed_legs) = @_;

	# packet should be a request packet (see constructor of *::Dispatcher::Packet)
	my ($domain,$user,$sip_proto,undef,$param) = sip_uri2parts($uri);
	$domain or do {
		DEBUG( 50,"bad URI '$uri'" );
		return invoke_callback($callback, EHOSTUNREACH );
	};

	my @proto;
	my $default_port = 5060;
	# XXXX hack, better would be to really parse URI, see *::Util::sip_hdrval2parts
	if ( $sip_proto eq 'sips' ) {
		$default_port = 5061;
		@proto = 'tcp';
	} elsif ( my $p = $param->{transport} ) {
		# explicit spec of proto
		@proto = lc($p)
	} else {
		# XXXX maybe we should use tcp first if the packet has a specific
		# minimum length, udp should not be used at all if the packet size is > 2**16
		@proto = ( 'udp','tcp' );
	}

	# change @proto so that only the protocols from $allowed_proto are ini it
	# and that they are tried in the order from $allowed_proto
	if ( $allowed_proto && @$allowed_proto ) {
		my @proto_new;
		foreach my $ap ( @$allowed_proto ) {
			my $p = first { $ap eq $_ } @proto;
			push @proto_new,$p if $p;
		}
		@proto = @proto_new;
		@proto or do {
			DEBUG( 50,"no protocols allowed for $uri" );
			return invoke_callback( $callback, ENOPROTOOPT ); # no proto available
		};
	}

	$dst_addr ||= [];
	$allowed_legs ||= [ $self->get_legs ];
	if ( @$legs ) {
		my %allowed = map { $_ => 1 } @$legs;
		@$allowed_legs = grep { $allowed{$_} } @$allowed_legs;
	}
	@$allowed_legs or do {
		DEBUG( 50,"no legs allowed for '$uri'" );
		return invoke_callback($callback, EHOSTUNREACH );
	};

	my $ip_addr;
	if ( $domain =~m{^(\d+\.\d+\.\d+\.\d+)(?::(\d+))?$} ) {
		# if domain part of URI is IPv4[:port]
		$default_port = $2;
		$ip_addr = $1;
		# e.g. 10.0.3.4 should match *.3.0.10.in-addr.arpa
		$domain = join( '.', reverse split( m{\.},$ip_addr )).'.in-addr.arpa';
	} else {
		$domain =~s{\.*(?::(\d+))?$}{}; # remove trailing dots + port
		$default_port = $1 if $1;
	}
	DEBUG( 100,"domain=$domain" );

	# do we have a fixed proxy for the domain or upper domain?
	if ( ! @$dst_addr ) {
		my $d2p = $self->{domain2proxy};
		if ( $d2p && %$d2p ) {
			my $dom = $domain;
			my $addr = $d2p->{$dom}; # exact match
			while ( ! $addr) {
				$dom =~s{^[^\.]+\.}{} or last;
				$addr = $d2p->{ "*.$dom" };
			}
			$addr ||= $d2p->{ $dom = '*'}; # catch-all
			if ( $addr ) {
				DEBUG( 50,"setting dst_addr from domain specific proxy for domain $dom" );
				@$dst_addr = @$addr;
			}
		}
	}

	# do we have a global outgoing proxy?
	if ( !@$dst_addr
		&& ( my $addr = $self->{outgoing_proxy} )) {
		# if we have a fixed outgoing proxy use it
		DEBUG( 50,"setting dst_addr+leg to $addr from outgoing_proxy" );
		@$dst_addr = ( $addr );
	}

	# is it an IP address?
	if ( !@$dst_addr && $ip_addr ) {
		DEBUG( 50,"setting dst_addr from URI because IP address given" );
		@$dst_addr = ( $ip_addr );
	}

	# entries in form [ prio,proto,ip,port ]
	my @resp;
	foreach my $addr ( @$dst_addr ) {
		if ( ref($addr)) {
			push @resp,$addr; # right format: see domain2proxy
		} else {
			$addr =~m{^(?:(udp|tcp):)?([^:]+)(?::(\d+))?$} || next;
			my $host = $2;
			my $proto = $1 ? [ $1 ] : \@proto;
			my $port = $3 ? $3 : $default_port;
			push @resp, map { [ -1,$_,$host,$port ] } @$proto;
		}
	}

	my @param = ( $dst_addr,$legs,$allowed_legs,$default_port,$callback );
	return __resolve_uri_final( @param,0,\@resp ) if @resp;

	# If no fixed mapping DNS needs to be used

	# XXXX no full support for RFC3263, eg we don't support NAPTR
	# but query instead directly for _sip._udp.domain.. like in
	# RFC2543 specified

	return $self->dns_domain2srv(
		$domain, \@proto, $sip_proto,
		[ \&__resolve_uri_final, @param ]
	);
}

sub __resolve_uri_final {

	my ($dst_addr,$legs,$allowed_legs,$default_port,$callback,$error,$resp) = @_;

	DEBUG_DUMP( 100,$resp );
	return invoke_callback( $callback,EHOSTUNREACH )
		unless $resp && @$resp;

	# for A records we got no port, use default_port
	$_->[3] ||= $default_port for(@$resp);

	# sort by prio
	# FIXME: can contradict order in @proto
	@$resp = sort { $a->[0] <=> $b->[0] } @$resp;

	@$dst_addr = ();
	@$legs = ();
	foreach my $r ( @$resp ) {
		my $leg = first { $_->can_deliver_to(
			proto => $r->[1],
			addr  => $r->[2],
			port  => $r->[3]
		)} @$allowed_legs;

		if ( $leg ) {
			push @$dst_addr, "$r->[1]:$r->[2]:$r->[3]";
			push @$legs,$leg;
		} else {
			DEBUG( 50,"no leg for $r->[1]:$r->[2]:$r->[3]" );
		}
	}

	return invoke_callback( $callback, EHOSTUNREACH ) if !@$dst_addr;
	invoke_callback( $callback );
}


sub _find_leg4addr {
	my Net::SIP::Dispatcher $self = shift;
	my $dst_addr = shift;
	my ($proto,$ip) = $dst_addr =~m{^(?:(tcp|udp):)?([^:]+)};
	my @legs;
	foreach my $leg (@{ $self->{legs} }) {
		push @legs,$leg if $leg->can_deliver_to( addr => $ip, proto => $proto );
	}
	return @legs;
}

###########################################################################
# resolve hostname to IP using DNS
# FIXME: should work asynchronously
# Args: ($self,$host,$callback)
#   $host: hostname or hash with hostname as keys
#   $callback: gets called with (EINVAL) or (undef,result) once finished
#     result is IP for single hosts or the input hash ref where the
#     IPs are filled in as values
# Returns: NONE
###########################################################################
sub dns_host2ip {
	my Net::SIP::Dispatcher $self = shift;
	my ($host,$callback) = @_;
	if ( ref($host)) {
		my $err;
		foreach ( keys %$host ) {
			if ( my $addr = gethostbyname( $_ )) {
				$host->{$_} = inet_ntoa($addr);
			} else {
				$err = EINVAL;
			}
		}
		invoke_callback( $callback, $err,$host );
	} else {
		my $addr = gethostbyname( $host );
		invoke_callback( $callback, $addr ? ( undef,inet_ntoa($addr) ) : ( $? ));
	}
}

###########################################################################
# get SRV records using DNS
# FIXME: should work asynchronously
# Args: ($self,$domain,$proto,$sip_proto,$callback)
#   $domain: domain for SRV query
#   $proto: which protocols to check
#   $sip_proto: sip|sips
#   $callback: gets called with result once finished
#      result is \@list of [ prio,proto,name,port ]
# Returns: NONE
###########################################################################
sub dns_domain2srv {
	my Net::SIP::Dispatcher $self = shift;
	my ($domain,$protos,$sip_proto,$callback) = @_;

	# FIXME: don't do blocking DNS queries
	my $dns = Net::DNS::Resolver->new;

	# Try to get SRV records for _sip._udp.domain or _sip._tcp.domain
	my @resp;
	foreach my $proto ( @$protos ) {
		if ( my $q = $dns->query( '_'.$sip_proto.'._'.$proto.'.'.$domain,'SRV' )) {
			foreach my $rr ( $q->answer ) {
				$rr->type eq 'SRV' || next;
				# XXX fixme, get IPs for name
				push @resp,[ $rr->priority, $proto,$rr->name,$rr->port ]
			}
		}
	}
	# if no SRV records try to resolve address directly
	unless (@resp) {
		# try addr directly
		my $default_port = $sip_proto eq 'sips' ? 5061:5060;
		if ( my $q = $dns->query( $domain,'A' )) {
			foreach my $rr ($q->answer ) {
				$rr->type eq 'A' || next;
				# XXX fixme, get *all* IPs for name
				push @resp,map {
					[ -1, $_ , $rr->address,$default_port ]
				} @$protos;
			}
		}
	}
	my $error = @resp ? 0 : EINVAL;
	invoke_callback( $callback,$error,\@resp );
}

###########################################################################
# Net::SIP::Dispatcher::Packet
# Container for Queue entries in Net::SIP::Dispatchers queue
###########################################################################
package Net::SIP::Dispatcher::Packet;
use fields (
	'id',           # transaction id, used for canceling delivery if response came in
	'packet',       # the packet which nees to be delivered
	'dst_addr',     # to which adress the packet gets delivered, is array-ref because
					# the DNS/SRV lookup might return multiple addresses and protocols
	'leg',          # through which leg the packet gets delivered, same number
					# of items like dst_addr
	'retransmits',  # array of retransmit time stamps, if undef no retransmit will be
					# done, if [] no more retransmits can be done (trigger ETIMEDOUT)
					# the last element in this array will not used for retransmit, but
					# is the timestamp, when the delivery fails permanently
	'callback',     # callback for DSN (success, ETIMEDOUT...)
	'proto',        # list of possible protocols, default tcp and udp for sip:
);

use Net::SIP::Debug;
use Net::SIP::Util 'invoke_callback';

###########################################################################
# create new Dispatcher::Packet
# Args: ($class,%args)
#  %args: hash with values according to fields
#    for response packets leg and dst_addr must be set
# Returns: $self
###########################################################################
sub new {
	my ($class,%args) = @_;
	my $now = delete $args{now};

	my $self = fields::new( $class );
	%$self = %args;
	$self->{id} ||= $self->{packet}->tid;

	if ( my $addr = $self->{dst_addr} ) {
		$self->{dst_addr} = [ $addr ] if !ref($addr)
	}
	if ( my $leg = $self->{leg} ) {
		$self->{leg} = [ $leg ] if UNIVERSAL::can( $leg,'deliver' );
	}

	$self->{dst_addr} ||= [];
	$self->{leg} ||= [];

	# figure out retransmit times
	my $p = $self->{packet} || die "no packet for delivery";
	if ( $p->is_response ) {
		unless ( $self->{leg} && $self->{dst_addr} ) {
			die "Response packet needs leg and dst_addr"
		}
	}
	return $self;
}

###########################################################################
# prepare retransmit infos if dispatcher handles retransmits itself
# Args: ($self;$now)
#   $now: current time
# Returns: NONE
###########################################################################
sub prepare_retransmits {
	my Net::SIP::Dispatcher::Packet $self = shift;
	my $now = shift;
	my $p = $self->{packet};

	# RFC3261, 17.1.1.2 (final response to INVITE) -> T1=0.5, T2=4
	# RFC3261, 17.1.2.2 (non-INVITE requests)      -> T1=0.5, T2=4
	# RFC3261, 17.1.1.2 (INVITE request)           -> T1=0.5, T2=undef
	# no retransmit -> T1=undef

	my ($t1,$t2);
	if ( $p->is_response ) {
		if ( $p->code > 100 && $p->cseq =~m{\sINVITE$} ) {
			# this is a final response to an INVITE
			# this is the only type of response which gets retransmitted
			# (until I get an ACK)
			($t1,$t2) = (0.500,4);
		}
	} elsif ( $p->method eq 'INVITE' ) {
		# INVITE request
		($t1,$t2) = (0.500,undef);
	} elsif ( $p->method eq 'ACK' ) {
		# no retransmit of ACKs
	} else {
		# non-INVITE request
		($t1,$t2) = (0.500,4);
	}

	# no retransmits?
	$t1 || return;

	$now ||= time();
	my $expire = $now + 64*$t1;
	my $to = $t1;
	my $rtm = $now + $to;

	my @retransmits;
	while ( $rtm < $expire ) {
		push @retransmits, $rtm;
		$to *= 2;
		$to = $t2 if $t2 && $to>$t2;
		$rtm += $to
	}
	DEBUG( 100,"retransmits $now + ".join( " ", map { $_ - $now } @retransmits ));
	$self->{retransmits} = \@retransmits;
}



###########################################################################
# use next dst_addr (eg if previous failed)
# Args: $self
# Returns: $addr
#   $addr: new address it will use or undef if no more addresses available
###########################################################################
sub use_next_dstaddr {
	my Net::SIP::Dispatcher::Packet $self = shift;
	my $addr = $self->{dst_addr} || return;
	shift(@$addr);
	my $leg = $self->{leg} || return;
	shift(@$leg);
	return @$addr && $addr->[0];
}

###########################################################################
# trigger callback to upper layer
# Args: ($self;$errno)
#  $errno: Errno
# Returns: $callback_done
#  $callback_done: true if callback was triggered, if no callback existed
#    returns false
###########################################################################
sub trigger_callback {
	my Net::SIP::Dispatcher::Packet $self = shift;
	my $error = shift;
	my $cb = $self->{callback} || return;
	invoke_callback( $cb, $error ? ($error,$self):() );
	return 1;
}

###########################################################################
# return transaction id of packet
# Args: $self
# Returns: $tid
###########################################################################
sub tid {
	my Net::SIP::Dispatcher::Packet $self = shift;
	return $self->{packet}->tid;
}
1;
