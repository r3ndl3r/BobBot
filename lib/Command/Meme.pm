package Command::Meme;
use feature 'say';
use utf8;

use Moo;
use strictures 2;
use namespace::clean;

use LWP::UserAgent;
use JSON;

use Exporter qw(import);
our @EXPORT_OK = qw(cmd_meme);

has bot                 => ( is => 'ro' );
has discord             => ( is => 'lazy', builder => sub { shift->bot->discord } );
has log                 => ( is => 'lazy', builder => sub { shift->bot->log } );

has name                => ( is => 'ro', default => 'Meme' );
has access              => ( is => 'ro', default => 0 );
has description         => ( is => 'ro', default => 'Rando meme' );
has pattern             => ( is => 'ro', default => '^meme ?' );
has function            => ( is => 'ro', default => sub { \&cmd_meme } );
has usage               => ( is => 'ro', default => <<EOF
Usage: !meme
EOF
);

sub cmd_meme {
    my ($self, $msg) = @_;

    my $channel = $msg->{'channel_id'};
    my $id      = $msg->{'id'};
    my $author  = $msg->{'author'};
    my $args    = $msg->{'content'};
    my $discord = $self->discord;
    my $pattern = $self->pattern;
    $args =~ s/$pattern//i;

    my $url  = "https://meme-api.herokuapp.com/gimme";
    my $meme = LWP::UserAgent->new->get($url);

    if ($meme->is_success) {
        my $json = from_json($meme->decoded_content);
        my $image = LWP::UserAgent->new->get();

        $discord->send_message($channel, $json->{url});
        $discord->create_reaction($msg->{'channel_id'}, $msg->{'id'}, "🤖");
    } else {
        $discord->send_message($channel, "Error: " . $meme->status_line . ". Try again later");
}
 
}

1;
