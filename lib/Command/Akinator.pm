package Command::Akinator;
use feature 'say';
use utf8;

use Moo;
use strictures 2;
use namespace::clean;

use JSON;
use Mojo::Promise;
use Mojo::IOLoop;
use URI::Escape qw(uri_escape_utf8);
use HTML::Entities qw(decode_entities);
use Data::Dumper;
use Mojo::UserAgent;

use Exporter qw(import);
our @EXPORT_OK = qw(cmd_akinator);

has bot                 => ( is => 'ro' );
has discord             => ( is => 'lazy', builder => sub { shift->bot->discord } );
has log                 => ( is => 'lazy', builder => sub { shift->bot->log } );
has db                  => ( is => 'ro', required => 1 );
has name                => ( is => 'ro', default => 'Akinator' );
has access              => ( is => 'ro', default => 0 ); # 0 = Public
has description         => ( is => 'ro', default => 'Plays a game of Akinator.' );
has pattern             => ( is => 'ro', default => sub { qr/^aki(nator)?\b/i } );
has function            => ( is => 'ro', default => sub { \&cmd_akinator } );
has usage               => ( is => 'ro', default => <<~'EOF'
    **Akinator Command Help**

    This command starts a game of Akinator, the web genie who guesses the character you're thinking of.

    `!akinator start`
    Starts a new game in the channel.

    `!akinator stop`
    Ends the current game in the channel.
    EOF
);


# This hash will hold the state for any active games, keyed by the Discord channel ID.
# This keeps each game separate and channel-specific.
my %active_games;

# Use a dedicated Mojo::UserAgent instance to set a browser-like user agent.
# Crucial for bypassing Akinator's Cloudflare protection, which would otherwise block requests.
my $aki_ua = Mojo::UserAgent->new;
$aki_ua->transactor->name('Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/108.0.0.0 Safari/537.36');


has on_message => ( is => 'ro', default => sub {
    my $self = shift;

    $self->discord->gw->on('INTERACTION_CREATE' => sub {
        my ($gw, $interaction) = @_;
        # Only care about button clicks with specific custom_id format.
        return unless (ref $interaction->{data} eq 'HASH' && $interaction->{data}{custom_id});
        my $custom_id = $interaction->{data}{custom_id};

        # Acknowledge the interaction immediately to prevent a "This interaction failed" message on Discord.
        # Type 6 means update the original message later (a deferred update).
        $self->discord->interaction_response($interaction->{id}, $interaction->{token}, { type => 6 });

        # If the button ID matches answer format (e.g., "akinator_answer_0"), handle it.
        if ($custom_id =~ /^akinator_answer_(\d)$/) {
            $self->handle_answer($interaction, $1);
        
        # New handlers for the guess confirmation buttons.
        } elsif ($custom_id eq 'akinator_guess_yes') {
            $self->_confirm_guess($interaction);
        } elsif ($custom_id eq 'akinator_guess_no') {
            $self->_reject_guess($interaction);
        }
    });
});


sub cmd_akinator {
    my ($self, $msg) = @_;
    my $args_str = $msg->{'content'};
       $args_str =~ s/^aki(nator)?\s*//i;
    my @args = split /\s+/, $args_str;
    my $subcommand = lc(shift @args || 'help'); # Default to 'help' if no subcommand

    $self->debug("Routing subcommand: '$subcommand'");

    if ($subcommand eq 'start') {
        $self->start_game($msg);
    } elsif ($subcommand eq 'stop') {
        $self->stop_game($msg);
    } else {
        $self->discord->send_message($msg->{'channel_id'}, $self->usage);
    }
}

