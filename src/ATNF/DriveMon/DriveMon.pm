#!/usr/bin/perl

package ATNF::DriveMon::DriveMon;

use strict;
use Astro::Time;
use IO::Socket::INET;
require Exporter;
use base 'Exporter';

# DriveMon routine Perl library.
# Jamie Stevens 2016

# Collection of routines to enable access to the network socket-based
# drivemon server.

# Global variables.
my $latest_data_string = "";

# The routines we export.
our @EXPORT = qw(new);

sub new {
    # Make a new client for the drivemon server.
    # Fun fact: the md5sum of the string "textdrivemon" is
    # 52b6507d57a7ebbcfc140c6e5b7070ff, which in decimal is
    # 109943326206033246331789025388467876095. The "private"
    # TCP port range starts at 49152 and goes through to 65535.
    # The first valid port appearing in that decimal number then
    # is 62060, and that's what we use :)
    my $class = shift;
    my $options = shift || {
	PeerAddr => 'localhost', PeerPort => 62060,
	Timeout => 1
    };
    
    my $self = { 'socket' => -1 };
    bless $self, $class;

    # Try to connect to the server now.
    $options->{'Proto'} = 'tcp';
    $self->{'socket'} = IO::Socket::INET->new(%{$options}) or
	die "Can't bind socket: $@\n";
    
    return $self;
}

sub isConnected {
    my $self = shift;

    if ($self->{'socket'} != -1) {
	return 1;
    } else {
	return 0;
    }
}

sub close {
    my $self = shift;

    $self->{'socket'}->shutdown(2);

    return 0;
}

sub getData {
    my $self = shift;

    my $s = $self->{'socket'};
    # Return the latest value on the socket.
    if ($s != -1) {
	my $ts = "";
	my $rb = $s->sysread($ts, 1);
	if ($rb == 0) {
	    # We've just received end of file.
	    $self->{'socket'} = -1;
	    $latest_data_string = "";
	} else {
	    # Data is still coming.
	    #$s->ungetc($ts);
	    my $lds = <$s>;
	    $latest_data_string = $ts.$lds;
	}
#	print "==debug $latest_data_string ($rb)\n";
    }
    
    return $self->parseData();
}

sub parseData {
    # Take a string from the network and parse it into usable form.
    my $self = shift;
    my $data = $latest_data_string;

    my %odata;
    my @els = split(/\t/, $data);
    while ($#els >= 0) {
	my $ant = shift @els;
	if ($ant !~ /^ca/) {
	    next;
	}
	my $date = shift @els;
	# Convert the date into the epoch.
	my $epoch = 0;
	my $hepoch = 0;
	if ($date =~ /^(....)\-(..)\-(..)\s(..)\:(..)\:(.*)$/) {
	    my ($year, $month, $date, $hour, $minute, $second) =
		($1, $2, $3, $4, $5, $6);
	    my $ut = hms2time($hour, $minute, $second);
	    my $mjd = cal2mjd($date, $month, $year, $ut);
	    $epoch = mjd2epoch($mjd);
	    $hepoch = $epoch - int($second + 0.5) + $second;
	}
	my $state = $self->antState(shift @els);
	my $azdeg = shift @els;
	my $eldeg = shift @els;
	my $azerr = shift @els;
	my $elerr = shift @els;
	my $azrate = shift @els;
	my $elrate = shift @els;
	my $azavg = shift @els;
	my $elavg = shift @els;
	my $azdiff = shift @els;
	my $eldiff = shift @els;
	$odata{$ant} = { 'date' => $date, 'state' => $state,
			 'azdeg' => $azdeg, 'eldeg' => $eldeg,
			 'azerr' => $azerr, 'elerr' => $elerr,
			 'azrate' => $azrate, 'elrate' => $elrate,
			 'azavg' => $azavg, 'elavg' => $elavg,
			 'azdiff' => $azdiff, 'eldiff' => $eldiff,
			 'epoch' => $epoch, 'htrepoch' => $hepoch };
    }
    $latest_data_string = "";

    return %odata;
}

sub antState {
    # Take a numeric antenna state and return the corresponding string.
    my $self = shift;
    my $nstate = shift;

    if ($nstate == 1) {
	return "UNKNOWN";
    } elsif ($nstate == 2) {
	return "STOWED";
    } elsif ($nstate == 3) {
	return "STOWING";
    } elsif ($nstate == 4) {
	return "UNSTOWING";
    } elsif ($nstate == 5) {
	return "STOW ERROR";
    } elsif ($nstate == 6) {
	return "PARKED";
    } elsif ($nstate == 7) {
	return "PARKING";
    } elsif ($nstate == 8) {
	return "STOPPING";
    } elsif ($nstate == 9) {
	return "IDLE";
    } elsif ($nstate == 10) {
	return "GOTO";
    } elsif ($nstate == 11) {
	return "SLEWING";
    } elsif ($nstate == 12) {
	return "TRACKING";
    } elsif ($nstate == 13) {
	return "INLIMITS";
    } elsif ($nstate == 14) {
	return "DRIVE ERROR";
    } elsif ($nstate == 15) {
	return "RESETTING";
    } else {
	return "UNSTATED";
    }
}
