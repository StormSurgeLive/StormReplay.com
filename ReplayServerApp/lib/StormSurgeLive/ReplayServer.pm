package StormSurgeLive::ReplayServer;

use strict;
use warnings;

use Dancer2;
use DBD::SQLite qw//;
use Crypt::PBKDF2 qw//;
use YAML qw/LoadFile/;
use FindBin qw/$Bin/;
use File::Path qw/make_path/;
use Util::H2O::More qw/h2o o2h baptise/;
use Config::Tiny qw//;
use Digest::SHA qw/sha256_hex/;
use Digest::MD5 qw/md5_hex/;
use MIME::Base64 qw/decode_base64/;
use HTTP::Status qw/:constants :is status_message/;
use POSIX qw//;
use POSIX::strptime qw//;
use Crypt::CBC qw//;

our $VERSION = '0.1';

my $STORMS = YAML::LoadFile(config->{local}->{storms_file});

# make sure config dir exists
if ( config->{replayd_base}->{configdir} and not -d config->{replayd_base}->{configdir} ) {
    make_path( config->{replayd_base}->{configdir}, { chmod => 0755 } );
}

prefix '/' => sub {
    get '' => sub {
        template 'index' => { title => 'Login' }, { layout => q{3col-public} };
    };

    get 'home' => sub {
        my $member = _assert_auth();

        template 'home' => { title => 'Member Home', member => $member }, { layout => q{3col-member} };
    };

    # serve index-at.xml by reading file rather than statically (much slower)
    get 'rss/:uuid/:file' => sub {
        my $uuid     = route_parameters->get(q{uuid});
        my $file     = route_parameters->get(q{file});
        my $rss_path = sprintf( qq{%s/../public/rss/%s/%s}, $Bin, $uuid, $file );
        if ( not -e $rss_path ) {
            send_error q/File Not Found/, HTTP_NOT_FOUND;
        }
        open my $fh, q{<}, $rss_path || die $!;
        local $/;
        my $content = <$fh>;
        close $fh;
        content_type q{application/xml};
        return $content;
    };

    get 'new' => sub {
        my $member = _assert_auth();

        # defined in the application configuration
        my $storms    = $STORMS->{storm_data}->{storms};
        my $stormJSON = encode_json $storms;

        template 'new' => { title => 'Configure a New Storm', member => $member, storms => $storms, stormJSON => $stormJSON }, { layout => q{3col-member} };
    };

    get 'stormlist' => sub {
        my $member = _assert_auth();

        # defined in the application configuration
        my $storms = $STORMS->{storm_data}->{storms};

        template 'stormlist' => { title => 'Storm Archive Info', member => $member, storms => $storms }, { layout => q{3col-member} };
    };

    get 'logout' => sub {
        session member => undef;
        redirect '/';
    };

    get 'status' => sub {
        my $member      = _assert_auth();
        my $details_ref = _status($member);
        template 'status' => { title => 'Storm Status', member => $member, details => $details_ref }, { layout => q{3col-member} };
    };

    get 'foo' => sub {
        return 'fist bmp';
    };
};

sub _status {
    my $member    = shift;
    my $configdir = config->{replayd_base}->{configdir};
    my $statusdir = config->{replayd_base}->{statusdir};

    my $details_ref = {};

    my $uuid = $member->uuid; 

    # get all specific user configs
    opendir( my $dh1, $configdir ) || die "Can't opendir $configdir: $!";
    my @configfiles = grep { /^$uuid/ && -f "$configdir/$_" } readdir($dh1);
    closedir $dh1;
    my @configs = grep { /\.config$/ } @configfiles;

    foreach my $file (@configs) {
        my $storm       = ( split /\./, $file )[1];
        my $_config_ref = { %{ Config::Tiny->read(qq{$configdir/$file}) } };
        $details_ref->{$storm}->{config} = $_config_ref;
    }

    # get all specific user configs
    opendir( my $dh2, $statusdir ) || die "Can't opendir $statusdir: $!";
    my @statusfiles = grep { /^$uuid/ && -f "$statusdir/$_" } readdir($dh2);
    closedir $dh2;
    my @details_ref = grep { /\.status$/ } @statusfiles;

    foreach my $file (@details_ref) {
        my $storm       = ( split /\./, $file )[1];
        my $_status_ref = { %{ Config::Tiny->read(qq{$statusdir/$file}) } };
        $details_ref->{$storm}->{status} = $_status_ref;
    }
    return $details_ref;
}

