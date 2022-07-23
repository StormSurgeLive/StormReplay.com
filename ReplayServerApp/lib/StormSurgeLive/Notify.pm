package StormSurgeLive::Notify;

use strict;
use warnings;
use Email::Sender::Simple qw(sendmail);
use Email::Sender::Transport::SMTP::TLS;
use Email::Simple::Creator;
use Util::H2O::More qw/h2o baptise/;

sub new {
    my ( $pkg, $opts ) = @_;

    my $self = baptise $opts, $pkg, qw/from_address reply_to_address smtp_host smtp_port smtp_password smtp_username/;

    # quick validation for required fields (all of them are required)
    if ( not( $self->smtp_host and $self->smtp_password and $self->smtp_username ) ) {
        die qq{Constructor requires:
        smtp_host     => \$host,
        smtp_username => \$username,
        smtp_password => \$password,
        from_address  => \$from,
Optionally:
        reply_to_address => \$replyto, # defaults to \$from
        smtp_port        => \$port,    # defaults to 587
      \n};
    }

    return $self;
}

sub send {
    my ( $self, %opts ) = @_;
    my $o = h2o \%opts, qw/to subject content/;

    # set up TLS transport
    my $transport = Email::Sender::Transport::SMTP::TLS->new(
        host     => $self->smtp_host,
        port     => $self->smtp_port // 587,    # defaults to TLS if not set
        username => $self->smtp_username,
        password => $self->smtp_password,
        helo     => 'HELO',
    );

    # build up message
    my $message = Email::Simple->create(
        header => [
            To         => $o->to,
            'Reply-To' => $self->reply_to_address // $self->from_address,
            From       => $self->from_address,
            Subject    => $o->subject,
        ],
        body => $o->content,
    );

    # send mail
    sendmail( $message, { transport => $transport } );

    return;
}

1;
