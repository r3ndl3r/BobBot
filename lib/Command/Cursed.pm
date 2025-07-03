package Command::Cursed;
use feature 'say';
use utf8;

use Moo;
use strictures 2;
use namespace::clean;

use JSON;
use Component::DBI;
use Mojo::Promise;

use Exporter qw(import);
our @EXPORT_OK = qw(cmd_cursed);

has bot                 => ( is => 'ro' );
has discord             => ( is => 'lazy', builder => sub { shift->bot->discord } );
has log                 => ( is => 'lazy', builder => sub { shift->bot->log } );
has db                  => ( is => 'lazy', builder => sub { Component::DBI->new() } );

has name                => ( is => 'ro', default => 'Cursed' );
has access              => ( is => 'ro', default => 0 );
has description         => ( is => 'ro', default => 'Rando cursed shit' );
has pattern             => ( is => 'ro', default => '^cursed ?' );
has function            => ( is => 'ro', default => sub { \&cmd_cursed } );
has usage               => ( is => 'ro', default => <<EOF
Usage: !cursed
EOF
);

my $debug = 1;
sub debug { my $msg = shift; say "[CURSED DEBUG] $msg" if $debug }

sub cmd_cursed {
    my ($self, $msg) = @_;

    my $channel = $msg->{'channel_id'};
    my $author  = $msg->{'author'};
    my $discord = $self->discord;
    my $pattern = $self->pattern;

    my $url = "https://www.reddit.com/r/cursedimages.json?sort=top&t=week&limit=100";
    debug("Fetching URL: $url");

    # Use Mojo::UserAgent for non-blocking fetch
    $self->discord->rest->ua->get_p($url)->then(sub {
        my $tx = shift;
        my $db = $self->db;

        unless ($tx->res->is_success) {
            debug("Failed to fetch cursed images: " . $tx->res->status_line);
            $discord->send_message($channel, "Sorry, I couldn't fetch a cursed image right now. Error: " . $tx->res->status_line);
            $discord->create_reaction($msg->{'channel_id'}, $msg->{'id'}, "🛑");
            return;
        }

        my $json;
        eval {
            $json = $tx->res->json;
        };
        if ($@ || !defined $json) { # Check for parsing errors or if json is undef
            debug("Failed to parse JSON response or JSON was undef: $@");
            $discord->send_message($channel, "Sorry, I received corrupted data from the cursed images source.");
            $discord->create_reaction($msg->{'channel_id'}, $msg->{'id'}, "🛑");
            return;
        }

        unless (ref $json eq 'HASH' && $json->{data} && ref $json->{data}{children} eq 'ARRAY') {
            debug("Invalid JSON structure received from Reddit API.");
            $discord->send_message($channel, "Sorry, I received invalid data from the cursed images source.");
            $discord->create_reaction($msg->{'channel_id'}, $msg->{'id'}, "🛑");
            return;
        }

        my @children_data = @{$json->{data}{children}};
        my @available_urls;
        for my $child (@children_data) {
            if (defined $child->{data}{url}) {
                push @available_urls, $child->{data}{url};
            }
        }

        unless (scalar @available_urls > 0) {
            debug("No valid URLs found in Reddit API response.");
            $discord->send_message($channel, "Couldn't find any cursed images. The subreddit might be empty or inaccessible.");
            $discord->create_reaction($msg->{'channel_id'}, $msg->{'id'}, "🛑");
            return;
        }

        my $cursed_to_send;
        my %cursed_seen = %{ $db->get('cursed') || {} };
        debug("Existing cursed images in DB: " . (scalar keys %cursed_seen));

        my $found_unique = 0;
        my $max_attempts = scalar(@available_urls) * 2;
        $max_attempts = 200 if $max_attempts > 200;
        $max_attempts = 100 if $max_attempts < 100;

        for (1 .. $max_attempts) {
            my $rand_idx = int(rand(scalar @available_urls));
            my $potential_cursed = $available_urls[$rand_idx];

            if (defined $potential_cursed && !exists $cursed_seen{$potential_cursed}) {
                $cursed_to_send = $potential_cursed;
                $cursed_seen{$cursed_to_send} = 1;
                $found_unique = 1;
                debug("Found new unique cursed image: $cursed_to_send");
                last;
            }
            debug("Attempt $_: '$potential_cursed' already seen or invalid. Retrying.");
        }

        unless ($found_unique) {
            $cursed_to_send = $available_urls[int(rand(scalar @available_urls))];
            $discord->send_message($channel, "I've run out of *new* cursed images! Here's a random one I've sent before. (History cleared)");
            $db->set('cursed', {});
            debug("No unique image found after $max_attempts tries, falling back to a random one: $cursed_to_send. History reset.");
        } else {
            $db->set('cursed', \%cursed_seen);
            debug("Saving updated cursed image list to DB.");
        }

        $discord->send_message($channel, $cursed_to_send);
        $discord->create_reaction($msg->{'channel_id'}, $msg->{'id'}, "🤖");
        debug("Message sent and reaction added.");

    })->catch(sub {
        my $err = shift;
        $self->log->error("[Cursed.pm] Unhandled promise error during cursed image fetch: $err");
        $discord->send_message($channel, "An unexpected error occurred while processing the cursed image request.");
        $discord->create_reaction($msg->{'channel_id'}, $msg->{'id'}, "🛑");
    });
}

1;