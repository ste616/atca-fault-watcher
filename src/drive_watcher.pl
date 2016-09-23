#!/usr/bin/perl

use ATNF::DriveMon::DriveMon;
use ATNF::Twitter::Poster;
use File::HomeDir;
use ATNF::MoniCA;
use Astro::Time;

use strict;
use sigtrap qw/handler signal_handler normal-signals/;

# Initialise the Twitter connection.
my $config_file = File::HomeDir->my_home."/.twitter";
die "$config_file is missing\n" if not -e $config_file;
my $twitter = ATNF::Twitter::Poster->new(
    { 'config_file' => $config_file }
    );

# Initialise the drive monitor.
my $drivemon = ATNF::DriveMon::DriveMon->new();

# The data storage area.
my %data_storage = ( 'array' => { 'errors' => {} } );
# The tracking state of the antennas.
my %tracking_state;
# The latest MoniCA status.
my $monica_status;

my $n_antennas = 6;
for (my $i = 1; $i <= $n_antennas; $i++) {
    my $a = "ca0".$i;
    $data_storage{$a} = {
	'last_update' => 0,
	'data' => [],
	'errors' => {}
    };
    $tracking_state{$a} = 0;
}
# The number of tracking samples to keep.
my $nsamples = 1000;

# The number of updates to burn after the antennas begin tracking.
my $burn_updates = 10;

my $n_ants_online = 0;

