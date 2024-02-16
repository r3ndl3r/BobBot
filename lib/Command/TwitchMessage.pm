# lib/Command/TwitchMessage.pm

package Command::TwitchMessage;
use feature 'say';
use utf8;

use Moo;
use strictures 2;
use namespace::clean;

use Mojo::UserAgent;
use IO::Socket::SSL;

use Simple::Config;

use Exporter qw(import);
our @EXPORT_OK = qw(cmd_twitch);

has bot          => ( is => 'ro' );
has discord      => ( is => 'lazy', builder => sub { shift->bot->discord } );
has log          => ( is => 'lazy', builder => sub { shift->bot->log } );
has name         => ( is => 'ro', default => 'TwitchMessage' );
has access       => ( is => 'ro', default => 0 );
has description  => ( is => 'ro', default => 'Send messages to a Twitch streamer\'s chat.' );
has pattern      => ( is => 'ro', default => '^twitch ?' );
has function     => ( is => 'ro', default => sub { \&cmd_twitch } );
has usage        => ( is => 'ro', default => "Usage: !twitch [streamer] [message]" );

sub cmd_twitch {
    my ($self, $msg) = @_;

    my $pattern = $self->pattern;
    my $args    = $msg->{'content'};
    $args       =~ s/$pattern//i;

    my ($streamer, $message) = split /\s+/, $args, 2;

    unless ($streamer && $message) {
        $self->discord->send_message($msg->{'channel_id'}, $self->usage);
        return;
    }

    my $config = Simple::Config->new(file => 'config/config.json');
    my $twitch_token = $config->get('twitch_token');
    my $twitch_channel = $config->get('twitch_channel');

    my $ua = Mojo::UserAgent->new;
    $ua->post("https://api.twitch.tv/kraken/chat/$twitch_channel", {
        'Authorization' => "OAuth $twitch_token",
        'Client-ID'      => 'your_client_id',
        'Accept'         => 'application/vnd.twitchtv.v5+json',
        'Content-Type'   => 'application/json'
    } => json => { 'message' => $message });

    $self->discord->send_message($msg->{'channel_id'}, "Message sent to $streamer's Twitch chat.");
}

1;
