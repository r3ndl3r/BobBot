package Command::Oz;
use feature 'say';
use utf8;

use Moo;
use strictures 2;
use XML::Simple;
use LWP::UserAgent;
use HTML::TreeBuilder;
use HTML::FormatText;
use Mojo::Date;

use namespace::clean;

use Exporter qw(import);
our @EXPORT_OK = qw(cmd_oz);

has bot                 => ( is => 'ro' );
has discord             => ( is => 'lazy', builder => sub { shift->bot->discord } );
has log                 => ( is => 'lazy', builder => sub { shift->bot->log } );
has db                  => ( is => 'ro', required => 1 );
has name                => ( is => 'ro', default => 'oz' );
has access              => ( is => 'ro', default => 1 );
has timer_seconds       => ( is => 'ro', default => 600 );
has description         => ( is => 'ro', default => 'OzBargains keyword alert system.' );
has pattern             => ( is => 'ro', default => '^oz ?' );
has function            => ( is => 'ro', default => sub { \&cmd_oz } );
has usage               => ( is => 'ro', default => <<~'EOF'
    **OzBargains Keyword Alert Command Help**

    This command allows you to set up keyword alerts for new deals posted on OzBargains.
    When a new deal matches one of your keywords, the bot can alert you.

    `!oz add <keyword>`
    Adds a new keyword to the list of terms to watch for in OzBargains deal titles.
    Keyword matching is case-insensitive.
    *Example:* `!oz add PlayStation`
    *Example:* `!oz add monitor deals`

    `!oz delete <keyword>` (or `!oz del <keyword>`)
    Removes an existing keyword from your watch list.
    *Example:* `!oz delete PS5`

    `!oz list`
    Displays all keywords currently being monitored.

    `!oz update`
    Manually triggers an immediate check for new OzBargains deals based on your keywords.
    (The bot also checks periodically in the background).

    `!oz help`
    Displays this detailed help message.
    EOF
);



has timer_sub => ( is => 'ro', default => sub
    {
        my $self = shift;
        Mojo::IOLoop->recurring( $self->timer_seconds => sub { $self->check_ozbargains } )
    }
);


my $debug = 0;
sub debug { my $msg = shift; say "[OZ DEBUG] $msg" if $debug }

# Helper function to add or delete keywords
sub matchKeyword {
    my ($self, $mode, $keyword, $discord, $channel, $msg) = @_;
    debug("matchKeyword: Mode: '$mode', Keyword: '$keyword' for user " . $msg->{'author'}{'username'});

    # Ensure the 'oz' storage key exists, initialize if not.
    unless ($self->db->get('oz')) {
        $self->db->set('oz', {});
        debug("matchKeyword: Initialized 'oz' storage key.");
    }

    my %oz = %{ $self->db->get('oz') }; # Retrieve current keywords

    if ($mode eq 'add') {
        # Check if keyword already exists for adding
        if (exists $oz{lc $keyword}) {
            $discord->send_message($channel, "OZ: That keyword already exists: '**$keyword**'.");
            $self->bot->react_error($channel, $msg->{'id'});
            debug("matchKeyword: Add failed, keyword '$keyword' already exists.");
            return;
        }

        # Add new keyword
        $oz{lc $keyword} = 1; # Store in lowercase for case-insensitive matching
        $self->db->set('oz', \%oz);
        $discord->send_message($channel, "OZ: Added new keyword: '**$keyword**'.");
        $self->bot->react_robot($channel, $msg->{'id'});
        debug("matchKeyword: Successfully added keyword '$keyword'.");
        return;
    }

    if ($mode eq 'del') {
        # Check if keyword exists for deletion
        unless (exists $oz{lc $keyword}) {
            $discord->send_message($channel, "OZ: That keyword doesn't exist: '**$keyword**'.");
            $self->bot->react_error($channel, $msg->{'id'});
            debug("matchKeyword: Delete failed, keyword '$keyword' does not exist.");
            return;
        }

        # Delete keyword
        delete $oz{lc $keyword};
        $self->db->set('oz', \%oz);
        $discord->send_message($channel, "OZ: Deleted keyword: '**$keyword**'.");
        $self->bot->react_robot($channel, $msg->{'id'});
        debug("matchKeyword: Successfully deleted keyword '$keyword'.");
        return;
    }
    debug("matchKeyword: Invalid mode received: '$mode'.");
}


