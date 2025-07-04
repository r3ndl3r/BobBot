package Command::Storage;
use feature 'say';
use utf8;

use Moo;
use strictures 2;
use namespace::clean;

use Component::DBI;
use Data::Dumper;
use JSON;

use Exporter qw(import);
our @EXPORT_OK = qw(cmd_storage);

has bot                 => ( is => 'ro' );
has discord             => ( is => 'lazy', builder => sub { shift->bot->discord } );
has log                 => ( is => 'lazy', builder => sub { shift->bot->log } );

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
    Lists all top-level storage keys currently in the database.
    EOF
);


my $debug = 0;
sub debug { my $msg = shift; say "[Storage DEBUG] $msg" if $debug }


sub cmd_storage {
    my ($self, $msg) = @_;
    debug("cmd_storage: Command received from user " . $msg->{author}{username} . ": " . $msg->{content});

    my $discord = $self->discord;
    my $pattern = $self->pattern;

    my $channel = $msg->{'channel_id'};
    my $args    = $msg->{'content'};
    $args       =~ s/$pattern//i;

    my $db = Component::DBI->new();

    my @parsed_args = split /\s+/, $args, 2;
    my $subcommand = lc shift @parsed_args;
    my $argument_str = shift @parsed_args;

    debug("cmd_storage: Parsed subcommand: '$subcommand', argument string: '" . ($argument_str // 'undef') . "'");

    if ($subcommand eq 'init') {
        unless (defined $argument_str && length $argument_str > 0) {
            $discord->send_message($channel, "Usage: `!storage init <key_name>`");
            $self->bot->react_error($channel, $msg->{'id'});
            debug("cmd_storage: Init command missing key name.");
            return;
        }
        $self->init_key($discord, $channel, $msg, $db, $argument_str);
    } elsif ($subcommand eq 'set') {
        # 'set' command expects a key_name followed by the value (can contain spaces)
        unless (defined $argument_str && $argument_str =~ /^(\S+)\s+(.+)$/s) { # Key and value
            $discord->send_message($channel, "Usage: `!storage set <key_name> <JSON_data_or_string>`");
            $self->bot->react_error($channel, $msg->{'id'});
            debug("cmd_storage: Set command missing key or value. Argument string: '" . ($argument_str // 'undef') . "'");
            return;
        }
        my ($key_name, $value_str) = ($1, $2);
        $self->set_value($discord, $channel, $msg, $db, $key_name, $value_str);
    } elsif ($subcommand eq 'show') {
        unless (defined $argument_str && length $argument_str > 0) {
            $discord->send_message($channel, "Usage: `!storage show <key_name>`");
            $self->bot->react_error($channel, $msg->{'id'});
            debug("cmd_storage: Show command missing key name.");
            return;
        }
        $self->show_value($discord, $channel, $msg, $db, $argument_str);
    } elsif ($subcommand eq 'delete' || $subcommand eq 'del') {
        unless (defined $argument_str && length $argument_str > 0) {
            $discord->send_message($channel, "Usage: `!storage delete <key_name>`");
            $self->bot->react_error($channel, $msg->{'id'});
            debug("cmd_storage: Delete command missing key name.");
            return;
        }
        $self->delete_key($discord, $channel, $msg, $db, $argument_str);
    } elsif ($subcommand eq 'list') {
        $self->list_keys($discord, $channel, $msg, $db);
    } else {
        # If no valid subcommand is recognized, display the general usage help.
        $discord->send_message($channel, $self->usage);
        $self->bot->react_error($channel, $msg->{'id'});
        debug("cmd_storage: Unknown subcommand: '$subcommand'. Displaying general usage.");
    }
}


# Helper function to initialize a new storage key.
sub init_key {
    my ($self, $discord, $channel, $msg, $db, $key_name) = @_;
    debug("init_key: Attempting to initialize key '$key_name'.");

    # Check if the key already exists to prevent accidental overwrites if not intended.
    if (defined $db->get($key_name)) {
        $discord->send_message($channel, "Storage: Key '**$key_name**' already exists. Use `!storage set` to modify its value.");
        $self->bot->react_error($channel, $msg->{'id'});
        debug("init_key: Key '$key_name' already exists. Aborting initialization.");
        return;
    }

    # Store an empty hash reference, which is a common way to initialize data structures in Perl.
    if ($db->set($key_name, {})) {
        $discord->send_message($channel, "Storage: Initialized key '**$key_name**'.");
        $self->bot->react_robot($channel, $msg->{'id'});
        debug("init_key: Successfully initialized key '$key_name'.");
    } else {
        $discord->send_message($channel, "Storage: Failed to initialize key '**$key_name**'.");
        $self->bot->react_error($channel, $msg->{'id'});
        debug("init_key: Failed to initialize key '$key_name'. Database error?");
    }
}


# Helper function to set (store) a value for a given storage key.
sub set_value {
    my ($self, $discord, $channel, $msg, $db, $key_name, $value_str) = @_;
    debug("set_value: Attempting to set value for key '$key_name' with string: '$value_str'.");

    my $data_to_store;
    my $json_error;

    # Attempt to decode the value string as JSON.
    eval {
        $data_to_store = JSON->new->decode($value_str);
    };
    if ($@) {
        $json_error = $@;
        # If JSON decoding fails, store the original string as plain text.
        $data_to_store = $value_str;
        debug("set_value: Value is not valid JSON. Storing as plain string. Error: $json_error");
    } else {
        debug("set_value: Value is valid JSON. Storing as Perl data structure.");
    }

    # Attempt to store the data in the database.
    if ($db->set($key_name, $data_to_store)) {
        $discord->send_message($channel, "Storage: Set value for key '**$key_name**'.");
        $self->bot->react_robot($channel, $msg->{'id'});
        debug("set_value: Successfully set value for key '$key_name'.");
    } else {
        $discord->send_message($channel, "Storage: Failed to set value for key '**$key_name**'.");
        $self->bot->react_error($channel, $msg->{'id'});
        debug("set_value: Failed to set value for key '$key_name'. Database error?");
    }
}


# Helper function to show (retrieve and display) the value of a storage key.
sub show_value {
    my ($self, $discord, $channel, $msg, $db, $key_name) = @_;
    debug("show_value: Attempting to retrieve and display value for key '$key_name'.");

    my $data = $db->get($key_name);

    # Check if the key exists in the database.
    unless (defined $data) {
        $discord->send_message($channel, "Storage: Key '**$key_name**' does not exist.");
        $self->bot->react_error($channel, $msg->{'id'});
        debug("show_value: Key '$key_name' does not exist.");
        return;
    }

    # Format the retrieved data using Data::Dumper for a readable representation.
    my $dump_output = Dumper($data);
    # Define a maximum length for the message to avoid Discord's character limit.
    my $max_length = 1900; # Max Discord message is 2000, leaving room for markdown.

    # Truncate the output if it's too long.
    if (length $dump_output > $max_length) {
        $dump_output = substr($dump_output, 0, $max_length) . "\n... (output truncated)";
        debug("show_value: Data for key '$key_name' was truncated as it exceeded Discord message limits.");
    }

    # Send the formatted output within a Perl code block.
    $discord->send_message($channel, "```perl\n$dump_output\n```");
    $self->bot->react_robot($channel, $msg->{'id'});
    debug("show_value: Successfully sent value for key '$key_name' to channel.");
}


# Helper function to delete a storage key.
sub delete_key {
    my ($self, $discord, $channel, $msg, $db, $key_name) = @_;
    debug("delete_key: Attempting to delete key '$key_name'.");

    # Check if the key exists before attempting deletion to provide better feedback.
    unless (defined $db->get($key_name)) {
        $discord->send_message($channel, "Storage: Key '**$key_name**' does not exist.");
        $self->bot->react_error($channel, $msg->{'id'});
        debug("delete_key: Key '$key_name' does not exist. Aborting deletion.");
        return;
    }

    # Attempt to delete the key from the database.
    if ($db->del($key_name)) {
        $discord->send_message($channel, "Storage: Deleted key '**$key_name**'.");
        $self->bot->react_robot($channel, $msg->{'id'});
        debug("delete_key: Successfully deleted key '$key_name'.");
    } else {
        $discord->send_message($channel, "Storage: Failed to delete key '**$key_name**'.");
        $self->bot->react_error($channel, $msg->{'id'});
        debug("delete_key: Failed to delete key '$key_name'. Database error?");
    }
}


# Helper function to list all top-level storage keys in the database.
sub list_keys {
    my ($self, $discord, $channel, $msg, $db) = @_;
    debug("list_keys: Retrieving all top-level storage keys from the database.");

    my $dbh = $db->{'dbh'};
    # Query the database to get all 'name' entries from the 'storage' table.
    my $sql = "SELECT name FROM storage";
    my $sth = $dbh->prepare($sql);
    $sth->execute();

    my @keys;
    # Fetch all key names.
    while (my ($key) = $sth->fetchrow_array()) {
        push @keys, $key;
    }

    if (@keys) {
        # Format the list of keys for display in Discord.
        my $key_list = join(', ', map { "`$_`" } sort @keys);
        $discord->send_message($channel, "Storage: Available keys: $key_list");
        debug("list_keys: Sent list of " . scalar(@keys) . " keys to channel.");
    } else {
        # Inform if no keys are found.
        $discord->send_message($channel, "Storage: No keys currently stored.");
        debug("list_keys: No keys found in the database.");
    }
    $self->bot->react_robot($channel, $msg->{'id'});
}


1;