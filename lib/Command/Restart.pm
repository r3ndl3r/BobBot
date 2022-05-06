package Command::Restart;
use feature 'say';
use utf8;

use Moo;
use strictures 2;
use namespace::clean;
use Component::DBI;

use Exporter qw(import);
our @EXPORT_OK = qw(cmd_bob);

has bot                 => ( is => 'ro' );
has discord             => ( is => 'lazy', builder => sub { shift->bot->discord } );
has log                 => ( is => 'lazy', builder => sub { shift->bot->log } );
has name                => ( is => 'ro', default => 'Restart' );
has access              => ( is => 'ro', default => 1 );
has description         => ( is => 'ro', default => 'Restarts the bot.' );
has pattern             => ( is => 'ro', default => '^restart ?' );
has function            => ( is => 'ro', default => sub { \&cmd_restart } );
has usage               => ( is => 'ro', default => '!restart' );

sub cmd_restart {
    my ($self, $msg) = @_;
    
    my $channel = $msg->{'channel_id'};
    my $discord = $self->discord;

    $discord->send_message($channel, "OK", sub { exit });
}

1;
