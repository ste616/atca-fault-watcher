#!/usr/bin/perl

use ATNF::DriveMon::DriveMon;
use ATNF::Twitter::Poster;
use File::HomeDir;
use ATNF::MoniCA;
use Astro::Time;
use POSIX;
use PDL::Lite;
use PDL::Core;
use PDL::Func;
use PDL::FFT;
use Data::Dumper;
use Curses;

use strict;
use sigtrap qw/handler signal_handler normal-signals/;

# The information we want to output.
my @labels = ( "AZIMUTH", "ELEVATION", "AZ ERROR", "EL ERROR" );

# Initialise the Twitter connection.
my $config_file = File::HomeDir->my_home."/.twitter";
die "$config_file is missing\n" if not -e $config_file;
my $twitter = ATNF::Twitter::Poster->new(
    { 'config_file' => $config_file }
    );

# Initialise the drive monitor.
my $drivemon = ATNF::DriveMon::DriveMon->new();

# Prepare the screen.
my $win = new Curses;
my $wincoords = &splitwindow(6, $win);
if (!$wincoords) {
    endwin;
    die "Window is too small, please make it larger!\n";
}
&output_headers($wincoords, $win);

# The data storage area.
my %data_storage = ( 'array' => { 'errors' => {} },
		     'last_update' => 0 );
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
my $is_connected = 0;