while(1) {
    # Grab the drive data.
    my %drive_data = $drivemon->getData();

    # The current time.
    my $ctime = time();

    # Get some MoniCA data periodically.
    if (($ctime % 60) == 0) {
	$monica_status = &get_monica_data();
	# How many antennas are we dealing with?
	$n_ants_online = 0;
	for (my $i = 1; $i <= $n_antennas; $i++) {
	    if ($monica_status->{'ignore'}->{"ca0".$i} == 0) {
		$n_ants_online += 1;
	    }
	}
    }
    
    # Add this new data to the list.
    foreach my $a (keys %drive_data) {
	# Check whether we're ignoring this antenna.
	if ($monica_status->{'ignore'}->{$a} == 1) {
	    $tracking_state{$a} = 0;
	    next;
	}
	
	# Check for tracking.
	my $s = $drive_data{$a};
	if ($s->{'state'} eq "TRACKING") {
	    $tracking_state{$a} += 1;
	} else {
	    $tracking_state{$a} = 0;
	}
	
	# Only add to the data list if we've been tracking for
	# some number of updates.
	my $d = $data_storage{$a};
	if ($tracking_state{$a} > $burn_updates) {
	    push @{$d->{'data'}}, $s;
	    # Keep the list to size.
	    if ($#{$d->{'data'}} > $nsamples) {
		shift @{$d->{'data'}};
	    }
	}

	# Keep track of the last time we got data, regardless
	# of the antenna state.
	$d->{'last_update'} = $s->{'epoch'};

	# Deal with drive errors now.
	if ($s->{'state'} eq "INLIMITS" &&
	    !$d->{'errors'}->{'INLIMITS'}) {
	    # This shouldn't be possible if we're in control
	    # of the antenna, so we tweet this error out
	    # immediately.
	    $twitter->tweet("#DRIVES #MAJOR The drives on ".uc($a).
			    " are in the limits. Please contact staff.");
	    $d->{'errors'}->{'INLIMITS'} = 1;
	} elsif ($s->{'state'} ne "INLIMITS" &&
		 $d->{'errors'}->{'INLIMITS'} == 1) {
	    # The error state must have been cleared.
	    $twitter->tweet("#DRIVES The drives on ".uc($a).
			    " are no longer in the limits.");
	    delete $d->{'errors'}->{'INLIMITS'};
	}
	if ($s->{'state'} eq "DRIVE ERROR" &&
	    !$data_storage{'array'}->{'errors'}->{'PMON_STOW'} &&
	    !$d->{'errors'}->{'DRIVE_PROBLEM'}) {
	    if (!$d->{'errors'}->{'DRIVE_ERROR'}) {
		# If this is the first time we see the drive error,
		# we don't know if it is just us, or maybe all the
		# antennas. So we wait for a while.
		$d->{'errors'}->{'DRIVE_ERROR'} = 1;
	    } elsif ($d->{'errors'}->{'DRIVE_ERROR'} < 10) {
		$d->{'errors'}->{'DRIVE_ERROR'} += 1;
	    } elsif ($d->{'errors'}->{'DRIVE_ERROR'} == 10) {
		# Check the other antennas.
		my $nerrors = 1;
		for (my $j = 1; $j <= $n_antennas; $j++) {
		    my $b = "ca0".$j;
		    if ($b eq $a) {
			# This is us.
			next;
		    }
		    if ($data_storage{$b}->{'errors'}->{'DRIVE_ERROR'}) {
			$nerrors += 1;
		    }
		}
		if ($nerrors == $n_ants_online) {
		    # This is likely to be a PMON wind stow, but let's
		    # just check the most recent average wind speed.
		    if ($monica_status->{'pmon'}->{'max_speed'} > 20) {
			# It's high enough that it is definitely windy.
			$twitter->tweet("#WEATHER The array has been ".
					"wind-stowed by PMON. You will need ".
					"to contact staff to continue observing.");
			$data_storage{'array'}->{'errors'}->{'PMON_STOW'} = 1;
		    }
		} else {
		    # Looks like this drive error is just on this antenna.
		    $twitter->tweet("#DRIVES There is a drive error on ".
				    uc($a).". Please contact staff.");
		    $d->{'errors'}->{'DRIVE_PROBLEM'} = 1;
		}
	    }
	} elsif ($s->{'state'} ne "DRIVE_ERROR") {
	    # First, we delete the drive error flag.
	    delete $d->{'errors'}->{'DRIVE_ERROR'};
	    if ($data_storage{'array'}->{'errors'}->{'PMON_STOW'} == 1) {
		# The PMON wind stow has been reset probably.
		$twitter->tweet("#WEATHER The PMON wind stow has been reset.");
		delete $data_storage{'array'}->{'errors'}->{'PMON_STOW'};
	    } elsif ($data_storage{'array'}->{'errors'}->{'DRIVE_PROBLEM'} == 1) {
		# The DRIVE_ERROR has gone away.
		$twitter->tweet("#DRIVES The drive error on ".uc($a).
				" has been cleared.");
		delete $d->{'errors'}->{'DRIVE_PROBLEM'};
	    }
	}
    }
    last;
}

sub get_monica_data {
    # Get some MoniCA data for our antennas.
    my $mon = monconnect("monhost-nar");

    # The data we return.
    my $rdata = {
	'ignore' => {},
	'pmon' => {}
    };
    
    # Check for antennas that we should ignore.
    for (my $i = 1; $i <= 6; $i++) {
	my $a = "ca0".$i;
	my @points = (
	    $a.".misc.obs.caobsAntState",
	    $a.".acc.RemLoc"
	    );
	my @vals = monpoll2($mon, @points);
	my $rdata->{'ignore'}->{$a} = 0;
	for (my $j = 0; $j <= $#vals; $j++) {
	    if ($vals[$j]->point =~ /caobsAntState/ &&
		($vals[$j]->val eq "OFF-LINE" ||
		 $vals[$j]->val eq "DISABLED")) {
		$rdata->{'ignore'}->{$a} = 1;
	    } elsif ($vals[$j]->point =~ /RemLoc/ &&
		     $vals[$j]->val eq "LOCAL") {
		$rdata->{'ignore'}->{$a} = 1;
	    }
	}
    }

    # Get the max PMON wind speed.
    my $pmon = monpoll2($mon, "site.environment.weather.WindPMONMax");
    $rdata->{'pmon'}->{'max_speed'} = $pmon->val;
    
    # Close the connection.
    monclose($mon);

    return $rdata;
}