# Starts a new game session by getting session details from the Akinator website.
sub start_game {
    my ($self, $msg) = @_;
    my $channel_id = $msg->{'channel_id'};

    # Prevent starting a new game if one is already running in the same channel.
    if (exists $active_games{$channel_id}) {
        $self->discord->send_message($channel_id, "A game is already in progress! Use `!akinator stop` to end it.");
        return;
    }

    $self->discord->send_message($channel_id, "Starting a new game of Akinator...");

    my $url = "https://en.akinator.com/game";
    my $form_data = { sid => 1, cm => 'false' }; # Theme=Characters, ChildMode=false

    $self->debug("Starting game by POSTing to session page: $url");

    $aki_ua->post_p($url => form => $form_data)->then(sub {
        my $tx = shift;
        # Handle failed HTTP requests.
        unless ($tx->res->is_success) {
            $self->log->error("Akinator page scrape failed: " . Dumper($tx));
            $self->discord->send_message($channel_id, "Sorry, I couldn't connect to the Akinator servers to start a game.");
            return;
        }

        # Parse the necessary session data from the returned HTML using regex.
        my $html = $tx->res->body;
        my ($session_id)  = $html =~ /#session'\).val\('(.+?)'\)/;
        my ($signature)   = $html =~ /#signature'\).val\('(.+?)'\)/;
        # This 'identifiant' is required for the final "choice" API call when a guess is confirmed.
        my ($identifiant) = $html =~ /#identifiant'\).val\('(.+?)'\)/;
        my ($question)    = $html =~ /<p class="question-text" id="question-label">(.+)<\/p>/;
        
        # If any of these critical pieces of data are missing can't proceed.
        unless ($session_id && $signature && $identifiant && $question) {
            $self->log->error("Failed to parse session data from Akinator HTML response." . Dumper($html));
            $self->discord->send_message($channel_id, "Sorry, I received an invalid response from the Akinator servers. This may be due to Cloudflare protection.");
            return;
        }

        # Store all the necessary game state information in global hash.
        $active_games{$channel_id} = {
            session               => $session_id,
            signature             => $signature,
            identifiant           => $identifiant,
            question              => decode_entities($question),
            step                  => 0,
            progression           => 0,
            language              => 'en',
            theme                 => 'c', # 'c' for Characters
            child_mode            => 'false',
            step_last_proposition => "" # Required by the API on subsequent calls
        };

        $self->debug("Game started successfully for channel $channel_id. Session: $session_id");
        # Display the first question to the user.
        $self->_send_question($channel_id);

    })->catch(sub {
        my $err = shift;
        $self->log->error("An error occurred during game start: " . Dumper($err));
        $self->discord->send_message($channel_id, "An unexpected error occurred while starting the game. Please check the logs for details.");
    });
}

# This handles the user's answer from a button click and calls the Akinator API.
sub handle_answer {
    my ($self, $interaction, $answer) = @_;
    my $channel_id = $interaction->{'channel_id'};
    my $message_id = $interaction->{'message'}{id};

    # Ensure the button click corresponds to the current active game question to prevent old button clicks from affecting a new game.
    return unless (exists $active_games{$channel_id} && $active_games{$channel_id}{message_id} eq $message_id);

    # Disable the buttons on the question now that it has been answered.
    $self->_disable_buttons($channel_id, $message_id);
    my $game = $active_games{$channel_id};

    $self->debug("Current game state before answering: " . Dumper($game));

    # A sanity check to ensure the game state hasn't been corrupted.
    unless (defined $game->{theme}) {
        $self->log->error("FATAL: Game state for channel $channel_id is missing 'theme'. State: " . Dumper($game));
        return $self->stop_game({ channel_id => $channel_id }, "A critical error occurred (game state corrupted). The game has been stopped.");
    }

    my %theme_ids = ( c => 1, a => 14, o => 2 ); # Theme IDs for Characters, Animals, Objects
    my $url = "https://en.akinator.com/answer";
    
    # This is the payload for the main API call to submit an answer. All fields are required.
    my $form_data = {
        session               => $game->{session},
        signature             => $game->{signature},
        step                  => $game->{step},
        answer                => $answer,
        progression           => $game->{progression},
        sid                   => $theme_ids{$game->{theme}},
        cm                    => $game->{child_mode},
        step_last_proposition => $game->{step_last_proposition}
    };

    $self->debug("Submitting answer API call. Form data: " . Dumper($form_data));

    $aki_ua->post_p($url => form => $form_data)->then(sub {
        my $tx = shift;
        # Pass the JSON response to our new centralized processor.
        $self->_process_api_response($channel_id, $tx->res->json);
    })->catch(sub {
        my $err = shift;
        my $error_details = defined($err) ? Dumper($err) : "Promise rejected with an undefined error.";
        $self->log->error("An error occurred while handling answer: " . $error_details);
        $self->stop_game({ channel_id => $channel_id }, "An unexpected error occurred. Please check the logs for details.");
    });
}

# Constructs and sends the question embed with answer buttons to Discord.
sub _send_question {
    my ($self, $channel_id) = @_;
    my $game = $active_games{$channel_id};

    my $embed = {
        embeds => [{
            color => 3447003, # Blue
            title => "Question #" . ($game->{step} + 1),
            description => "**$game->{question}**",
            footer => { text => "Progression: " . sprintf("%.2f", $game->{progression}) . "%" }
        }],
        components => [{
            type => 1, # Action Row
            components => [
                { type => 2, style => 3, label => "Yes",           custom_id => "akinator_answer_0" },
                { type => 2, style => 4, label => "No",            custom_id => "akinator_answer_1" },
                { type => 2, style => 2, label => "Don't Know",    custom_id => "akinator_answer_2" },
                { type => 2, style => 1, label => "Probably",      custom_id => "akinator_answer_3" },
                { type => 2, style => 1, label => "Probably Not",  custom_id => "akinator_answer_4" }
            ]
        }]
    };

    # Send the message and save its ID so we can disable the buttons later.
    $self->discord->send_message($channel_id, $embed, sub {
        my $sent_msg = shift;
        if (ref $sent_msg eq 'HASH' && $sent_msg->{id}) {
            $active_games{$channel_id}{message_id} = $sent_msg->{id};
        }
    });
}

