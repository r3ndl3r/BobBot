package Command::Storage;
use feature 'say';
use utf8;

use Moo;
use strictures 2;
use namespace::clean;

use Data::Dumper;
use JSON;

use Exporter qw(import);
our @EXPORT_OK = qw(cmd_storage);

has bot                 => ( is => 'ro' );
has discord             => ( is => 'lazy', builder => sub { shift->bot->discord } );
has log                 => ( is => 'lazy', builder => sub { shift->bot->log } );
has db                  => ( is => 'ro', required => 1 );
has name                => ( is => 'ro', default => 'Storage' );
has access              => ( is => 'ro', default => 1 );
has description         => ( is => 'ro', default => 'A command to store and retrieve arbitrary data in the bot\'s database.' );
has pattern             => ( is => 'ro', default => '^(storage|store) ?' );
has function            => ( is => 'ro', default => sub { \&cmd_storage } );
has usage               => ( is => 'ro', default => <<~'EOF'
    **Storage Command Help**

    This command allows the bot owner to store and retrieve arbitrary data in the bot's database.

    `!storage init <key_name>`
    Initializes a new storage key in the database with an empty data structure (a hash).
    *Example:* `!storage init my_settings`

    `!storage set <key_name> <JSON_data_or_string>`
    Stores data under a specified key. The data can be a plain string or a JSON object.
    If it's JSON, it will be stored as a Perl hash/arrayref.
    *Example:* `!storage set user_data {"user_id":123,"name":"Alice"}`
    *Example:* `!storage set message_of_day "Hello world!"`

    `!storage show <key_name>`
    Retrieves and displays the content stored under a specified key.
    *Example:* `!storage show my_settings`

    `!storage delete <key_name>`
    Deletes a specified storage key and its associated data from the database.
    *Example:* `!storage delete old_data`

    `!storage list`
    Lists all top-level storage keys currently in the database as clickable buttons.
    EOF
);

# This on_message handler intercepts all button clicks to see if they are for this module.
has on_message => ( is => 'ro', default => sub {
    my $self = shift;
    $self->discord->gw->on('INTERACTION_CREATE' => sub {
        my ($gw, $interaction) = @_;
        # Ensure it's a button click with a custom_id before proceeding.
        return unless (ref $interaction->{data} eq 'HASH' && $interaction->{data}{custom_id});

        my $custom_id = $interaction->{data}{custom_id};
        my $channel_id = $interaction->{channel_id};

        # Check if the button click is for showing a storage key's value.
        if ($custom_id =~ /^storage_show_key_(.+)$/) {
            my $key_name = $1;
            $self->debug("Button clicked to show storage key: $key_name");

            # Defer the response immediately. This tells Discord "I got the click"
            # and prevents an "interaction failed" error, giving the bot time to process.
            $self->discord->interaction_response($interaction->{id}, $interaction->{token}, { type => 5 });

            # Create a mock message object. This isn't a real message, but it allows
            # us to call the existing show_value function without rewriting it.
            my $mock_msg = {
                channel_id => $channel_id,
                author     => $interaction->{member}{user},
                id         => $interaction->{id}
            };

            # Call the existing show_value function to post the data publicly.
            $self->show_value($self->discord, $channel_id, $mock_msg, $key_name);
        }
    });
});