sub cmd_oz {
    my ($self, $msg) = @_;
    my $discord = $self->discord;
    my $channel = $msg->{'channel_id'};
    my $pattern = $self->pattern;
    my $args    = $msg->{'content'};
    my $msg_id  = $msg->{'id'};

    # Remove the command trigger from the arguments.
    $args =~ s/$pattern//i;
    $args = lc $args; # Convert args to lowercase for consistent subcommand parsing.
    debug("cmd_oz: Received command with args: '$args' from user " . $msg->{author}{username});

    my %oz = %{ $self->db->get('oz') || {} }; # Get current keywords (empty hash if none)

    # Handle keyword management subcommands
    if ($args =~ /^(add|del(?:ete)?)\s+(.+)$/i) {
        my ($mode, $keyword) = (lc $1, $2);
        # Remove trailing/leading spaces from keyword if present
        $keyword =~ s/^\s+|\s+$//g;
        debug("cmd_oz: Identified keyword management command: mode '$mode', keyword '$keyword'.");
        $self->matchKeyword($mode, $keyword, $discord, $channel, $msg);
        return; # Exit after handling subcommand
    }

    # Handle list subcommand
    if ($args eq 'list') {
        debug("cmd_oz: Identified 'list' subcommand.");
        if (scalar keys %oz) {
            $discord->send_message($channel, "OZ: Matching keywords - " . join ', ', map { "[ **$_** ]" } sort keys %oz );
            debug("cmd_oz: Sent list of " . (scalar keys %oz) . " keywords.");
        } else {
            $discord->send_message($channel, "OZ: No keywords currently set. Use `!oz add <keyword>` to add some.");
            debug("cmd_oz: No keywords to list.");
        }
        $self->bot->react_robot($channel, $msg_id);
        return;
    }

    # Handle update subcommand
    if ($args eq 'update') {
        debug("cmd_oz: Identified 'update' subcommand. Triggering manual check.");
        $discord->send_message($channel, "OZ: Manually checking for new deals...");
        $self->check_ozbargains($msg); # Pass $msg so we can react to it after check
        return;
    }

    # Handle help subcommand
    if ($args eq 'help') {
        debug("cmd_oz: Identified 'help' subcommand. Displaying usage.");
        $discord->send_message($channel, $self->usage);
        $self->bot->react_robot($channel, $msg_id);
        return;
    }

    # If no specific subcommand was matched, assume it's a general trigger (e.g., just "!oz")
    # and trigger a check, informing the user about valid commands.
    debug("cmd_oz: No specific subcommand matched. Displaying usage and checking for new deals.");
    $discord->send_message($channel, "OZ: Unknown command. " . $self->usage);
    $self->bot->react_error($channel, $msg_id);
    # Even if unknown command, proceed to check for deals if no manual command was passed.
    # $self->check_ozbargains($msg); # This would check every time, maybe not desired.
}