while(1) {
    # Grab the drive data.
    my %drive_data = $drivemon->getData();
    if (!$drivemon->isConnected()) {
	# After a read, we can tell if we aren't connected, and if so
	# we issue an error.
	if ($is_connected) {
	    # This means we've lost the connection, which is worse
	    # than if we never connected at all.
#	    warn "Connection lost!\n";
	    $is_connected = 0;
	} else {
	    # We're still waiting on a connection.
	    sleep 1;
	    eval {
		$drivemon = ATNF::DriveMon::DriveMon->new();
	    };
	    next;
	}
    } elsif ($is_connected == 0) {
#	print "Connection established!\n";
	$is_connected = 1;
    }
    
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
    my $cr_needed = 0;
    foreach my $a (keys %drive_data) {
	# Check whether we're ignoring this antenna, or if it
	# isn't actually an antenna.
	if ($a !~ /^ca/) {
	    next;
	}
	if ($monica_status->{'ignore'}->{$a} == 1) {
	    $tracking_state{$a} = 0;
	    next;
	}
	my $antnum = -1;
	if ($a =~ /^ca0(.)$/) {
	    $antnum = $1;
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
	if ($s->{'epoch'} > $data_storage{'last_update'}) {
	    $data_storage{'last_update'} = $s->{'epoch'};
	}

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

	# Compute the statistics periodically.
	if (($ctime % 10) == 0) {
	    # Arrange the samples into bins of 1 minute.
	    &index_array($d->{'data'}, $ctime, 60);
	    
	    my @drive_stats = &produce_statistics($d->{'data'});
	    if ($#drive_stats >= 0) {
	    
#		print "\n\nTime is ".strftime("%Y-%m-%d %H:%M:%S", gmtime($ctime))."\n";
		my $ds = $drive_stats[$#drive_stats]->{'statistics'};
		
#		print "$a\n";
#		print Dumper $ds;
		if ($ds->{'azdeg'}->{'n'} > 0) {
#		    print "For the past minute, while tracking:\n";
#		    printf ("  average az / el = %.3f, %.3f\n",
#			    $ds->{'azdeg'}->{'average'}, $ds->{'eldeg'}->{'average'});
		    #		    printf ("  average epoch = %.3f\n", $ds->{'htrepoch'}->{'average'});
		    my $xleft = $wincoords->{'panels'}->[$antnum]->[0];
		    my $ytop = $wincoords->{'panels'}->[$antnum]->[1] + 1;
		    my $os = sprintf("%+7.3f\" / %+7.3f\"", 
				     $ds->{'azdeg'}->{'average'},
				     $ds->{'azdeg'}->{'median'});
		    $win->addstr($ytop + 1, $xleft, $os);
		    $win->refresh;
		} else {
#		    print "There has been no tracking within the last minute.\n";
		}
	    }
	} else {
	    $cr_needed = 0;
	}
    }

    # Check for stale data.
    my $updatediff = abs($data_storage{'last_update'} - $ctime);
#    if ($updatediff > 60) {
	# We haven't received an update in over 60 seconds.
#	print "No updates!\n";
#    }
    
#    if ($cr_needed == 1) {
#	print "\n";
#    }
}

sub signal_handler {
    endwin;

    $drivemon->close();

    exit;
}

sub produce_statistics {
    my $aref = shift;

    my @stats_params = (
	'htrepoch', 'azdeg', 'eldeg', 'azerr', 'elerr',
#	'azrate', 'elrate', 'azavg', 'elavg', 'azdiff', 'eldiff'
	);
    
    my @stats_list;
    my @tmp;
    my $ci = -1;
    for (my $i = 0; $i <= $#{$aref}; $i++) {
	if ($ci == -1) {
	    $ci = $aref->[$i]->{'pindex'};
	}
	if ($ci == $aref->[$i]->{'pindex'}) {
	    push @tmp, $aref->[$i];
	}
	if ($ci != $aref->[$i]->{'pindex'} ||
	    $i == $#{$aref}) {

	    # Do the statistics.
	    my $sref = {
		'period' => $ci, 'statistics' => {}
	    };
	    for (my $j = 0; $j <= $#stats_params; $j++) {
		my $vref = &compute_statistics(\@tmp, $stats_params[$j]);
		$sref->{'statistics'}->{$stats_params[$j]} = $vref;
	    }
	    push @stats_list, $sref;
	    
	    # Reset the holding areas.
	    if ($i < $#{$aref}) {
		$i--;
	    }
	    $ci = -1;
	    @tmp = ();
	}
    }

    return @stats_list;
}

sub compute_statistics {
    my $aref = shift;
    my $pname = shift;

#    print "++++ $pname\n";
    # The total.
    my $t = 0;
    # The number of accepted elements.
    my $n = 0;
    # The minimum value.
    my $mnv = $aref->[0]->{$pname};
    # The maximum value.
    my $mxv = $aref->[0]->{$pname};

    # Loop 1, get the average, min and max,
    # and make an array for the FFT.
    my $fft_timeres = 0.5; # in seconds.
    my @prepx;
    my @prepy;
    for (my $i = 0; $i <= $#{$aref}; $i++) {
	push @prepx, $aref->[$i]->{'htrepoch'};
	push @prepy, $aref->[$i]->{$pname};
	$t += $aref->[$i]->{$pname};
	$n += 1;
	$mnv = ($aref->[$i]->{$pname} < $mnv) ?
	    $aref->[$i]->{$pname} : $mnv;
	$mxv = ($aref->[$i]->{$pname} > $mxv) ?
	    $aref->[$i]->{$pname} : $mxv;
    }
    my $avg = 0;
    if ($n > 0) {
	$avg = $t / $n;
    }

    # Loop 2, using the earliest time as a benchmark,
    # make an array of interpolated values on the time
    # grid.
    my $t0 = $prepx[0];
    my $tl = $prepx[$#prepx];
    my $ct = $t0;
    my @fftv;
    my $interp = PDL::Func->init( x => \@prepx, y => \@prepy );
    while ($ct < $tl) {
	push @fftv, sclr $interp->interpolate($ct);
	$ct += $fft_timeres;
    }
    # Remove the last value if we end up with an odd number of
    # samples.
    if (($#fftv % 2) == 0) {
	# The way Perl lengths work, this is an odd number.
	pop @fftv;
    }

    # Loop 3, get the standard deviation.
    my $dt = 0;
    my $dn = 0;
    for (my $i = 0; $i <= $#{$aref}; $i++) {
	$dt += ($aref->[$i]->{$pname} - $avg)**2;
	$dn += 1;
    }
    my $stdev = 0;
    if ($dn > 0) {
	$stdev = sqrt($dt / $dn);
    }

    # Now do the FFT.
#    print "[".join(" , ", @fftv)."]\n";
    my @u_fftv;
    my @comps;
    if ($#fftv >= 3) {
	my $p_fftv = pdl @fftv;
	realfft($p_fftv);
	# Transform the FFT result into a list of powers and frequencies.
	@u_fftv = list $p_fftv;
	# The frequency spacing of the FFT power spectrum.
	my $l = $#u_fftv + 1;
	my $hl = $l / 2;
	my $deltaf = (1 / $fft_timeres) / $l;
	# The first element is given as the zero-frequency, but
	# the zero frequency is not listed as an imaginary component, so
	# we just shift that off the front.
	push @comps, [ 20 * &log10((shift @u_fftv) / $l), 0 ];
	# There are now going to be half the number of components left
	# as were samples going in, minus 1. For example, if we had
	# 16 samples, the FFT will have the zero frequency plus 7
	# more frequency outputs.
	my @acomps;
	for (my $i = 0; $i < $hl; $i++) {
	    # We. turn the output into decibels.
	    my $amp = 20 * &log10(sqrt($u_fftv[$i]**2 +
				       $u_fftv[$hl + $i]**2) / $l);
	    push @comps, [ $amp, ($i + 1) * $deltaf ];
	    push @acomps, $amp;
	}
	# Get the median value of this array, excluding the zero-freq
	# term.
	my $medcomp = &median_offset(\@acomps);
	# We make the median strength the reference, and call it 0 dB.
	# We thus scale everything with respect to this.
	for (my $i = 0; $i <= $#comps; $i++) {
	    $comps[$i]->[0] -= $medcomp;
	}
    }

    # Sort the frequency component array based on the component strength, with
    # strongest components first.
    my @scomps = sort { $b->[0] <=> $a->[0] } @comps;
    
    # Get the median value.
    my $median = &median_offset(\@prepy);
    
    # Return all our results.
    return {
	'n' => ($#fftv + 1), 'average' => $avg, 'min' => $mnv, 'max' => $mxv,
	'samples' => \@u_fftv, 'fft' => \@comps, 'median' => $median, 
	'stdev' => $stdev };
}

sub median_offset {
    # Take the median of an array, with an optional number of
    # elements discarded from the front of the array.
    my $aref = shift;
    my $ndis = shift || 0;

    my @parr = @{$aref};
    while ($ndis > 0) {
	shift @parr;
	$ndis -= 1;
    }
    my @sparr = sort { $a <=> $b } @parr;

    my $ml = $#sparr + 1;
    my $median = 0;
    if (($ml % 2) == 0 && $ml > 0) {
	my $mi = ($ml - 1) / 2;
	$median = ($sparr[$mi - 0.5] + $sparr[$mi + 0.5]) / 2;
    } else {
	my $mi = ($ml + 1) / 2;
	$median = $sparr[$mi];
    }
    return $median;
}

sub log10 {
    my $n = shift;

    if ($n > 0) {
	return log($n) / log(10);
    } else {
	return -60;
    }
}
    
sub index_array {
    # Based on the time of the sample, give each sample an index,
    # with 0 being in the "current" period, and the index increasing
    # with earlier periods.
    my $aref = shift;
    my $ctime = shift; # The current time.
    my $ptime = shift; # The length of a period in seconds.
    
    for (my $i = 0; $i <= $#{$aref}; $i++) {
	$aref->[$i]->{'pindex'} = floor(abs($ctime - $aref->[$i]->{'epoch'}) /
					$ptime);
    }
}

sub average_parameter {
    # Take the average of an array of hashes, of a named
    # key.
    my $aref = shift;
    my $keyname = shift;

    my $t = 0;
    my $n = 0;
    for (my $i = 0; $i <= $#{$aref}; $i++) {
	if (defined $aref->[$i]->{$keyname}) {
	    $t += $aref->[$i]->{$keyname};
	    $n += 1;
	}
    }
    my $a = 0;
    if ($n > 0) {
	$a = $t / $n;
    }
    return { 'average' => $a, 'num' => $n };
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

sub output_headers {
    # Output the stuff on the screen that doesn't change.
    my $coord_ref = shift;
    my $pwin = shift;

    for (my $i = 0; $i <= $#{$coord_ref->{'panels'}}; $i++) {
	if ($i == 0) {
	    # Output the labels.
	    for (my $j = 0; $j <= $#labels; $j++) {
		$pwin->addstr($coord_ref->{'panels'}->[$i]->[1] + 1 + ($j * 5), 
			      $coord_ref->{'panels'}->[$i]->[0], $labels[$j]);
		$pwin->addstr($coord_ref->{'panels'}->[$i]->[1] + 2 + ($j * 5), 
			      $coord_ref->{'panels'}->[$i]->[0], "avg / med");
		$pwin->addstr($coord_ref->{'panels'}->[$i]->[1] + 3 + ($j * 5), 
			      $coord_ref->{'panels'}->[$i]->[0], "min / max");
		$pwin->addstr($coord_ref->{'panels'}->[$i]->[1] + 4 + ($j * 5), 
			      $coord_ref->{'panels'}->[$i]->[0], "N / stdev");
		$pwin->addstr($coord_ref->{'panels'}->[$i]->[1] + 5 + ($j * 5), 
			      $coord_ref->{'panels'}->[$i]->[0], "sine freq");
	    }
	} else {
	    # Output the antenna name.
	    $pwin->addstr($coord_ref->{'panels'}->[$i]->[1], 
			  $coord_ref->{'panels'}->[$i]->[0], "CA0".$i);
	}
    }
    $pwin->refresh;
}

sub splitwindow {
    # Determine the coordinates for each panel.
    my $npanels = shift;
    my $pwin = shift;

    # The minimum width for each panel.
    my $min_panel_width = 20;
    # And the maximum required width for each panel.
    my $max_panel_width = 20;
    
    my %coords;
    # Get the current size of the window.
    my ($yheight, $xwidth);
    $pwin->getmaxyx($yheight, $xwidth);

    if ((($npanels + 1) * $min_panel_width) > $xwidth) {
	return undef;
    }
    
    my $panel_width = $xwidth / ($npanels + 1);
    if ($panel_width < $min_panel_width) {
	$panel_width = $min_panel_width;
    }
    if ($panel_width > $max_panel_width) {
	$panel_width = $max_panel_width;
    }
    
    $coords{'panel_width'} = $panel_width;
    # The required number of lines.
    my $req_lines = ($#labels + 1) * 5 + 1;

    $coords{'panels'} = [];
    # Output the positions of the panels.
    for (my $i = 0; $i <= $npanels; $i++) {
	push @{$coords{'panels'}}, [ $i * $panel_width, $yheight - $req_lines ];
    }
    
    return \%coords;
}
