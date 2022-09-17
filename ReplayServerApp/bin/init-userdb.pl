#!/usr/bin/env perl

use warnings;
use strict;
use FindBin qw/$Bin/;
use DBD::SQLite qw//;
use Data::GUID qw//;
use Crypt::CBC qw//;
use Crypt::PBKDF2 qw//;
use YAML qw//;
use Email::Sender::Simple qw(sendmail);  # main email capability (receives TLS obj)
use Email::Sender::Transport::SMTP::TLS; # creates transport object
use Email::Simple::Creator;              # generates message itself (converts header and body from hash to text email)

# load auth info 
my $CONFIG = qq{$Bin/../config.yml};
local $@;
my $config = eval {
    YAML::LoadFile($CONFIG);
};
die qq{Configuration file with AES key can't be found, "$CONFIG".\n} if ($@ or not $config);

my $DBFILE = $config->{auth}->{dbfile};
my $AESKEY = $config->{auth}->{aeskey};

sub read_p($$) {
    my ( $prompt, $default ) = @_;
    printf qq{\n%s [%s] }, $prompt, $default;
    my $ans = <STDIN>;
    chomp $ans;
    return $ans || $default;
}

if ( -e $DBFILE ) {
    print qq{DB file found, $DBFILE.\n};
    my $ans = read_p qq{Delete and start over?}, q{N};
    if ( $ans and $ans =~ m/^y/ ) {
        unlink $DBFILE;
        print qq{$DBFILE has been deleted, initializing a new one ...\n};
    }
}

my $cSQL = <<EOSQL;
    CREATE TABLE IF NOT EXISTS tbl_users (
      userid   INTEGER PRIMARY KEY,
      uuid     TEXT NOT NULL UNIQUE,
      username TEXT NOT NULL UNIQUE,
      email    TEXT NOT NULL,
      passhash TEXT,
      apikey   TEXT,
      apihash  TEXT
    );
EOSQL

my $dbh = DBI->connect( "dbi:SQLite:dbname=$DBFILE", "", "" );

$dbh->do($cSQL);

print qq{\nCreate users... it 'ctrl-c' when done.\n};

sub hashify {
    my $password = shift;
    my $pbkdf2   = Crypt::PBKDF2->new(
        hash_class => 'HMACSHA2',
        hash_args  => {
            sha_size => 512,
        },
        iterations => 10000,
        salt_len   => 10,
    );
    my $hash = $pbkdf2->generate($password);
    die qq{Password hashing went side ways, this should never fail?\n} if ( not $pbkdf2->validate( $hash, $password ) );
    return $hash;
}

sub get_rando {
    my $length = shift // 12;
    return join '', map +( 0 .. 9, 'a' .. 'z', 'A' .. 'Z' )[ rand( 10 + 26 * 2 ) ], 1 .. $length;
}

# AES Symmetric
sub _encrypt {
    my $password   = shift;
    my $plaintext  = shift;
    my $cipher     = Crypt::CBC->new( -pass => $password, -cipher => 'Cipher::AES', -pbkdf=>'pbkdf2' );
    my $ciphertext = $cipher->encrypt($plaintext);
    return $ciphertext;
}

# AES Symmetric
sub _decrypt {
    my $password   = shift;
    my $ciphertext = shift;
    my $cipher     = Crypt::CBC->new( -pass => $password, -cipher => 'Cipher::AES', -pbkdf=>'pbkdf2' );
    my $plaintext  = $cipher->decrypt($ciphertext);
    return $plaintext;
}

while (1) {
  USERNAME:
    my $uuid = sprintf qq{%s}, get_rando(32);
    my $username  = read_p q{New username (req'd): }, q{};
    goto USERNAME if not $username;
  EMAIL:
    my $email = read_p q{New email (req'd): }, q{};
    goto EMAIL if not $email;
    my $randpass   = get_rando 16;
    my $password   = read_p q{New password: }, qq{$randpass};
    my $passhash   = hashify($password);
    my $api_key    = Data::GUID->new;
    my $api_secret = sprintf qq{%s-%s-%s-%s}, get_rando(16), get_rando(16), get_rando(16), get_rando(16);
    my $encrypted_secret = _encrypt( $AESKEY, $api_secret );
    my $decrypted_secret = _decrypt( $AESKEY, $encrypted_secret );

    # verify encryption/decryption of API secret key
    if ( $decrypted_secret ne $api_secret ) {
        die qq{Unexpected error encountered when verifying that the API secrets key was properly encrypted for DB storage. \n};
    }

    my $auth_block = sprintf qq{
; DO NOT LOSE. Copy credentials or lose some information forever!
;
;  WWW USERNAME  : %s 
;  WWW PASSWORD  : %s 
;  USER UUID     : %s 
;  EMAIL ADDRESS : %s 
;
; credential entry for ~/asgs-global.conf, used by the replaycli
[replayd]
apikey=%s
apisecret=%s
}, $username, $password, $uuid, $email, $api_key, $api_secret;
    my $save = read_p q{Save ?}, q{Y};

    if ( $save =~ m/^Y/i ) {
        print qq{Credentials for '$username' saved! ...\n};
        my $iSQL = q{
          INSERT into tbl_users
            (uuid,username,email,passhash,apikey,apihash)
          VALUES (?,?,?,?,?,?)
        };
        $dbh->do( $iSQL, undef, $uuid, $username, $email // q{n/a}, $passhash, $api_key, $encrypted_secret );
        if ($email) {
            my $ans = read_p qq{Send email '$email' credentials?}, q{N};
            if ( $ans !~ m/\An\Z/ ) {
              _do_send($auth_block, $email); 
            }
        }
    }
}

sub _do_send {
    my ($body, $to) = @_; 
    local $@;
    my $ok = eval {
      my $transport = Email::Sender::Transport::SMTP::TLS->new(
        host     => $config->{notify}->{email}->{smtp_host},
        port     => $config->{notify}->{email}->{smtp_port} // 587,  # defaults to TLS if not set
        username => $config->{notify}->{email}->{smtp_username},
        password => $config->{notify}->{email}->{smtp_password},
        helo     => 'HELO',
      );
      my $message = Email::Simple->create(
        header => [
            'Reply-To' => $config->{nofify}->{email}->{reply_to_address} // $config->{notify}->{email}->{from_address},
            From       => $config->{notify}->{email}->{from_address},
            To         => $to,
            Subject    => q{An account has been created for you!}, 
        ],
        body => $body,
      );
      sendmail( $message, { transport => $transport } );
      1;
    };
    if (not $ok or $@) {
      printf STDERR qq{Error sending email: %s\n}, $@ // q{Unknown error.};
    };
}
