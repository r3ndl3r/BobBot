package Command::Meme;
use feature 'say';
use utf8;

use Moo;
use strictures 2;
use namespace::clean;

use LWP::UserAgent;
use JSON;
use URI::Escape;

use Exporter qw(import);
our @EXPORT_OK = qw(cmd_meme);

has bot                 => ( is => 'ro' );
has discord             => ( is => 'lazy', builder => sub { shift->bot->discord } );
has log                 => ( is => 'lazy', builder => sub { shift->bot->log } );

has name                => ( is => 'ro', default => 'Meme' );
has access              => ( is => 'ro', default => 0 );
has description         => ( is => 'ro', default => 'Random meme from Reddit.' );
has pattern             => ( is => 'ro', default => '^meme ?' );
has function            => ( is => 'ro', default => sub { \&cmd_meme } );
has usage               => ( is => 'ro', default => <<EOF
Usage: !meme [subreddit]
Examples:
  !meme
  !meme dankmemes
  !meme memes
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
    $args = uri_escape($args); # URL encode the subreddit if provided

    # Choose a default subreddit if none is specified, or use the provided one
    my $subreddit = $args ? $args : 'memes'; # Default to 'memes' if no argument
    # Use the new meme-api.com endpoint, which pulls from Reddit
    my $url = "https://meme-api.com/gimme/$subreddit";

    my $ua = LWP::UserAgent->new;
    $ua->timeout(10); # Set a timeout for the request
    my $meme_res = $ua->get($url);

    if ($meme_res->is_success) {
        my $json = from_json($meme_res->decoded_content);

        # Check if the API returned an error (e.g., subreddit not found)
        if ($json->{code} && $json->{message}) {
            $discord->send_message($channel, "Error fetching meme: " . $json->{message});
        } elsif ($json->{url}) {
            my $meme_url = $json->{url};
            my $post_title = $json->{title} // 'Meme'; # Get title if available

            my $embed = {
                'embeds' => [
                    {
                        'title' => $post_title,
                        'url'   => $meme_url,
                        'image' => {
                            'url' => $meme_url,
                        },
                        'color' => 16750080, # A nice orange color for embeds
                        'footer' => {
                            'text' => "From r/$json->{subreddit}",
                        }
                    }
                ]
            };

            $discord->send_message($channel, $embed);
            $discord->create_reaction($msg->{'channel_id'}, $msg->{'id'}, "🤖");
        } else {
            $discord->send_message($channel, "Could not find a meme. Try a different subreddit or try again later.");
        }
    } else {
        $discord->send_message($channel, "Error: " . $meme_res->status_line . ". Try again later.");
    }
}

1;