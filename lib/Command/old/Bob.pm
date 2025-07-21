package Command::Bob;
use feature 'say';
use utf8;

use Moo;
use strictures 2;
use namespace::clean;

use Exporter qw(import);
our @EXPORT_OK = qw(cmd_bob);

has bot                 => ( is => 'ro' );
has discord             => ( is => 'lazy', builder => sub { shift->bot->discord } );
has log                 => ( is => 'lazy', builder => sub { shift->bot->log } );
has name                => ( is => 'ro', default => 'Bob' );
has access              => ( is => 'ro', default => 0 );
has pattern             => ( is => 'ro', default => '^bob ?' );
has function            => ( is => 'ro', default => sub { \&cmd_bob } );
has usage               => ( is => 'ro', default => '');
has description         => ( is => 'ro', default => '');

sub cmd_bob {
    my ($self, $msg) = @_;

    my $channel = $msg->{'channel_id'};
    my $author = $msg->{'author'};
    my $args = $msg->{'content'};

    my $pattern = $self->pattern;
    $args =~ s/$pattern//i;

    my $discord = $self->discord;
    my $replyto = '<@' . $author->{'id'} . '>';

    $discord->send_message($channel, "Bob is God.");
}

1;
