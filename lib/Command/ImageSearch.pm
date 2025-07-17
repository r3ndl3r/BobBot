package Command::ImageSearch;
use feature 'say';
use utf8;

use Moo;
use strictures 2;
use namespace::clean;

use LWP::UserAgent;
use JSON;
use URI::Escape;

use Exporter qw(import);
our @EXPORT_OK = qw(cmd_image_search);

has bot                 => ( is => 'ro' );
has discord             => ( is => 'lazy', builder => sub { shift->bot->discord } );
has log                 => ( is => 'lazy', builder => sub { shift->bot->log } );
has name                => ( is => 'ro', default => 'Image' );
has access              => ( is => 'ro', default => 0 );
has description         => ( is => 'ro', default => 'Searches for an image based on a query and posts it.' );
has pattern             => ( is => 'ro', default => '^image ?' );
has function            => ( is => 'ro', default => sub { \&cmd_image_search } );
has usage               => ( is => 'ro', default => 'Usage: `!image <search term>`' );


sub cmd_image_search {
    my ($self, $msg) = @_;

    my $channel = $msg->{'channel_id'};
    my $discord = $self->discord;
    my $pattern = $self->pattern;

    my $args = $msg->{'content'};
    $args =~ s/$pattern//i;

    # Check if the user provided a search term.
    unless (length $args > 0) {
        $discord->send_message($channel, $self->usage);
        $self->bot->react_error($channel, $msg->{'id'});
        return;
    }

    $self->debug("User requested an image search for: '$args'");

    # Get the API configuration from config.ini
    my $config = $self->bot->config->{google_image_search};
    unless ($config && $config->{api_key} && $config->{cx}) {
        $self->log->error("[ImageSearch.pm] Google API key or CX is not configured in config.ini.");
        $discord->send_message($channel, "Sorry, the image search command is not configured correctly by the bot owner.");
        $self->bot->react_error($channel, $msg->{'id'});
        return;
    }

    my $api_key = $config->{api_key};
    my $cx      = $config->{cx};
    my $query   = uri_escape($args);

    # Construct the Google Custom Search API URL. This fetches 10 image results.
    my $url = "https://www.googleapis.com/customsearch/v1?key=$api_key&cx=$cx&q=$query&searchType=image&num=10";
    $self->debug("Fetching URL: $url");

    # Use Mojo's non-blocking user agent to make the API call
    $self->discord->rest->ua->get_p($url)->then(sub {
        my $tx = shift;

        unless ($tx->res->is_success) {
            $self->debug("Failed to fetch image results: " . $tx->res->status_line);
            $discord->send_message($channel, "Sorry, I couldn't connect to the image search API. Error: " . $tx->res->message);
            $self->bot->react_error($channel, $msg->{'id'});
            return;
        }

        my $json = $tx->res->json;

        # Check for API-level errors, like exceeding the daily quota.
        if (my $error = $json->{error}) {
            $self->debug("Google API returned an error: " . $error->{message});
            $discord->send_message($channel, "The image search API returned an error: " . $error->{message});
            $self->bot->react_error($channel, $msg->{'id'});
            return;
        }

        # Check if any items were returned.
        unless (ref $json->{items} eq 'ARRAY' && @{$json->{items}}) {
            $self->debug("No image results found for query: '$args'");
            $discord->send_message($channel, "Sorry, I couldn't find any images for '**$args**'.");
            $self->bot->react_error($channel, $msg->{'id'});
            return;
        }

        # Pick a random image from the results.
        my $item = $json->{items}->[rand @{$json->{items}}];
        my $image_url = $item->{link};
        my $image_title = $item->{title};
        my $image_context = $item->{image}{contextLink};

        $self->debug("Found image: $image_url");

        my $embed = {
            'embeds' => [{
                'title' => $image_title,
                'url'   => $image_context,
                'color' => 7506394, # A nice purple color
                'image' => {
                    'url' => $image_url
                },
                'footer' => {
                    'text' => "Searched for: $args"
                }
            }]
        };

        $discord->send_message($channel, $embed);
        $self->bot->react_robot($channel, $msg->{'id'});

    })->catch(sub {
        my $err = shift;
        $self->log->error("[ImageSearch.pm] Unhandled promise error during image fetch: $err");
        $discord->send_message($channel, "An unexpected error occurred while searching for the image.");
        $self->bot->react_error($channel, $msg->{'id'});
    });
}

1;