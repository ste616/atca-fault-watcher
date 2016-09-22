#!/usr/bin/perl

use TextDriveMon::TextDriveMon;
use Curses;
use Astro::Time;
use strict;

# The information we want to output.
my @labels = ( "STATE", "AZIMUTH", "ELEVATION", "AZ ERROR", "EL ERROR" );

my $win = new Curses;
my $wincoords = &splitwindow(6, $win);
if (!$wincoords) {
    endwin;
    die "Window is too small, please make it larger.\n";
}
&output_headers($wincoords, $win);

# Open a socket to the data.
my $drivemon = TextDriveMon::TextDriveMon->new();

while(1) {
    # Grab the data from the socket.
    my %pdata = $drivemon->getData();
    # Output it to screen.
    &data_to_screen(\%pdata, $wincoords, $win);
}

endwin;

sub data_to_screen {
    # Take the parsed data and output it on screen.
    my $dref = shift;
    my $cref = shift;
    my $pwin = shift;

    # Go through the data reference.
    my $pwidth = $cref->{'panel_width'};
    my $fwidth = $pwidth - 1;
    foreach my $a (keys %{$dref}) {
	my $antnum = -1;
	if ($a =~ /^ca0(.)$/) {
	    $antnum = $1;
	}
	if ($antnum > 0) {
	    my $xleft = $cref->{'panels'}->[$antnum]->[0];
	    my $ytop = $cref->{'panels'}->[$antnum]->[1] + 1;
	    for (my $i = 0; $i <= $#labels; $i++) {
		my $ostring = "";
		my $degoffset = -1;
		if ($labels[$i] eq "STATE") {
		    $ostring = sprintf "%-".$pwidth."s", $dref->{$a}->{'state'};
		} elsif ($labels[$i] eq "AZIMUTH") {
		    my $posref = &degrees_to_string_position($dref->{$a}->{'azdeg'});
		    $ostring = sprintf "%-".$pwidth."s", $posref->{'raw'};
#		    $degoffset = $posref->{'offset'};
		} elsif ($labels[$i] eq "ELEVATION") {
		    my $posref = &degrees_to_string_position($dref->{$a}->{'eldeg'});
		    $ostring = sprintf "%-".$pwidth."s", $posref->{'raw'};
#		    $degoffset = $posref->{'offset'};
		} elsif ($labels[$i] eq "AZ ERROR") {
		    my $errs = &arcseconds_to_string_error($dref->{$a}->{'azerr'});
		    $ostring = sprintf "%-".$pwidth."s", $errs;
		} elsif ($labels[$i] eq "EL ERROR") {
		    my $errs = &arcseconds_to_string_error($dref->{$a}->{'elerr'});
		    $ostring = sprintf "%-".$pwidth."s", $errs;
		}
		$pwin->addstr($ytop + $i, $xleft, $ostring);
		if ($degoffset >= 0) {
		    $pwin->attr_on(A_ALTCHARSET);
		    $pwin->addch($ytop + $i, $xleft + $degoffset, 128);
		    $pwin->attr_off(A_ALTCHARSET);
		}
	    }
	}
    }
    $pwin->refresh;
}

sub arcseconds_to_string_error {
    # Take the error in arcseconds and output the string to display.
    my $acs = shift;

    my $astring = "";
    if ($acs < 60) {
	# Output in arcseconds.
	$astring = sprintf("%+.2f\"", $acs);
    } elsif ($acs < 3600) {
	# Output in arcmins/arcsec.
	my $adeg = $acs / 3600;
	my $tstring = deg2str($adeg, 'D', 1, 'deg');
	$tstring =~ s/^.*d(.*)$/$1/;
	$astring = $tstring;
    } else {
	# Output in dms.
	my $adeg = $acs / 3600;
	$astring = deg2str($adeg, 'D', 0, 'deg');
	$astring =~ s/d/\^/;
    }
    return $astring;
}

sub degrees_to_string_position {
    # Take the position in degrees and output the string to display.
    my $deg = shift;

    my $dstring = deg2str($deg, 'D', 0, 'deg');
    # Calculate the offset of the 'd' character.
    my $offs = index($dstring, 'd');
    $dstring =~ s/d/\^/;

    return { 'raw' => $dstring, 'offset' => $offs };
}


sub output_headers {
    # Output the stuff on the screen that doesn't change.
    my $coord_ref = shift;
    my $pwin = shift;

    for (my $i = 0; $i <= $#{$coord_ref->{'panels'}}; $i++) {
	if ($i == 0) {
	    # Output the labels.
	    for (my $j = 0; $j <= $#labels; $j++) {
		$pwin->addstr($coord_ref->{'panels'}->[$i]->[1] + 1 + $j, 
			      $coord_ref->{'panels'}->[$i]->[0], $labels[$j]);
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
    my $min_panel_width = 12;
    # And the maximum required width for each panel.
    my $max_panel_width = 14;
    
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
    my $req_lines = $#labels + 2;

    $coords{'panels'} = [];
    # Output the positions of the panels.
    for (my $i = 0; $i <= $npanels; $i++) {
	push @{$coords{'panels'}}, [ $i * $panel_width, $yheight - $req_lines ];
    }
    
    return \%coords;
}
