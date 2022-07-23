#!/usr/bin/env perl

package StormSurgeLive::Nowify;

use strict;
use warnings;
use StormSurgeLive::RSS qw//;
use Date::Parse qw//;
use File::Copy qw//;
use File::Path qw//;
use POSIX::strptime qw//;
use POSIX qw//;
use Util::H2O::More qw/h2o o2h opt2h2o/;

sub ddd {
    require Data::Dumper;
    print Data::Dumper::Dumper(@_);
}

sub dddie {
    require Data::Dumper;
    print Data::Dumper::Dumper(@_);
    exit;
}

sub new {
    my $pkg  = shift;
    my %opts = @_;
    my $self = bless { DEBUG => $opts{DEBUG} }, $pkg;
    return $self;
}

sub nowify {
    my ( $self, $o ) = @_;
    h2o $o, qw/advStart advEnd fstBasin btkBasin frequency newDir newStart newStorm newName oldDir oldStorm oldYear/;

    my $old_dir = $o->oldDir;    # req

    if ( not $old_dir or not -d $old_dir ) {
        die qq{--oldDir is not defined or doesn't exist\n};
    }

    # A	N A L Y S E  S T O R M  D A T A
    my $ADV          = {};
    my $adv_max      = 0;
    my $adv_min      = 1_000_000;
    my $adv_checksum = 0;           # used at end to verify consecutive ADVs are provided
    opendir my $dh, $old_dir || die "Can't open $old_dir: $!";
  LIST:
    foreach my $file ( readdir $dh ) {
        my @filepart = split /\./, $file;
        my $type     = $filepart[-1];
        my $adv      = $filepart[0];

        # filter for only .dat and .xml, $adv ($filepart[0]) must be a number
        next LIST if not @filepart or not $type or not grep { $_ =~ m/$type/ } (qw/dat xml/) or not $adv or $adv =~ m/^[^0-9]/;
        $ADV->{$adv}->{$type} = sprintf qq{%s/%s}, $old_dir, $file;
        $adv_max              = $adv if ( $adv > $adv_max );
        $adv_min              = $adv if ( $adv < $adv_min );

        # capture storm basin, storm number, year from .dat file name
        if ( $type eq q{dat} ) {
            $adv_checksum += $adv;

            my ( $basin, $storm, $year ) = ( $filepart[1] =~ m/([a-z]{3})([\d]{2})([\d]{4})/g );    # e.g., bal072009
            $ADV->{$adv}->{basin} = $basin;
            $ADV->{$adv}->{storm} = $storm;
            $ADV->{$adv}->{year}  = $year;

            # assigned multiple times; may need to add year/storm inconsistencies
            $o->oldYear($year);
            $o->oldStorm($storm);
        }
    }
    closedir $dh;

    # Make sure the range of advisory numbers fit the following criteria:
    # * start with 1
    # * are consecutive
    # * max advisory (last) corresponds with number of advisories (count)
    # * compare accumlated sum of advisory numbers with explicitly computed
    #   \ based on the above critera
    my $adv_count      = ( keys %$ADV );
    my $computed_check = ( $adv_max / 2 ) * ( 1 + $adv_max );
    if ( $adv_checksum != $computed_check or $adv_min != 1 or $adv_max != $adv_count ) {
        die q{Advisory numbers are not consecutive!\n};
    }

    # new directory to dump nowified data is required
    my $new_dir = $o->newDir;    # req
    die qq{--newDir is not defined. This is required to save nowified data.\n} if not $new_dir;

    # check outcome of date regex, which defines the starting initial date
    $o->{'newStart'} =~ m/^(\d\d\d\d)(\d\d)(\d\d)(\d\d)?$/;    # req
    if ( not $1 or not $2 or not $3 ) {
        die qq{--newStart is not in the correct format: "YYYYMMDD" (same as what's in the best track file).\n};
    }

    # $start_hour defaults to hour in advisory 1 of old storm if not set
    my ( $start_year, $start_mon, $start_day, $start_hour ) = ( $1, $2, $3, $4 // undef );

    # make destination directory if it doesn't exist
    if ( not -d $new_dir ) {
        File::Path::make_path($new_dir);
    }

    my $frequency_sec = $o->frequency // 6 * 3600;        # not req, defaults to 6*3600 seconds (6 hours)
    my $new_storm     = $o->newStorm  // $o->oldStorm;    # not req, defaults to old storm number
    my $old_storm     = $o->oldStorm;

    my $fst_basin = $o->fstBasin // q{at};                # because NHC is inconsistent about how
    $o->fstBasin($fst_basin);                             # $o used in subroutine

    my $btk_basin = $o->btkBasin // q{al};                # they designate ocean basins xD
    $o->btkBasin($btk_basin);                             # $o used in subroutine

    my ( $new_sec, $new_min, $new_hour, $new_day, $new_mon, $new_year, $new_wday, $new_yday, $new_isdst ) = gmtime(time);

    # Pass 1 - generate mapping of dates/times from RSS (old -> new)
    my $rss_date_map   = {};
    my $adv_to_pubdate = {};                              # RSS pubdate for advisory X
    my ( $ss, $mm, $wday, $yday, $isdst );                # not used but needed for localtime capture
                                                          # iterate over all advisories (guaranteed to be consecutive from $adv_min .. $adv_max
                                                          # if we've gotten this far, based on the initial check above
    my @pubdate = ();
  RSSPASS:

    foreach my $adv ( sort { $a <=> $b } keys %$ADV ) {
        my $rss_xml = $ADV->{$adv}->{xml};

        # open up the source index-at.xml file; assume there is
        # only one RSS item, the storm we're interested in
        my $src_rss = XML::RSS->new;
        $src_rss->parsefile($rss_xml);
        my $pub_date = $src_rss->{channel}->{pubDate};

        # record pubdate based on $adv
        $adv_to_pubdate->{$adv} = $pub_date;

        #($sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst)
        my @old_pubdate = POSIX::strptime( $pub_date, qq{%a, %d %b %Y %H:%M:%S %Z} );
        pop @old_pubdate;    # get rid of $isdst

        if ( not @pubdate ) {
            push @pubdate, @old_pubdate;    # use first old pubdate as reference point for new data + frequency
        }
        else {
            $pubdate[0] += $frequency_sec;
        }

        $pubdate[5] = $new_year;
        $pubdate[4] = $new_mon;
        $pubdate[3] = $new_day - 1;
        $pubdate[2] = $new_hour;

        # used below for converting the pubdate in the RSS
        $rss_date_map->{$pub_date} = {
            new_sec  => $pubdate[0],
            new_hour => $pubdate[2],
            new_day  => $pubdate[3],
            new_mon  => $pubdate[4],
            new_year => $pubdate[5],
            old_sec  => $old_pubdate[0],
            old_hour => $old_pubdate[2],
            old_day  => $old_pubdate[3],
            old_mon  => $old_pubdate[4],
            old_year => $old_pubdate[5]
        };
    }

    # jump right the the last best track file to look at all of
    # the records, we will update each .dat file in a subsequent
    # loop
    my $btk_file = $ADV->{$adv_max}->{dat};
    open my $BTK_FH, q{<}, $btk_file;
    my $btk_content = do { local $/; <$BTK_FH> };
    close $BTK_FH;

    # read in all btk records
    my $btk_dt_lines = {};
    foreach my $dat_line ( split /\n/, $btk_content ) {
        chomp $dat_line;
        my ( $BASIN, $STORM, $datetime, $KIND, @cruft ) = split /, */, $dat_line;

        # store all lines with this date time
        push @{ $btk_dt_lines->{$datetime} }, $dat_line;
    }

    # generate mapping of btk datetime to current
    my $btk_date_map = {};
    my ( $btk_first_datetime, $btk_sec, $btk_min, $btk_hour, $btk_mday, $btk_mon, $year, $btk_wday, $btk_yday );
    my $inc_sec = 0;    # used to increment from the starting date
    foreach my $date ( sort keys %$btk_dt_lines ) {
        my $btk_new_datetime;
        if ( not $btk_first_datetime ) {
            $btk_first_datetime = ( sort keys %$btk_dt_lines )[0];
            ( $btk_sec, $btk_min, $btk_hour, $btk_mday, $btk_mon, $year, $btk_wday, $btk_yday ) = POSIX::strptime( $btk_first_datetime, q{%Y%m%d%h} );
            $btk_date_map->{$date} = POSIX::strftime( qq{%Y%m%d%H}, $new_sec, $new_min, $new_hour, $new_day, $new_mon, $new_year );
        }
        else {
            $inc_sec += $frequency_sec;
            $btk_date_map->{$date} = POSIX::strftime( qq{%Y%m%d%H}, $inc_sec, $new_min, $new_hour, $new_day, $new_mon, $new_year );
        }
    }

  UPDATERSS:
    foreach my $adv ( sort { $a <=> $b } keys %$ADV ) {
        my $rss_xml_full = $ADV->{$adv}->{xml};
        my $old_pub_date = $adv_to_pubdate->{$adv};
        $self->_update_rss( $rss_xml_full, $rss_date_map, $adv, $o );
    }

  UPDATEBEST:
    foreach my $adv ( sort { $a <=> $b } keys %$ADV ) {
        my $btk_file = $ADV->{$adv}->{dat};
        open my $BTK_FH, q{<}, $btk_file;
        my $btk_content = do { local $/; <$BTK_FH> };
        close $BTK_FH;

        # update dat records using search and replace, remaining
        # mindful that the .dat records are fixed width format;
        # Currently only replaces:
        # * datetime stamp (column 3)
        # * storm number   (column 2)
        foreach my $old ( sort keys %$btk_date_map ) {
            my $new = $btk_date_map->{$old};
            $btk_content =~ s/$old/$new/gm;
        }

        # update storm number
        my $basin_UC = uc $btk_basin;
	my $zero_padded_new_storm = sprintf qq{%02d}, $new_storm;
        $btk_content =~ s/$basin_UC, $old_storm/$basin_UC, $zero_padded_new_storm/gm;

        my $new_btk_file = sprintf( "%s/%02d.b%s%02d%04d.dat", $new_dir, $adv, $btk_basin, $new_storm, $new_year + 1900 );
        open my $fh, q{>}, $new_btk_file;
        print $fh $btk_content;
        close $fh;
        print qq{Wrote nowified Best Track: "$new_btk_file"\n} if $self->{DEBUG};
    }

    return 1;
}

# Creates standard W3CDTF time stamp for use as RSS pubDate
sub _newdate_as_pubtime {
    my ( $self, $new_time ) = @_;

    # Sun, 18 Sep 2005 03:00:00 GMT
    #  %a, %d  %b   %Y %H:00:00 GMT
    my $W3CDTF = POSIX::strftime( qq{%a, %d %b %Y %H:00:00 GMT}, $new_time->{new_sec}, 0, $new_time->{new_hour}, $new_time->{new_day}, $new_time->{new_mon}, $new_time->{new_year} );
    return $W3CDTF;
}

# update all dates in RSS fields and in the NHC forecast using the date map
sub _update_rss {
    my ( $self, $orig_rss_file, $rss_date_map, $adv, $o ) = @_;

    my $old_storm      = $o->oldStorm;
    my $old_year       = $o->oldYear;
    my $new_dir        = $o->newDir;
    my $fst_basin      = $o->fstBasin;
    my $new_storm      = $o->newStorm // $o->oldStorm;
    my $new_storm_name = $o->newName;

    # open up the source index-at.xml file
    my $src_rss = XML::RSS->new;
    $src_rss->parsefile($orig_rss_file);
    my $channel_pub_date = $src_rss->{channel}->{pubDate};
    my $item_pub_date    = $src_rss->{items}->[0]->{pubDate};
    my $description      = $src_rss->{items}->[0]->{description};

    # update pubTime using W3CDTF format (standard for RSS fields)
    my $date_map    = $rss_date_map->{$item_pub_date};
    my $new_pubdate = $self->_newdate_as_pubtime($date_map); # this seems OK

    # update RSS fields for pubDate directly
    $src_rss->{channel}->{pubDate} = $new_pubdate;
    $src_rss->{items}->[0]->{pubDate} = $new_pubdate;

    # extract title of old storm and determine the storms name (and if it is a name or a number)
    my $old_full_title = $src_rss->{items}->[0]->{title};
    $old_full_title =~ m/^(.+) Forecast/;
    my $old_storm_title = $1;
    $old_storm_title =~ m/ ([^ ]+)$/;
    my $old_storm_name = $1;

    # if old storm name is still a NUMBER WORD, replace the old NUMBER WORD
    # with the new NUMBER WORD associated with $new_storm

    # if not set above (--new-name is optional), default to $old_storm_name
    $new_storm_name //= $old_storm_name;

    # if $old_storm_name is a number, use NUMBER WORD form of $new_storm, which
    # will be $old_storm if --new-storm is not specified
    # NOTE: a storm designated "INVEST" is not considered to have a NUMBER WORD name
    if ( $self->_storm_name_is_a_number($old_storm_name) ) {
        $new_storm_name = $self->_storm_number_to_word($new_storm);
    }

    # update <title></title> with new name/NUMBER WORD
    $src_rss->{items}->[0]->{title} =~ s/$old_storm_name/$new_storm_name/;

    # update <description></description>, which has an UPPER CASE
    # version of the $old_storm_title
    $old_storm_title = uc $old_storm_title;
    my $new_storm_title = $old_storm_title;
    $new_storm_title =~ s/$old_storm_name/$new_storm_name/;
    $description     =~ s/$old_storm_title/$new_storm_title/g;

    # determine new storm designation
    my $new_storm_id = sprintf( "AL%02d%s", $new_storm, $date_map->{new_year} + 1900 );
    my $old_storm_id = sprintf( "AL%02d%s", $old_storm, $old_year );

    # e.g., "NWS TPC/NATIONAL HURRICANE CENTER MIAMI FL   AL182005"
    $description =~ s/$old_storm_id/$new_storm_id/g;

    # Line 6 of description, e.g.,
    #  *  0300Z SUN SEP 18 2005
    #  *  1500 UTC MON AUG 25 2008
    my $new_line6 = uc POSIX::strftime( qq{%H00 UTC %a %b %d %Y}, $date_map->{new_sec}, 0, $date_map->{new_hour}, $date_map->{new_day}, $date_map->{new_mon}, $date_map->{new_year} );

    print qq{New advisory date: $new_line6\n} if $self->{DEBUG};

    my $old_line6 = (split /\n/, $description)[5];
    $description =~ s/$old_line6/$new_line6/g;

    # get all date strings of the form "DD/HH00Z" (not unique)
    my @day_slash_hourZ = ( $description =~ m/(\d\d\/\d\d\d\dZ)/g );
    my %_uniq_Z         = map { $_ => 1 } @day_slash_hourZ;

    # generate slash Z format to pub year look up (every hour for 7 days - starting 24 hours before old/new dates - just to be safe)
    my $_old_Z_to_new = {};
    my ( $_old_year, $_old_day, $_old_mon, $_old_hour ) = ( $date_map->{old_year}, $date_map->{old_day}, $date_map->{old_mon}, $date_map->{old_hour} - 24 );    # go back 24 hrs
    my ( $_new_year, $_new_day, $_new_mon, $_new_hour ) = ( $date_map->{new_year}, $date_map->{new_day}, $date_map->{new_mon}, $date_map->{new_hour} - 24 );    # go back 24 hrs
    for my $i ( 1 .. 24 * 14 ) {

        # capture each quarter hour ...
        for my $min (qw/00 15 30 45/) {
            my $_old_Z = POSIX::strftime( qq{%d/%H${min}Z}, 0, 0, $_old_hour, $_old_day, $_old_mon, $_old_year );
            my $_new_Z = POSIX::strftime( qq{%d/%H${min}Z}, 0, 0, $_new_hour, $_new_day, $_new_mon, $_new_year );
            $_old_Z_to_new->{$_old_Z} = $_new_Z;
        }
        ++$_old_hour;
        ++$_new_hour;
    }

  REPLACE_Z:
    foreach my $_old_Z ( keys %_uniq_Z ) {
        my $_new_Z = $_old_Z_to_new->{$_old_Z};
        if ( not $_new_Z ) {
            print qq{Missing replacement for '$_old_Z' ... (should fix but is probably fine)\n};
            next REPLACE_Z;
        }
        $description =~ s/$_old_Z/$_new_Z/;
    }

    # update RSS item object's <description></description>
    $description =~ s/<pre>/<![CDATA[<pre>/;    # begin CDATA with <pre> tag
    $description =~ s/<\/pre>/<\/pre>]]>/;      # end CDATA after </pre> tag
    $src_rss->{items}->[0]->{description} = $description;
    $src_rss->{items}->[0]->{description} = $description;

    my $new_rss_file = sprintf( "%s/%02d.%02d%s.index-%s.xml", $new_dir, $adv, $new_storm, $date_map->{new_year} + 1900, $fst_basin );
    my $tmp_rss_file = sprintf( "%s.tmp", $new_rss_file );
    $src_rss->save($tmp_rss_file);
    File::Copy::move $tmp_rss_file, $new_rss_file;
    print qq{Wrote nowified RSS/XML Advisory: "$new_rss_file"\n} if $self->{DEBUG};
}

# translates storm number to the word for the number used in the forecast
sub _number_as_words {
    [
        qw/
          ONE TWO THREE FOUR FIVE SIX SEVEN EIGHT NINE TEN ELEVEN TWELVE THIRTEEN FOURTEEN FIFTEEN
          SIXTEEN SEVENTEEN EIGHTEEN NINETEEN TWENTY TWENTYONE TWENTYTWO TWENTYTHREE TWENTYFOUR
          TWENTYFIVE TWENTYSIX TWENTYSEVEN TWENTYEIGHT TWENTYNINE THIRTY THIRTYONE THIRTYTWO THIRTYTHREE
          THIRTYFOUR THIRTYFIVE THIRTYSIX THIRTYSEVEN THIRTYEIGHT THIRTYNINE FORTY FORTYONE FORTYTWO
          FORTYTHREE FORTYFOUR FORTYFIVE
          /
    ];
}

sub _storm_name_is_a_number {
    my ( $self, $storm_name ) = @_;
    my $NUMBER_WORDS = $self->_number_as_words;
    return grep { /$storm_name/ } @$NUMBER_WORDS;
}

sub _storm_number_to_word {
    my ( $self, $storm ) = @_;
    return $storm if not int $storm;
    my $NUMBER_WORDS = $self->_number_as_words;
    return $NUMBER_WORDS->[ int $storm - 1 ];
}

1;

__END__

=head1 NAME

   advisory_nowify.pl

=head1 USAGE

   ./advisory_nowify.pl --advStart <number> --advEnd <number> --oldStorm <storm#> --oldYear <storm YYYY> --oldDir ./input/dir --newStart= <YYYYDDMM[HH]> --newDir ./output/dir [--newStorm <number>] [--btkBasin btk-basin] [fstBasin fst-basin]

Example,

   ./advisory_nowify.pl --advStart 1 --advEnd 30 --oldStorm 18 --oldYear 2005 --oldDir ./rita --newStart=20202704 --newDir ./new-rita --newStorm 7 --btkBasin al fstBasin at 

=head1 DESCRIPTION

This script is used take an existing set of advisories (e.g., Rita, AL182005) and
update all time references in the best track and the forecast RSS XML so that
they are relative to a new date passed in using the C<--newStart> flag.

The primary purpose is to facilitated ASGS testing and readiness drills using
selected historical tracks, but using current meteorological data. The preparation
workflow entails running this script first to generate the modified best track
and forecast files in a new directory. Then the <replay-storm.pl> is run using
a configuration file that contains the details of the new storm, including the
new storm number and year (if options are set).

=head1 REQUIRED OPTIONS

=over 3

=item C<--advStart> number

Designates the first NHC advisory number to process from the old
storm. All storms from C<--advStart> to C<--advEnd> will be transformed.

=item C<--advEnd> number

Designates the last NHC advisory number to process from the old
storm. All storms from C<--advStart> to C<--advEnd> will be transformed.

=item C<--newDir> path/to/newDir

Designates the directory destination of the generated best track and
forecast files. If this directory doesn't exist, it will be created.

=item C<--newStart> YYYYDDMM[HH]

Defines the new start date in the prescribed format, C<YYYYDDMM>. The
values passed using this flag optionally accepts a two-digit number
representing the hour. Please note the format expected. If the created
advisories have unexpected dates, check to make sure you have not accidentally
swapped C<DD> and C<MM>. The internal date computations will gladly accept
these values.

Example,

    --newStart=20181504   # April 15, 2018 00Z
    
    --newStart=2018150403 # April 15, 2018 03Z

The starting hour, if provided via C<HH>, map directly to the starting hour
of the very first advisory for the old storm. If not set, C<HH>, defaults to
the starting hour of the avisory designated using C<--advStart>.

Note, there is no default value for this and it is required. Despite the name
of the script contains the word C<nowify>, it is not meant to imply that the
new start literally defaults to C<now()> if not set as an argument.

=item C<--oldDir> path/to/oldStorm

Denotes the directory that contains the C<old> best track and forecast files.
Assumes a name convention identical to that used by C<replay-storm.pl> and
used throughout the ASGS C<./input/sample_advisories> directory.

=back

=head1 NON-REQUIRED OPTIONS

=over 3

=item C<--btkBasin> btk-basin

Defaults to C<al> (Atlantic Basin), but may be set to something else. Used
to name the best track file, which looks like C<ADVISORY.bBASIN.STORMYEAR.dat>.

=item C<fstBasin> fst-basin

Defaults to C<at> (Atlantic Basin), but may be set to something else. Used
to name the forecast file, which looks like C<ADVISORY.index-BASIN.xml>.

=item C<--newStorm> number

This option allows the user to designate a different NHC storm number. If
not set, the new storm number will be the same as the C<--oldStorm>. This
is useful if issuing both old and new storms in the same C<replay> ensemble.

=item C<--newName> newName

Specify the new storm name as if it was issued by the NHC. The script can detect
when the olds storm is still known as it's NUMBER WORD (Nth storm of the season),
and if this is detected the NUMBER WORD version of C<--newStorm> number will be
substituted in it's place.  Forecast files (.xml) don't seem to have C<INVEST>
storms, but if this is detected, then this will be used in the new forecast. This
also applies to best track files, which do seem to have C<INVEST> as part of their
range of values for the storm name field.

=back

=head1 ASSUMPTIONS

To make a script such as this easier to create and maintain, the following
assumptions are made:

=over 3

=item * For each advisory to be converted, there are corresponding C<best track> and
C<forecast> files.

=item * The best track and forecast files are already consistent. This means that the
forecast file has been issued 3 hours after the last record in the best track file.

=item * The number of records contained in a best track file correspond to the number
of previous forecasts issued. This means for each current forecast, the best track
contains the latest storm track position and metric.

=item * Forecasts are issued every 6 hours.

=back

There are likely other hidden assumptions, but the enumerated ones above should
sufficiently explain any unexpected changes made in the new advisory files. They
are almost sure the result of the data that is contained in the source files
themselves (but maybe it's a bug:)).

=head1 LICENSE AND COPYRIGHT

This file is part of the ADCIRC Surge Guidance System (ASGS).  The ASGS is
free software: you can redistribute it and/or modify it under the terms of
the GNU General Public License as published by the Free Software Foundation,
either version 3 of the License, or (at your option) any later version.

ASGS is distributed in the hope that it will be useful, but WITHOUT ANY
WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with
the ASGS. If not, see <http://www.gnu.org/licenses/>.
