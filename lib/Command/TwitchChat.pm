package Command::TwitchChat;
use feature 'say';
use utf8;

use Moo;
use strictures 2;
use namespace::clean;

use IO::Socket::INET;

use Exporter qw(import);
our @EXPORT_OK = qw(cmd_tc);

has bot           => ( is => 'ro' );
has discord       => ( is => 'lazy', builder => sub { shift->bot->discord } );
has log           => ( is => 'lazy', builder => sub { shift->bot->log } );
has name          => ( is => 'ro', default => 'TwitchChat' );
has access        => ( is => 'ro', default => 1 );
has description   => ( is => 'ro', default => 'Sends messages to Twitch chat.' );
has usage         => ( is => 'ro', default => 'Usage: !tc <twitch_channel> <message to send>' );
has pattern       => ( is => 'ro', default => sub { qr/^tc\b/i } );
has function      => ( is => 'ro', default => sub { \&cmd_tc } );


my $debug = 0; 
sub debug { my $msg = shift; say "[TwitchChat DEBUG] $msg" if $debug }


sub cmd_tc {
    my ($self, $msg) = @_;

    my $args = $msg->{'content'};
    $args =~ s/^tc\s*//i; 

    if ($args =~ /^(\w+)\s+(.+)$/) {
        my $target_channel  = $1;
        my $message_to_send = $2;

        # This regex finds all Discord custom emojis and replaces them with just their name.
        $message_to_send =~ s/<:(\w+):\d+>/$1/g;

        # Get the main Twitch command module object to access its functions.
        my $twitch_module = $self->bot->commands->{Twitch}{object};

        # Check if the main Twitch module is loaded.
        unless ($twitch_module) {
            $self->discord->send_message($msg->{'channel_id'}, "Error: The core Twitch module is not loaded. Cannot validate channel.");
            return;
        }

        # Use the validation function from Twitch.pm to check the channel name.
        unless ( $twitch_module->validChannel($target_channel) ) {
            $self->discord->send_message($msg->{'channel_id'}, "Error: '**$target_channel**' is not a valid Twitch channel.");
            return;
        }

        my $config = $self->bot->config->{twitch};

        $self->discord->create_reaction($msg->{'channel_id'}, $msg->{'id'}, "🤖");
        send_twitch_chat($config, $target_channel, $message_to_send);
        $self->discord->send_message($msg->{'channel_id'}, "Message sent to Twitch channel: `$target_channel`");

    } else {
        $self->discord->send_message($msg->{'channel_id'}, $self->usage);
    }
}


# Sends a single message to a specified Twitch channel's chat.
sub send_twitch_chat {
    my ($config, $streamer_channel, $message) = @_;
    debug("Attempting to send chat message to #$streamer_channel");

    # Establish a connection to Twitch's IRC server.
    my $socket = IO::Socket::INET->new(
        PeerAddr => 'irc.chat.twitch.tv',
        PeerPort => 6667,
        Proto    => 'tcp',
    );
    unless ($socket) {
        warn "[TwitchChat] Could not connect to Twitch IRC: $!";
        debug("-> ERROR: Could not connect to Twitch IRC.");
        return;
    }
    debug("-> Successfully connected to Twitch IRC.");

    my $channel_name = lc($streamer_channel);

    # Authenticate, join the channel, send the message, and disconnect.
    debug("-> Sending PASS");
    say $socket "PASS $config->{bot_oauth}";
    debug("-> Sending NICK: $config->{bot_username}");
    say $socket "NICK $config->{bot_username}";
    debug("-> Sending JOIN: #$channel_name");
    say $socket "JOIN #$channel_name";
    debug("-> Sending PRIVMSG: $message");
    say $socket "PRIVMSG #$channel_name :$message";

    close $socket;
    debug("-> Socket closed. Message sent.");
}

1;