# This is the main function to fetch and process OzBargains deals,
# called by the timer or the 'update' command.
sub check_ozbargains {
    my ($self, $msg) = @_; # $msg will be defined if called manually by user.
    debug("check_ozbargains: Starting check for new OzBargains deals.");

    my $discord = $self->discord;
    my $config  = $self->{'bot'}{'config'}{'oz'};
    my $dbh     = $self->db->{'dbh'}; # Access the DBI handle from the shared instance
    my %oz_keywords  = %{ $self->db->get('oz') || {} }; # Keywords for alerting

    unless ($config && $config->{'url'} && $config->{'channel'}) {
        debug("check_ozbargains: OzBargains URL or channel not configured in config.ini.");
        return;
    }

    my $ua = LWP::UserAgent->new();
    $ua->agent('Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/101.0.4951.54 Safari/537.36');
    $ua->timeout(30); # Set a timeout for the request

    my $res = $ua->get($config->{'url'});

    unless ($res->is_success) {
        debug("check_ozbargains: Failed to fetch OzBargains feed: " . $res->status_line);
        if (defined $msg && exists $msg->{'id'}) {
             $discord->send_message($msg->{'channel_id'}, "OZ: Failed to retrieve deals from OzBargains. Please try again later.");
             $self->bot->react_error($msg->{'channel_id'}, $msg->{'id'});
        }
        return;
    }

    my $xml;
    eval {
        $xml = XMLin($res->content, KeepRoot => 1); # KeepRoot helps with single-item feeds
    };
    if ($@ || !defined $xml || !exists $xml->{rss}{channel}{item}) {
        debug("check_ozbargains: Failed to parse XML or invalid structure: $@");
        if (defined $msg && exists $msg->{'id'}) {
             $discord->send_message($msg->{'channel_id'}, "OZ: Failed to parse OzBargains feed data.");
             $self->bot->react_error($msg->{'channel_id'}, $msg->{'id'});
        }
        return;
    }

    my @items = ref $xml->{rss}{channel}{item} eq 'ARRAY' ? @{$xml->{rss}{channel}{item}} : [$xml->{rss}{channel}{item}];
    debug("check_ozbargains: Fetched " . scalar(@items) . " items from feed.");

    my $new_deals_found = 0;
    for my $item (@items) {
        # Check if this deal has already been processed (based on its link)
        my $sql = "SELECT link FROM oz WHERE link = ?"; # Changed table name to avoid conflict with 'oz' keywords
        my $sth = $dbh->prepare($sql);
        $sth->execute($item->{'link'});

        if ($sth->fetchrow_array()) {
            debug("check_ozbargains: Deal already logged: " . $item->{'link'});
            next; # Skip already processed deals
        }

        $new_deals_found = 1;
        debug("check_ozbargains: Found new deal: " . $item->{'title'});

        my $html = HTML::TreeBuilder->new();
        $html->parse($item->{'description'} // ''); # Handle potentially missing description
        my $formatter = HTML::FormatText->new(leftmargin => 0, rightmargin => 500);

        # Construct the Discord embed for the deal.
        my $embed_description = $formatter->format($html) // 'No description available.';
        # Discord embed description max length is 4096. Truncate if necessary.
        $embed_description = substr($embed_description, 0, 4000) . '...' if length $embed_description > 4000;


        my $embed = {
            'embeds' => [
                {
                    'author' => {
                        'name'     => 'OzBargains',
                        'url'      => 'https://www.ozbargain.com.au/',
                        'icon_url' => 'https://files.delvu.com/images/ozbargain/logo/Square%20Flat.png',
                    },
                    'thumbnail' => {
                        'url'   => $item->{'media:thumbnail'}{'url'} // undef, # Use undef if not available
                    },
                    'title'       => $item->{'title'},
                    'description' => $embed_description,
                    'url'         => $item->{'link'}, # Direct link to the deal on OzBargains

                    'fields' => [
                        {
                            'name'  => 'Deal Link:',
                            'value' => $item->{'ozb:meta'}{'url'} // 'N/A', # Specific deal URL
                        },
                    ],
                    'color'       => 0x51A810, # OzBargains green color
                    'timestamp'   => (defined $item->{'pubDate'} ? (Mojo::Date->new($item->{'pubDate'}))->to_datetime : undef),
                    'footer' => {
                        'text' => 'Powered by OzBargains',
                        'icon_url' => 'https://files.delvu.com/images/ozbargain/logo/Square%20Flat.png',
                    }
                }
            ]
        };

        my @alerted_users;
        # Check if the deal title matches any of the stored keywords for owner alerts.
        for my $keyword (keys %oz_keywords) {
            if (lc($item->{'title'}) =~ lc($keyword)) { # Case-insensitive match
                push @alerted_users, $self->{'bot'}{'config'}{'discord'}{'owner_id'}; # Only owner is configured for DM alerts
                debug("check_ozbargains: Deal title matched keyword '$keyword'. Alerting owner.");
                last; # Alert only once per deal for owner
            }
        }

        # Add an "Alerting" field to the embed if any users are being DM alerted.
        if (@alerted_users) {
            # Ensure unique user IDs if multiple keywords matched
            my %seen_users;
            @alerted_users = grep { !$seen_users{$_}++ } @alerted_users;
            push @{ $embed->{'embeds'}[0]{'fields'} }, { 'name'  => 'Alerting:', 'value' => join ' ', map { '<@' . $_ . '>' } @alerted_users };

            # Send DMs to alerted users (currently only bot owner)
            for my $user_id (@alerted_users) {
                $discord->send_dm($user_id, $embed);
                debug("check_ozbargains: Sent DM alert for new deal to user ID: $user_id.");
            }
        }

        # Send the deal embed to the main configured channel.
        $discord->send_message($config->{'channel'}, $embed,
            sub {
                my $sent_msg = shift;
                if (ref $sent_msg eq 'HASH' && $sent_msg->{'id'}) {
                    # Log the deal link to prevent re-processing it.
                    my $sql_insert = "INSERT INTO oz (link) VALUES(?)"; # Changed table name
                    my $sth_insert = $dbh->prepare($sql_insert);
                    $sth_insert->execute($item->{'link'});
                    debug("check_ozbargains: Logged deal link: " . $item->{'link'} . " after sending to channel.");
                } else {
                    debug("check_ozbargains: Failed to send deal message for '" . $item->{'title'} . "': " . Dumper($sent_msg));
                }
            }
        );
    }
    
    # React to the original message if this check was manually triggered by a user command.
    if (defined $msg && exists $msg->{'id'}) {
        if ($new_deals_found) {
            $discord->send_message($msg->{'channel_id'}, "OZ: Found and posted new deals!");
            $self->bot->react_robot($msg->{'channel_id'}, $msg->{'id'});
        } else {
            $discord->send_message($msg->{'channel_id'}, "OZ: No new deals found matching your keywords.");
            $self->bot->react_robot($msg->{'channel_id'}, $msg->{'id'});
        }
    }
    debug("check_ozbargains: Finished check for new OzBargains deals.");
}

1;