# API endpoints
prefix '/api' => sub {
    get '/storms' => sub {
        my $member = _do_hmac();
        my $storms = $STORMS->{storm_data}->{storms};
        if (%$storms) {
            send_as JSON => { msg => q{OK}, storms => $storms },;
        }
        else {
            send_error q/{ msg => q{No storms configured for replay.}/, HTTP_GONE;
        }
      },

      get '/uuid' => sub {
        my $member = _do_hmac();
        send_as JSON => { msg => q{OK}, uuid => $member->uuid, md5 => md5_hex( $member->uuid ) };
      };

    get '/status' => sub {
        my $member      = _do_hmac();
        my $details_ref = _status($member);
        send_as JSON => $details_ref;
    };

    post '/login' => sub {
        my $member = h2o decode_json( request->content ), qw/md5 password username uuid/;

        if ( my $urec = _authenticate($member) ) {
            session member => $urec;
            send_as JSON => { msg => q{OK} };
        }

        send_error q/Access Denied/, HTTP_FORBIDDEN;
    };

    # TODO:
    # /storm/:name/nextAdv and /storm/:name indicate the need for a
    # queuing mechanism to communicate between this "gateway" for
    # the API and replayd, which is what's actually doing the work
    #

    # will cause storm ':name' to advance its advisory to the next on;
    post '/storm/:name/nextAdv' => sub {
        my $member = ( request_header 'X-replayd-api-version' ) ? _do_hmac() : _assert_auth();

        # get storm name from route
        my $name = route_parameters->get(q{name});

        # touches a storm specific .delete file that replayd
        # will detect, the effect the nextAdv sequence
        my $storm_status  = _status_file_name( $name, $member );
        my $storm_config  = _config_file_name( $name, $member );
        my $storm_nextAdv = _nextAdv_file_name( $name, $member );

        # make sure status and config exists, nextAdv doesn't yet exist
        if ( not -e $storm_status or not -e $storm_config or -e $storm_nextAdv ) {
            status HTTP_PRECONDITION_FAILED;    # 412
            send_as JSON => { msg => qq{Storm '$name' is not running, or 'nextAdv' has already been issued. Please login via StormReplay.com to confirm.} };
        }

	# adding epoch to this file, even though its mere existence is enough
	# to trigger the logic in replayd to nextAdv this storm
        open my $fh, q{>}, $storm_nextAdv;
        print $fh time;
        close $fh;

        send_as JSON => { msg => q{OK} };
    };

    del '/storm/:name' => sub {
        my $member = ( request_header 'X-replayd-api-version' ) ? _do_hmac() : _assert_auth();

        # get storm name from route
        my $name = route_parameters->get(q{name});

        # touches a storm specific .delete file that replayd
        # will detect, the effect the DELETE sequence
        my $storm_status = _status_file_name( $name, $member );
        my $storm_config = _config_file_name( $name, $member );
        my $storm_delete = _delete_file_name( $name, $member );

        # make sure status and config exists, delete doesn't yet exist
        if ( not -e $storm_status or not -e $storm_config or -e $storm_delete ) {
            status HTTP_PRECONDITION_FAILED;    # 412
            send_as JSON => { msg => qq{Storm '$name' is not running, or 'delete' has already been issued. Please login via StormReplay.com to confirm.} };
        }

	# adding epoch to this file, even though its mere existence is enough
	# to trigger the logic in replayd to delete this storm
        open my $fh, q{>}, $storm_delete;
        print $fh time;
        close $fh;

        send_as JSON => { msg => q{OK} };
    };

    post '/configure' => sub {
        my $member = ( request_header 'X-replayd-api-version' ) ? _do_hmac() : _assert_auth();

        # capture storm config from request data
        my @form_fields = (
            qw/
              base btk_basin endadv md5 name nhc_basin
              notify nowbase nowyear number rss_basin
              source startadv storm year ipaddress
              nhc_storm hostname httpport loop nowify
              email newstart coldstartdate hindcastlength uuid
              /
        );

        my $formdata = h2o decode_json( request->content ), @form_fields;

	# basic validation of $formdata
        if ( not $formdata->name ) {
            send_error q{Invalid request}, HTTP_BAD_REQUEST;
        }

        # source storm information
        my $name         = $formdata->name;
        my $replayd_base = h2o { %{config->{replayd_base}} };
        my $storm        = h2o { %{$STORMS->{storm_data}->{storms}->{$name}} };

	# set some defaults in $formdata
        if ( not $formdata->loop ) {
            $formdata->loop(0);
        }

	# set time defaults
	my $time         = time;

	# hindcastlength - typically is 30.0 days
	if (not $formdata->hindcastlength) {
          $formdata->hindcastlength(30.0);
	}

	# ASGS' config, COLDSTARTDATE should be 30.0 days prior
	# to newStart and the ending "HH" *must* be the same, otherwise ASGS'
	# ./storm_track_gen.pl will not find the starting best track record
	# and will die

        ## compute COLDSTARTDATE based on original storm's first btk time stamp
	my $hcl = $formdata->hindcastlength;

	# if not provided, defaults to basically, NOW 
	if (not $formdata->newstart) {
          my $newstart     = POSIX::strftime( "%Y%m%d%H", localtime($time) );
          $formdata->newstart($newstart);
	}

        if (not $formdata->nowify) {
	  my ($sec, $min, $hour, $mday, $mon, $year, $wday, $yday) = POSIX::strptime($storm->btk_time_first, "%Y%m%d%H");
          my $coldstartdate = POSIX::strftime( "%Y%m%d%H", $sec, $min, $hour-($hcl*24), $mday, $mon, $year, $wday, $yday );
	  $formdata->coldstartdate($coldstartdate);
          $formdata->newstart($storm->btk_time_first);
          $formdata->nhc_storm( sprintf( "%s%02d%04d", $storm->nhc_basin, $storm->number, $storm->year ) );
          $formdata->nowyear($storm->year);
        }
	elsif (not $formdata->coldstartdate) {
	  my ($sec, $min, $hour, $mday, $mon, $year, $wday, $yday) = POSIX::strptime($formdata->newstart, "%Y%m%d%H");
          my $coldstartdate = POSIX::strftime( "%Y%m%d%H", $sec, $min, $hour-($hcl*24), $mday, $mon, $year, $wday, $yday );
	  $formdata->coldstartdate($coldstartdate);
	}

	# year for nowification
	if (not $formdata->nowyear) {
          my $nowyear      = POSIX::strftime( "%Y", localtime($time) );
          $formdata->nowyear($nowyear);
        }

        if (not $formdata->nhc_storm) {
          $formdata->nhc_storm( sprintf( "%s%02d%04d", $storm->nhc_basin, $storm->number, $formdata->{nowyear} ) );
        }

        # add to $formdata so it's in the storm config file
        $formdata->uuid( $member->uuid );                        # augment w/ member uuid
        $formdata->base( $STORMS->{storm_data}->{base} );        # augment w/ base directory for original storm data
        $formdata->nowbase( $replayd_base->nowbase );            # augment w/ nowbase directory for original storm data
        $formdata->source( $storm->source );                     # augment w/ source directory for original storm data
        $formdata->number( $storm->number );                     # augment w/ original storm number
        $formdata->year( $storm->year );                         # augment w/ original storm year
        $formdata->btk_basin( $storm->btk_basin );               # augment w/ btk basin prefix
        $formdata->nhc_basin( $storm->nhc_basin );               # augment w/ nhc basin prefix
        $formdata->rss_basin( $storm->rss_basin );               # augment w/ rss basin prefix
        $formdata->ipaddress( config->{local}->{ipaddress} );    # augment w/ public ip address
        $formdata->hostname( $replayd_base->hostname );          # augment w/ hostname
        $formdata->httpport( $replayd_base->httpport );          # augment w/ http port
        # augment w/ NHC storm designation, i.e.: al052022

        # add md5_hex of uuid to config file to disambiguate
        my $storm_config = _config_file_name( $name, $member );
        my $storm_status = _status_file_name( $name, $member );

        # check if config for this storm, user already exists (even if ended)
        if ( -e $storm_config ) {
            if ( request_header 'X-replayd-api-version' ) {
                status HTTP_CONFLICT;
                send_as JSON => { msg => q{Storm configuration already exists} };
            }
            else {
                send_error q{Storm configuration already exists}, HTTP_CONFLICT;
            }
        }

      WRITE_CONFIG:
        {
            # output in INI format
            open my $fh, q{>}, $storm_config || die $!;
            my @lines = qq/[replayd]/;
            foreach my $k ( sort keys %$formdata ) {
                push @lines, sprintf( qq{%s=%s}, uc $k, $formdata->$k );
            }
            my $lines = join qq{\n}, @lines;
            print $fh $lines;

            # write config file
            my $config_template = qq{
FTP_ROOT=[% FTP_ROOT %]
FTP_FDIR=[% FTP_FDIR %]
FTP_HDIR=[% FTP_HDIR %]
HTTP_ROOT=[% HTTP_ROOT %]
};
            my $template      = Template->new;
            my $template_vars = config->{replayd_base};
            $template_vars->{md5} = $member->uuid;
            my $config_content;
            $template->process( \$config_template, $template_vars, \$config_content );
            print $fh $config_content;
            close $fh;
        }

      WRITE_STATUS:
        {
            # initialize status file
            open my $fh, qq{>}, $storm_status || die $!;
            my $start = $formdata->startadv;

            # indentation in qq{} below, is purposeful
            print $fh qq{
[status]
STATE=NEED2NOWIFY
LASTADV=NaN
CURRENTADV=NaN
NEXTADV=NaN
EARLIEST_ISSUE_EPOCH=NaN
};
            close $fh;
        }

        send_as JSON => { msg => q{OK} };
    };
};
sub _config_file_name {
    my ( $storm_name, $member ) = @_;
    my $storm_config = sprintf qq{%s/%s.%s.config}, config->{replayd_base}->{configdir}, $member->uuid, $storm_name;
    return $storm_config;
}

sub _status_file_name {
    my ( $storm_name, $member ) = @_;
    my $storm_status = sprintf qq{%s/%s.%s.status}, config->{replayd_base}->{statusdir}, $member->uuid, $storm_name;
    return $storm_status;
}

sub _delete_file_name {
    my ( $storm_name, $member ) = @_;
    my $storm_status = sprintf qq{%s/%s.%s.delete}, config->{replayd_base}->{statusdir}, $member->uuid, $storm_name;
    return $storm_status;
}

sub _nextAdv_file_name {
    my ( $storm_name, $member ) = @_;
    my $storm_status = sprintf qq{%s/%s.%s.nextAdv}, config->{replayd_base}->{statusdir}, $member->uuid, $storm_name;
    return $storm_status;
}

# opens users YAML, but also adds a section that makes it
# easier for lookup by 'apikey' used in HMAC API authentication
sub _get_users_lookup {
    my $users_file = config->{auth}->{passwd};
    my $userlookup = YAML::LoadFile($users_file);

    # add lookup by apikey
    my $by_apikey = {};
    foreach my $user ( keys %{ $userlookup->{users} } ) {
        $by_apikey->{ $userlookup->{users}->{$user}->{apikey} } = $userlookup->{users}->{$user};

        # - initialize empty keys so h2o -recurse picks them up
        $by_apikey->{ $userlookup->{users}->{$user}->{apikey} }->{md5} = md5_hex( $userlookup->{users}->{$user}->{uuid} );
    }
    $userlookup->{apikeys} = $by_apikey;
    return h2o -recurse, $userlookup;
}

# AES Symmetric
sub _decrypt {
    my $password  = shift;
    my $ciphertext = shift;
    my $cipher = Crypt::CBC->new( -pass => $password, -cipher => 'Cipher::AES', -pbkdf=>'pbkdf2');
    my $plaintext = $cipher->decrypt($ciphertext);
    return $plaintext;
}

# API authentication, also sets $member via session so
# that the /configure call can work the same; either by
# API call or via WWW login session
sub _do_hmac {
    my $member;
    if ( my $version = request_header 'X-replayd-api-version' ) {

        # grab headers, verify possession of proper secret by trying
        # to replicate the Authorization header
        my $Authorization = request_header 'Authorization';
        my $nonce         = request_header 'x-auth-nonce';
        my $decoded       = decode_base64($Authorization);
        my ( $apikey, $signature ) = split /:/, $decoded;

        my $USERDB  = sprintf(qq{%s/%s}, qq{$Bin/..}, config->{auth}->{dbfile});
        my $dbh     = DBI->connect( "dbi:SQLite:dbname=$USERDB", "", "" );
        my $sSQL    = qq{SELECT * from tbl_users WHERE apikey=?};
        $member  = h2o $dbh->selectrow_hashref($sSQL, undef, $apikey);

        my $test_secretkey2 = _decrypt(config->{auth}->{aeskey}, $member->{apihash});
        my $test_signature2 = sha256_hex( $nonce . $test_secretkey2 );

        if ( $test_signature2 ne $signature ) {
            # A P I  A U T H  F A I L E D
            send_error q/{ msg:"Access Denied" }/, HTTP_FORBIDDEN;
        }
    }
    return $member;
}

# assertion to check that for WWW sessions, the login
# has been done or is not expired
sub _assert_auth {
    my $member = session('member');

    if ( q{HASH} eq ref $member ) {
        h2o $member, qw/username/;
    }

    # auth mode 1 - via JS API that relies on the login cookie
    if ( not $member or not defined $member->username ) {
        # H T M L  A U T H  F A I L E D
        redirect '/logout';
    }

    return $member;
}

sub _checkhash {
    my ($hash, $password) = @_;
    chomp $password;
    my $pbkdf2   = Crypt::PBKDF2->new();
    return $pbkdf2->validate($hash, $password);
}

# used by POST:/login for WWW access
sub _authenticate {
    my $formdata = shift;

    my $USERDB  = sprintf(qq{%s/%s}, qq{$Bin/..}, config->{auth}->{dbfile});
    my $dbh     = DBI->connect( "dbi:SQLite:dbname=$USERDB", "", "" );
    my $sSQL    = qq{SELECT * from tbl_users WHERE username=?};
    my $member  = $dbh->selectrow_hashref($sSQL, undef, $formdata->username);
     
    if ( not $member or not _checkhash($member->{passhash}, $formdata->password)) {
        return undef;
    }

    return $member;
}

true;