sub cmd_storage {
    my ($self, $msg) = @_;
    $self->debug("cmd_storage: Command received from user " . $msg->{author}{username} . ": " . $msg->{content});

    my $discord = $self->discord;
    my $pattern = $self->pattern;

    my $channel = $msg->{'channel_id'};
    my $args    = $msg->{'content'};
    $args       =~ s/$pattern//i; # Remove command trigger

    # Subcommand parsing: Split into subcommand and the rest as argument string
    my @parsed_args = split /\s+/, $args, 2;
    my $subcommand = lc shift @parsed_args;
    my $argument_str = shift @parsed_args; # This will contain the rest of the arguments for the subcommand

    $self->debug("cmd_storage: Parsed subcommand: '$subcommand', argument string: '" . ($argument_str // 'undef') . "'");

    if ($subcommand eq 'init') {
        unless (defined $argument_str && length $argument_str > 0) {
            $discord->send_message($channel, "Usage: `!storage init <key_name>`");
            $self->bot->react_error($channel, $msg->{'id'});
            return;
        }
        $self->init_key($discord, $channel, $msg, $argument_str);
    } elsif ($subcommand eq 'set') {
        unless (defined $argument_str && $argument_str =~ /^(\S+)\s+(.+)$/s) { # Key and value
            $discord->send_message($channel, "Usage: `!storage set <key_name> <JSON_data_or_string>`");
            $self->bot->react_error($channel, $msg->{'id'});
            return;
        }
        my ($key_name, $value_str) = ($1, $2);
        $self->set_value($discord, $channel, $msg, $key_name, $value_str);
    } elsif ($subcommand eq 'show') {
        unless (defined $argument_str && length $argument_str > 0) {
            $discord->send_message($channel, "Usage: `!storage show <key_name>`");
            $self->bot->react_error($channel, $msg->{'id'});
            return;
        }
        $self->show_value($discord, $channel, $msg, $argument_str);
    } elsif ($subcommand eq 'delete' || $subcommand eq 'del') {
        unless (defined $argument_str && length $argument_str > 0) {
            $discord->send_message($channel, "Usage: `!storage delete <key_name>`");
            $self->bot->react_error($channel, $msg->{'id'});
            return;
        }
        $self->delete_key($discord, $channel, $msg, $argument_str);
    } elsif ($subcommand eq 'list') {
        $self->list_keys($discord, $channel, $msg);
    } else {
        $discord->send_message($channel, $self->usage);
        $self->bot->react_error($channel, $msg->{'id'});
    }
}

# Helper function to initialize a new storage key.
sub init_key {
    my ($self, $discord, $channel, $msg, $key_name) = @_;
    if ($self->db->get($key_name)) {
        $discord->send_message($channel, "Storage: Key '**$key_name**' already exists.");
        $self->bot->react_error($channel, $msg->{'id'});
        return;
    }
    if ($self->db->set($key_name, {})) {
        $discord->send_message($channel, "Storage: Initialized key '**$key_name**'.");
        $self->bot->react_robot($channel, $msg->{'id'});
    } else {
        $discord->send_message($channel, "Storage: Failed to initialize key '**$key_name**'.");
        $self->bot->react_error($channel, $msg->{'id'});
    }
}

# Helper function to set (store) a value for a given storage key.
sub set_value {
    my ($self, $discord, $channel, $msg, $key_name, $value_str) = @_;
    my $data_to_store;
    eval { $data_to_store = JSON->new->decode($value_str); };
    if ($@) { $data_to_store = $value_str; }

    if ($self->db->set($key_name, $data_to_store)) {
        $discord->send_message($channel, "Storage: Set value for key '**$key_name**'.");
        $self->bot->react_robot($channel, $msg->{'id'});
    } else {
        $discord->send_message($channel, "Storage: Failed to set value for key '**$key_name**'.");
        $self->bot->react_error($channel, $msg->{'id'});
    }
}

# Helper function to show (retrieve and display) the value of a storage key.
sub show_value {
    my ($self, $discord, $channel, $msg, $key_name) = @_;
    $self->debug("show_value: Attempting to retrieve and display value for key '$key_name'.");

    my $data = $self->db->get($key_name);

    unless (defined $data) {
        $discord->send_message($channel, "Storage: Key '**$key_name**' does not exist.");
        # Only react to the original command message, not a button click interaction
        if (ref($msg) eq 'HASH' && $msg->{content}) {
             $self->bot->react_error($channel, $msg->{'id'});
        }
        return;
    }

    my $dump_output = Dumper($data);
    
    $self->bot->send_long_message($channel, $dump_output)->then(sub {
        if (ref($msg) eq 'HASH' && $msg->{content}) {
            $self->bot->react_robot($channel, $msg->{'id'});
        }
        $self->debug("show_value: Successfully sent value for key '$key_name' to channel.");
    })->catch(sub {
        my $err = shift;
        $self->log->error("Failed to send long message for key '$key_name': $err");
        if (ref($msg) eq 'HASH' && $msg->{content}) {
            $self->bot->react_error($channel, $msg->{'id'});
        }
    });
}

# Helper function to delete a storage key.
sub delete_key {
    my ($self, $discord, $channel, $msg, $key_name) = @_;
    unless (defined $self->db->get($key_name)) {
        $discord->send_message($channel, "Storage: Key '**$key_name**' does not exist.");
        $self->bot->react_error($channel, $msg->{'id'});
        return;
    }

    if ($self->db->del($key_name)) {
        $discord->send_message($channel, "Storage: Deleted key '**$key_name**'.");
        $self->bot->react_robot($channel, $msg->{'id'});
    } else {
        $discord->send_message($channel, "Storage: Failed to delete key '**$key_name**'.");
        $self->bot->react_error($channel, $msg->{'id'});
    }
}

# Helper function to list all top-level storage keys as interactive buttons.
sub list_keys {
    my ($self, $discord, $channel, $msg) = @_;
    $self->debug("list_keys: Retrieving all top-level storage keys to display as buttons.");

    my $dbh = $self->db->{'dbh'};
    my $sql = "SELECT name FROM storage";
    my $sth = $dbh->prepare($sql);
    $sth->execute();

    my @keys;
    while (my ($key) = $sth->fetchrow_array()) {
        push @keys, $key;
    }

    if (!@keys) {
        $discord->send_message($channel, "Storage: No keys currently stored.");
        $self->bot->react_robot($channel, $msg->{'id'});
        return;
    }

    @keys = sort { lc $a cmp lc $b } @keys;

    my @components;
    my @current_row;

    # Discord allows a maximum of 5 rows, each with a maximum of 5 buttons.
    # We will send a max of 25 keys as buttons.
    my $key_limit = @keys > 25 ? 25 : @keys;

    for my $i (0 .. $key_limit - 1) {
        my $key = $keys[$i];

        # Button labels have a max length of 80 characters.
        my $label = (length $key > 80) ? substr($key, 0, 77) . '...' : $key;

        push @current_row, {
            type      => 2, # Button component
            style     => 2, # Secondary style (grey)
            label     => $label,
            custom_id => "storage_show_key_$key"
        };

        # If the current row is full (5 buttons) or this is the last key,
        # push the row to the main components array and reset the row.
        if (scalar @current_row == 5 || $i == $key_limit - 1) {
            # This is the corrected line:
            push @components, { type => 1, components => [ @current_row ] };
            @current_row = ();
        }
    }

    my $message_content = "Storage: Available keys. Click a button to view its value.";
    if (scalar @keys > 25) {
        $message_content = "Storage: Showing the first 25 of " . scalar(@keys) . " available keys.";
    }

    my $payload = {
        content    => $message_content,
        components => \@components
    };

    $discord->send_message($channel, $payload, sub {
        my $response = shift;
        if (ref $response eq 'HASH' && exists $response->{code}) {
            $self->log->error("Error sending storage list message: " . Dumper($response));
            $discord->send_message($channel, "Error: Could not display the key list. Check the bot's logs for details.");
            $self->bot->react_error($channel, $msg->{'id'});
        } else {
            $self->bot->react_robot($channel, $msg->{'id'});
        }
    });
}

1;