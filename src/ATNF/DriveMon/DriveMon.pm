#!/usr/bin/perl

package TextDriveMon::TextDriveMon;

use strict;
use IO::Socket::INET;
require Exporter;
use base 'Exporter';

# TextDriveMon routine Perl library.
# Jamie Stevens 2016

# Collection of routines to enable access to the network socket-based
# drivemon server.

# Global variables.
my $latest_data_string = "";

# The routines we export.
our @EXPORT = qw(new);

sub new {
    # Make a new client for the drivemon server.
    my $class = shift;
    my $options = shift || {
	PeerAddr => 'localhost', PeerPort => 60000
    };
    
    my $self = {};
    bless $self, $class;

    # Try to connect to the server now.
    $options->{'Proto'} = 'tcp';
    $self->{'socket'} = IO::Socket::INET->new(%{$options}) or
	die "Can't bind socket: $@\n";
    
    return $self;
}

sub getData {
    my $self = shift;

    my $s = $self->{'socket'};
    # Return the latest value on the socket.
    if (defined $s) {
	$latest_data_string = <$s>;
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
	my $date = shift @els;
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
			 'azdiff' => $azdiff, 'eldiff' => $eldiff };
    }

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
