package Command::Test;
use feature 'say';
use utf8;

use Moo;
use strictures 2;
use Mojo::JSON qw(decode_json);
use namespace::clean;

use Exporter qw(import);
our @EXPORT_OK = qw(cmd_test);

has bot                 => ( is => 'ro' );
has discord             => ( is => 'lazy', builder => sub { shift->bot->discord } );
has log                 => ( is => 'lazy', builder => sub { shift->bot->log } );
has name                => ( is => 'ro', default => 'Test' );
has access              => ( is => 'ro', default => 0 );
has description         => ( is => 'ro', default => '' );
has pattern             => ( is => 'ro', default => '^test ?' );
has function            => ( is => 'ro', default => sub { \&cmd_test } );
has usage               => ( is => 'ro', default => '' );

sub cmd_test
{
    my ($self, $msg) = @_;

    my $channel = $msg->{'channel_id'};
    my $author = $msg->{'author'};
    my $args = $msg->{'content'};

    my $pattern = $self->pattern;
    $args =~ s/$pattern//i;

    my $discord = $self->discord;
    my $replyto = '<@' . $author->{'id'} . '>';

    eval 
    { 
        my $json = decode_json($args);
        $discord->send_message($channel, $json);
    };
    if ($@)
    {
        # Send as plaintext instead.
        $discord->send_message($channel, "hello");
    }
}

1;