# This is called when the API is confident enough to make a guess. It now asks for confirmation.
sub _make_guess {
    my ($self, $channel_id, $params) = @_;
    my $game = $active_games{$channel_id};
    
    # The guess information is nested inside the 'elements' array.
    my $guess = $params->{elements}[0]{element};

    # Store the details of this guess in the game state, so we can use them
    # if the user confirms it's correct.
    $game->{id_proposition} = $guess->{id_proposition};
    $game->{name_proposition} = $guess->{name};
    $game->{flag_photo} = $guess->{flag_photo} || 0; # Use 0 as a default if not present

    $self->discord->send_message($channel_id, "I think I have it...");
    
    my $embed = {
        embeds => [{
            title       => "I'm thinking of... " . decode_entities($guess->{name}),
            description => "**" . decode_entities($guess->{description}) . "**",
            color       => 15844367, # Gold
            image       => { url => $guess->{absolute_picture_path} },
            footer      => { text => "Was I correct?" }
        }],
        # Add new Yes/No buttons for confirmation.
        components => [{
            type => 1, # Action Row
            components => [
                { type => 2, style => 3, label => "Yes", custom_id => "akinator_guess_yes" },
                { type => 2, style => 4, label => "No",  custom_id => "akinator_guess_no" },
            ]
        }]
    };

    # Send the guess and wait for the user to click a button. The game no longer stops here.
    $self->discord->send_message($channel_id, $embed, sub {
        my $sent_msg = shift;
        if (ref $sent_msg eq 'HASH' && $sent_msg->{id}) {
            $active_games{$channel_id}{message_id} = $sent_msg->{id};
        }
    });
}

# Stops the game and cleans up the active game state from the %active_games hash.
sub stop_game {
    my ($self, $msg, $message) = @_;
    my $channel_id = $msg->{'channel_id'};
    $message //= "Akinator game has been stopped.";

    if (exists $active_games{$channel_id}) {
        # Disable buttons on the last message to prevent further interaction.
        if (my $message_id = $active_games{$channel_id}{message_id}) {
            $self->_disable_buttons($channel_id, $message_id);
        }
        # Remove the game state from memory.
        delete $active_games{$channel_id};
        $self->discord->send_message($channel_id, $message) if $message;
        # React to the original !akinator stop command if it was user-initiated.
        $self->bot->react_robot($msg->{'channel_id'}, $msg->{'id'}) if $msg->{'id'};
        $self->debug("Game stopped for channel $channel_id.");
    } else {
        $self->discord->send_message($channel_id, "There's no game to stop in this channel.");
    }
}

# Helper sub to remove buttons from a message by editing it with an empty components array.
sub _disable_buttons {
    my ($self, $channel_id, $message_id) = @_;
    return unless ($channel_id && $message_id);
    $self->debug("Disabling buttons on message ID $message_id.");

    $self->discord->get_message($channel_id, $message_id, sub {
        my $original_msg = shift;
        return unless ref $original_msg eq 'HASH';
        $original_msg->{components} = []; # Setting components to an empty array removes them.
        $self->discord->edit_message($channel_id, $message_id, $original_msg);
    });
}

# Subroutine to handle when the user confirms a guess is correct.
sub _confirm_guess {
    my ($self, $interaction) = @_;
    my $channel_id = $interaction->{'channel_id'};
    my $game = $active_games{$channel_id};

    return unless $game;
    $self->_disable_buttons($channel_id, $game->{message_id});

    # This API call informs Akinator that the guess was correct.
    my $url = "https://en.akinator.com/choice";
    my $form_data = {
        session      => $game->{session},
        signature    => $game->{signature},
        step         => $game->{step},
        identifiant  => $game->{identifiant},
        pid          => $game->{id_proposition},
        charac_name  => $game->{name_proposition},
        pflag_photo  => $game->{flag_photo}
    };

    $self->debug("Confirming correct guess. POSTing to $url");
    $aki_ua->post_p($url => form => $form_data)->then(sub {
        $self->discord->send_message($channel_id, "Excellent! I am a genius! Let's play again soon.");
        $self->stop_game({ channel_id => $channel_id }, ""); # Stop without a message since one was sent
    })->catch(sub {
        $self->log->error("Failed to confirm guess with Akinator API: " . Dumper(shift));
        $self->stop_game({ channel_id => $channel_id }, "An error occurred while confirming the guess.");
    });
}

# Subroutine to handle when the user says a guess is incorrect.
sub _reject_guess {
    my ($self, $interaction) = @_;
    my $channel_id = $interaction->{'channel_id'};
    my $game = $active_games{$channel_id};

    return unless $game;
    $self->_disable_buttons($channel_id, $game->{message_id});
    $self->discord->send_message($channel_id, "Drat! Let's continue...");

    # This API call tells Akinator to exclude the last guess and provide the next question.
    my $url = "https://en.akinator.com/exclude";
    my %theme_ids = ( c => 1, a => 14, o => 2 );
    my $form_data = {
        session     => $game->{session},
        signature   => $game->{signature},
        step        => $game->{step},
        progression => $game->{progression},
        sid         => $theme_ids{$game->{theme}},
        cm          => $game->{child_mode}
    };

    $self->debug("Rejecting guess. POSTing to $url");
    $aki_ua->post_p($url => form => $form_data)->then(sub {
        my $tx = shift;
        my $json;
        
        # Safely attempt to decode the JSON from the response body.
        # This handles cases where the server returns HTML (like a Cloudflare page) instead of JSON.
        eval { $json = from_json($tx->res->body); };
        if ($@) {
            $self->log->error("Failed to parse JSON from /exclude response: " . $@);
            $self->log->error("Raw /exclude response body: " . $tx->res->body);
            $self->stop_game({ channel_id => $channel_id }, "Sorry, I received a corrupted response from the servers after rejecting a guess.");
            return;
        }

        # The /exclude endpoint returns a simple question structure, but without a `completion` key.
        # Handle this specific structure here instead of using the main response processor.
        if (ref $json eq 'HASH' && exists $json->{question}) {
            $self->debug("API returned a new question after rejection.");
            $game->{question}    = decode_entities($json->{question});
            $game->{step}        = $json->{step};
            $game->{progression} = $json->{progression};
            # Must clear the proposition details from the last guess to avoid confusion.
            delete $game->{id_proposition};
            delete $game->{name_proposition};
            delete $game->{flag_photo};
            $self->_send_question($channel_id);
        } else {
            # If the structure is unexpected, log it and stop.
            $self->log->error("Akinator /exclude returned an unexpected response: " . Dumper($json));
            $self->stop_game({ channel_id => $channel_id }, "Sorry, I received a confusing response from the servers after rejecting a guess.");
        }
    })->catch(sub {
        $self->log->error("Failed to reject guess with Akinator API: " . Dumper(shift));
        $self->stop_game({ channel_id => $channel_id }, "An error occurred while continuing the game.");
    });
}

# Centralized function to process any valid API response (from an answer).
sub _process_api_response {
    my ($self, $channel_id, $json) = @_;
    my $game = $active_games{$channel_id};

    # Basic validation of the response.
    unless (ref $json eq 'HASH' && $json->{completion} eq 'OK') {
        $self->log->error("Akinator API returned invalid data: " . Dumper($json));
        $self->stop_game({ channel_id => $channel_id }, "Sorry, I received an invalid response from the servers.");
        return;
    }

    my $guess_params;

    # The API has multiple, inconsistent structures for a guess. Must check for all of them.
    # First, check for the original nested guess structure.
    if (exists $json->{parameters}{elements}[0]{element}{id_proposition} && $json->{parameters}{elements}[0]{element}{id_proposition} ne "") {
        $self->debug("API returned a nested guess structure.");
        $guess_params = $json->{parameters};
        $game->{step_last_proposition} = $guess_params->{step};
    
    # Second, check for the new top-level guess structure.
    } elsif (exists $json->{id_proposition} && $json->{id_proposition} ne "") {
        $self->debug("API returned a top-level guess structure.");
        # Build a normalized 'parameters' hash so _make_guess doesn't need to change.
        $guess_params = {
            elements => [{
                element => {
                    id_proposition        => $json->{id_proposition},
                    name                  => $json->{name_proposition},
                    description           => $json->{description_proposition},
                    absolute_picture_path => $json->{photo}
                }
            }]
        };
        $game->{step_last_proposition} = $json->{step};
    }

    # If found a guess in either format, process it.
    if ($guess_params) {
        $self->_make_guess($channel_id, $guess_params);
    
    # If no guess was found, check for a top-level 'question'. This is the normal "next question" response.
    } elsif (exists $json->{question}) {
        $self->debug("API returned a new question.");
        # Update game state from the top-level keys.
        $game->{question}    = decode_entities($json->{question});
        $game->{step}        = $json->{step};
        $game->{progression} = $json->{progression};
        $self->debug("Progression for channel $channel_id is now: $game->{progression}");
        $self->_send_question($channel_id);
    
    # Handle any other unexpected API response structure.
    } else {
        $self->log->error("Akinator API returned an unexpected 'OK' response structure: " . Dumper($json));
        $self->stop_game({ channel_id => $channel_id }, "Sorry, I received a confusing response from the servers.");
    }
}


1;