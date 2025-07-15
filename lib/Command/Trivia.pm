package Command::Trivia;
use feature 'say';
use utf8;

use Moo;
use strictures 2;
use namespace::clean;

use List::Util qw(shuffle);
use HTML::Entities qw(decode_entities);
use Mojo::Promise;
use Mojo::IOLoop;
use URI::Escape qw(uri_escape_utf8 uri_unescape);
use POSIX qw(ceil);

has bot                 => ( is => 'ro' );
has discord             => ( is => 'lazy', builder => sub { shift->bot->discord } );
has log                 => ( is => 'lazy', builder => sub { shift->log } );
has name                => ( is => 'ro', default => 'Trivia' );
has access              => ( is => 'ro', default => 0 );
has description         => ( is => 'ro', default => 'Starts a trivia game.' );
has pattern             => ( is => 'ro', default => sub { qr/^triv(ia)?\b/i } );
has function            => ( is => 'ro', default => sub { \&cmd_trivia } );
has db                  => ( is => 'ro', required => 1 );
has usage               => ( is => 'ro', default => <<~'EOF'
### **Trivia Command**

**Description:** Starts an interactive trivia game in the channel. Fetches questions from the OpenTDB API. Players compete to be the first to reach the target score.

---
**Usage:** `!trivia <sub-command> [options]`

---
**Sub-commands:**

* `start [difficulty] [win_score] [category]`
    * Starts a new trivia game session.
    * Scores are reset for the channel at the start of each new game.
    * **[difficulty]** (optional): Sets the question difficulty. Can be `easy`, `medium`, or `hard`.
    * **[win_score]** (optional): Sets the number of points needed to win. Defaults to **10**.
    * **[category]** (optional): Specifies a category for the questions. If the category name contains spaces, just type it out.

* `buttons`
    * Starts an interactive menu to set up a trivia game using Discord buttons for options.

* `stop`
    * Ends the current trivia game in the channel.
    * Displays the final scores for the session.

* `top`
    * Displays the leaderboard for the current game session.

* `globaltop`
    * Displays the all-time, server-wide trivia leaderboard.

* `categories`
    * Lists all available trivia categories that can be used with the `start` command.

---
**Examples:**

* `!trivia start`
    * Starts a game with default settings (any difficulty, 10 points to win, any category).
* `!trivia start easy 15`
    * Starts an easy game where the first player to 15 points wins.
* `!trivia start hard Video Games`
    * Starts a hard game with questions from the "Video Games" category.
* `!trivia buttons`
    * Opens an interactive menu to configure and start a game.
EOF
);

# This hash holds all temporary state for active games, keyed by channel ID.
my %active_channels;
# {
#   channel_id => {
#     is_fetching    => (0|1),
#     timer_id       => Mojo::IOLoop timer ID,
#     session_token  => OpenTDB session token,
#     answered_users => { user_id => 1, ... } # Tracks users who have already answered the current question
#     pending_options => { difficulty => 'easy', win_score => 10, category_id => 9, category_name => 'Video Games' }
#     category_menu => { current_page => 0, total_pages => 2, categories => [], message_id => '...' }
#   }
# }

# In-memory cache for categories
my %categories_cache;
my $categories_last_fetched = 0;


has on_message => ( is => 'ro', default => sub {
    my $self = shift;

    $self->discord->gw->on('INTERACTION_CREATE' => sub {
        my ($gw, $interaction) = @_;
        return unless (ref $interaction->{data} eq 'HASH' && $interaction->{data}{custom_id});
        my $custom_id = $interaction->{data}{custom_id};
        my $channel_id = $interaction->{channel_id};
        my $message_id = $interaction->{message}{id}; # The ID of the message with the buttons
        my $user_id = $interaction->{member}{user}{id};

        # Acknowledge the interaction immediately to avoid "This interaction failed"
        # Type 6 is DEFERRED_CHANNEL_MESSAGE_WITH_SOURCE
        $self->discord->interaction_response($interaction->{id}, $interaction->{token}, { type => 6 });

        # Handle trivia answer buttons
        if ($custom_id =~ /^trivia_answer_(.+)/s) {
            my $answer = $1;
            $self->handle_answer($interaction, $answer);

        } elsif ($custom_id eq 'trivia_end_session') {
            my $mock_msg = { channel_id => $channel_id };
            $self->stop_game($mock_msg);

        } elsif ($custom_id =~ /^trivia_set_difficulty_(easy|medium|hard)$/) {
            my $difficulty = $1;
            $active_channels{$channel_id}{pending_options}{difficulty} = $difficulty;
            debug("User $user_id set difficulty to $difficulty for channel $channel_id.");
            # Update the message to show selected difficulty
            $self->_update_buttons_menu($channel_id, $message_id);

        } elsif ($custom_id =~ /^trivia_set_winscore_(\d+)$/) {
            my $win_score = $1;
            $active_channels{$channel_id}{pending_options}{win_score} = $win_score;
            debug("User $user_id set win score to $win_score for channel $channel_id.");
            # Update the message to show selected win score
            $self->_update_buttons_menu($channel_id, $message_id);
            
        } elsif ($custom_id eq 'trivia_select_category') {
            debug("User $user_id clicked 'Select Category' for channel $channel_id.");
            $self->show_category_selection($channel_id, $message_id);

        } elsif ($custom_id eq 'trivia_start_with_buttons') {
            debug("User $user_id clicked 'Start Game' for channel $channel_id.");
            my $opts = $active_channels{$channel_id}{pending_options};
            # Ensure opts is initialized
            $opts //= {};
            # If no options were selected, use defaults.
            $opts->{difficulty}    //= undef; # No default difficulty
            $opts->{win_score}     //= 10;
            $opts->{category_id}   //= undef;
            $opts->{category_name} //= undef;
            $opts->{via_buttons}   = 1; # Flag to indicate initiation via buttons

            # Clear pending options and disable current button menu BEFORE starting the game
            delete $active_channels{$channel_id}{pending_options};
            $self->_disable_buttons($channel_id, $message_id);

            # If this is the start of a new game via buttons, clear previous session scores
            my $data = $self->get_trivia_data();
            $data->{scores}{$channel_id} = {}; # Reset session scores for this channel
            $self->db->set('trivia', $data);

            # Send a confirmation message, then start the game in its callback
            $self->discord->send_message($channel_id, "Starting trivia game with your selected options...", sub {
                $self->start_game({ channel_id => $channel_id, content => '' }, $opts);
            });
        
        } elsif ($custom_id eq 'trivia_cancel_buttons_setup') {
            debug("User $user_id clicked 'Cancel' for channel $channel_id.");
            delete $active_channels{$channel_id}{pending_options}; # Clear pending options
            $self->_disable_buttons($channel_id, $message_id); # Disable current button menu
            $self->discord->send_message($channel_id, "Trivia game setup cancelled.");
        
        } elsif (defined $interaction->{data}{component_type} && $interaction->{data}{component_type} == 3) { # Discord's SELECT_MENU type is 3
            if ($custom_id =~ /^trivia_category_select_(\d+)$/) {
                my $selected_value = $interaction->{data}{values}[0]; # Get the selected option's value
                if ($selected_value =~ /^cat_(.+)$/) {
                    my $category_id = $1;
                    # Find the original name from cache using the ID
                    my ($cat_obj_key) = grep { $categories_cache{$_}{id} == $category_id } keys %categories_cache;
                    my $category_name = $categories_cache{$cat_obj_key}{original_name} if $cat_obj_key;

                    if ($category_name) {
                        $active_channels{$channel_id}{pending_options}{category_id} = $category_id;
                        $active_channels{$channel_id}{pending_options}{category_name} = $category_name;
                        debug("User $user_id selected category ID $category_id ($category_name) for channel $channel_id.");
                        delete $active_channels{$channel_id}{category_menu}; # Clear category menu state
                        $self->_update_buttons_menu($channel_id, $message_id); # Go back to the main menu after selection
                    } else {
                        $self->discord->send_message($channel_id, "Error: Selected category not found.");
                        $self->_update_buttons_menu($channel_id, $message_id); # Fallback to main menu
                    }
                }
            }

        } elsif ($custom_id eq 'trivia_cat_nav_prev') {
            my $cat_menu_state = $active_channels{$channel_id}{category_menu};

            if ($cat_menu_state && $cat_menu_state->{current_page} > 0) {
                $cat_menu_state->{current_page}--;
                $self->_send_category_page($channel_id, $message_id, $cat_menu_state->{current_page});
            }

        } elsif ($custom_id eq 'trivia_cat_nav_next') {
            my $cat_menu_state = $active_channels{$channel_id}{category_menu};

            if ($cat_menu_state && $cat_menu_state->{current_page} < $cat_menu_state->{total_pages} - 1) {
                $cat_menu_state->{current_page}++;
                $self->_send_category_page($channel_id, $message_id, $cat_menu_state->{current_page});
            }

        } elsif ($custom_id eq 'trivia_back_to_main') {
            debug("User $user_id clicked 'Back to Main Menu' for channel $channel_id.");
            delete $active_channels{$channel_id}{category_menu}; # Clear category menu state
            $self->_update_buttons_menu($channel_id, $message_id); # Go back to main setup menu
        }
    });
});


my $debug = 1;
sub debug { my $msg = shift; say "[Trivia DEBUG] $msg" if $debug }


# Helper to initialize data structures from DB
sub get_trivia_data {
    my $self = shift;
    my $data = $self->db->get('trivia') || {};
    $data->{scores} //= {}; # Scores per channel, e.g., { 'channel_id' => { 'user_id' => score, ... } }
    $data->{global_scores} //= {}; # All-time global scores
    $data->{active_game} //= {}; # Active game state per channel

    return $data;
}

# Get (or retrieve from DB) an OpenTDB session token
sub _get_session_token {
    my ($self, $channel_id) = @_;
    my $token_key = "trivia_token_$channel_id";

    # Try to get token from DB first
    my $token_ref = $self->db->get($token_key);
    my $persisted_token = $token_ref ? ${$token_ref} : ''; # Dereference the token

    if (defined $persisted_token && length $persisted_token > 0) {
        debug("-> Using persisted session token for channel $channel_id: $persisted_token");
        $active_channels{$channel_id}{session_token} = $persisted_token;
        return Mojo::Promise->resolve($persisted_token);
    }

    # If not found in DB, request a new one
    my $api_url = 'https://opentdb.com/api_token.php?command=request';
    debug("-> Requesting new session token for channel $channel_id.");

    return $self->discord->rest->ua->get_p($api_url)->then(sub {
        my $tx = shift;
        my $json = $tx->res->json;

        if ($json && $json->{response_code} == 0 && $json->{token}) {
            debug("-> Got new token: $json->{token}");
            $active_channels{$channel_id}{session_token} = $json->{token};
            my $token_to_store = \$json->{token};
            $self->db->set($token_key, $token_to_store);
            
            return Mojo::Promise->resolve($json->{token});
        }

        debug("-> Failed to get session token: " . ($json->{response_message} // "Unknown error"));

        return Mojo::Promise->reject("Failed to get session token.");
    })->catch(sub {
        my $err = shift;

        debug("-> Error during session token fetch: $err");

        return Mojo::Promise->reject("Network error fetching token: $err");
    });
}

# Reset an OpenTDB session token
sub _reset_session_token {
    my ($self, $channel_id, $token) = @_;
    my $token_key = "trivia_token_$channel_id";

    my $api_url = "https://opentdb.com/api_token.php?command=reset&token=$token";

    debug("-> Resetting session token for channel $channel_id: $token");

    return $self->discord->rest->ua->get_p($api_url)->then(sub {
        my $tx = shift;
        my $json = $tx->res->json;

        if ($json && $json->{response_code} == 0 && $json->{token}) {
            debug("-> Token reset successful. New token: $json->{token}");
            $active_channels{$channel_id}{session_token} = $json->{token};
            $self->db->set($token_key, $json->{token}); # Update in DB
            return Mojo::Promise->resolve($json->{token});
        }

        debug("-> Failed to reset session token: " . ($json->{response_message} // "Unknown error"));

        return Mojo::Promise->reject("Failed to reset session token.");
    })->catch(sub {
        my $err = shift;

        debug("-> Error during token reset: $err");

        return Mojo::Promise->reject("Network error resetting token: $err");
    });
}

# Fetches categories from API
sub _fetch_categories {
    my $self = shift;

    if (!%categories_cache || (time - $categories_last_fetched) > 3600) {
        my $api_url = 'https://opentdb.com/api_category.php';

        debug("-> Fetching trivia categories from API: $api_url");

        return $self->discord->rest->ua->get_p($api_url)->then(sub {
            my $tx = shift;

            return Mojo::Promise->reject("API fetch failed") unless $tx->res->is_success;

            my $api_data = $tx->res->json;

            return Mojo::Promise->reject("Invalid API response") unless (ref $api_data eq 'HASH' && ref $api_data->{trivia_categories} eq 'ARRAY');
            
            %categories_cache = ();
            
            for my $cat (@{$api_data->{trivia_categories}}) {
                my $original_name = decode_entities($cat->{name});
                my $cleaned_name = lc $original_name;
                $cleaned_name =~ s/[^a-z0-9\s&()]//g; # Keep alphanumeric, spaces, '&', '(', ')'
                $categories_cache{$cleaned_name} = { id => $cat->{id}, original_name => $original_name };
            }

            $categories_last_fetched = time;

            debug("-> Successfully cached " . scalar(keys %categories_cache) . " categories.");

            return Mojo::Promise->resolve(1);
        })->catch(sub {
            my $err = shift;

            debug("Error fetching categories: $err");

            return Mojo::Promise->reject("Error fetching categories: $err");
        });
    }

    debug("-> Using cached trivia categories.");

    return Mojo::Promise->resolve(1);
}


sub cmd_trivia {
    my ($self, $msg) = @_;
    my $args_str = $msg->{'content'};
    $args_str =~ s/^triv(ia)?\s*//i;
    my @args = split /\s+/, $args_str;
    my $subcommand = lc(shift @args || 'start');

    debug("Routing subcommand: '$subcommand'");

    if ($subcommand eq 'start') {
        # Parsing for: [difficulty] [win_score] [category...]
        my $opts = {};
        if ($args[0] && $args[0] =~ /^(easy|medium|hard)$/i) {
            $opts->{difficulty} = lc(shift @args);
        }

        if ($args[0] && $args[0] =~ /^\d+$/) {
            $opts->{win_score} = shift @args;
        }

        if (@args) {
            $opts->{category_name} = join ' ', @args;
        }

        $self->start_game($msg, $opts);
    } elsif ($subcommand eq 'stop') { $self->stop_game($msg) 
    } elsif ($subcommand eq 'top') { $self->show_leaderboard($msg) 
    } elsif ($subcommand eq 'globaltop') { $self->show_global_leaderboard($msg) 
    } elsif ($subcommand =~ /cat(egories)?/) { $self->list_categories($msg) 
    } elsif ($subcommand eq 'buttons') { debug("Routing to 'show_buttons_menu'"); $self->show_buttons_menu($msg)
    } else { $self->discord->send_message($msg->{'channel_id'}, $self->usage) }
}


sub start_game {
    my ($self, $msg, $opts) = @_;
    $opts //= {}; # Ensure opts is a hashref
    my $channel_id = $msg->{'channel_id'};
    my $data = $self->get_trivia_data();

    return if $active_channels{$channel_id}{is_fetching};
    $active_channels{$channel_id}{is_fetching} = 1;

    # Clear any active question timer
    Mojo::IOLoop->remove($active_channels{$channel_id}{timer_id}) if $active_channels{$channel_id}{timer_id};
    delete $active_channels{$channel_id}{timer_id};

    # Clear list of users who answered the previous question
    delete $active_channels{$channel_id}{answered_users};

    # Determine if this is an initial start command (not a continuation of a game)
    my $is_initial_start_command = ($msg->{'content'} =~ /^triv(ia)?\s*start\b/i || ($msg->{'content'} =~ /^triv(ia)?$/i && !defined $opts->{category_name} && !defined $opts->{difficulty} && !defined $opts->{win_score}) || exists $opts->{via_buttons});

    # Handle explicit '!trivia start' command when a game is already active
    if ($is_initial_start_command && exists $data->{active_game}{$channel_id}) {
        debug("-> User tried to start new game, but one is already in progress for channel $channel_id.");
        delete $active_channels{$channel_id}{is_fetching}; # Clear flag as we're not fetching
        return $self->discord->send_message($channel_id, "A trivia game is already in progress in this channel! Use `!trivia stop` to end it.");
    }

    # Ensure a valid session token is available
    $self->_get_session_token($channel_id)->then(sub {
        # Continue if token is fetched or wasn't needed
        return $self->_fetch_categories();
    })->then(sub {
        my $api_url = 'https://opentdb.com/api.php?amount=1&type=multiple';
        my $game_state = $data->{active_game}{$channel_id} || {};

        # Persist options or use previous game's options
        $game_state->{difficulty}    = $opts->{difficulty}    // $game_state->{difficulty};
        $game_state->{category_name} = $opts->{category_name} // $game_state->{category_name};
        $game_state->{category_id}   = $opts->{category_id}   // $game_state->{category_id}; # Use category_id from buttons
        $game_state->{win_score}     = $opts->{win_score}     // $game_state->{win_score} // 10; # Default 10

        # Append options to API URL
        $api_url .= "&difficulty=$game_state->{difficulty}" if $game_state->{difficulty};
        $api_url .= "&token=" . $active_channels{$channel_id}{session_token} if $active_channels{$channel_id}{session_token};

        # Handle category selection (both text and button-selected)
        if (defined $game_state->{category_id}) { # Use ID if available (from buttons)
            $api_url .= "&category=$game_state->{category_id}";
            debug("-> Using category ID: $game_state->{category_id} (from buttons)");
        } elsif (defined $game_state->{category_name} && $game_state->{category_name} ne '') {
            my $user_input = lc $game_state->{category_name};
            my @matches;

            for my $cat_key (keys %categories_cache) {
                my $cat_obj = $categories_cache{$cat_key};
                if (index(lc($cat_obj->{original_name}), $user_input) != -1) {
                    push @matches, $cat_obj;
                }
            }

            if (@matches == 1) {
                my $found_cat = $matches[0];
                $api_url .= "&category=$found_cat->{id}";
                $game_state->{category_id} = $found_cat->{id}; # Store ID for next rounds
                $game_state->{category_name} = $found_cat->{original_name};
                debug("-> Using category: $game_state->{category_name} (ID: $game_state->{category_id})");
            } elsif (@matches > 1) {
                my $err_msg = "Your category choice '`$game_state->{category_name}`' was ambiguous. Did you mean one of these?\n- " . join("\n- ", map { $_->{original_name} } @matches);
                $self->discord->send_message($channel_id, $err_msg);
                delete $active_channels{$channel_id}{is_fetching};
                return Mojo::Promise->reject("Ambiguous category");
            } else {
                my $err_msg = "Unknown category: `$game_state->{category_name}`. Use `!trivia categories` to see the list.";
                $self->discord->send_message($channel_id, $err_msg);
                delete $active_channels{$channel_id}{is_fetching};
                return Mojo::Promise->reject("Unknown category");
            }
        }

        $data->{active_game}{$channel_id} = $game_state;

        if ($is_initial_start_command) {
            debug("-> Resetting scores for new game session.");
            $data->{scores}{$channel_id} = {}; # Scope scores to the channel
            $self->db->set('trivia', $data);
            $self->discord->send_message($channel_id, "Starting a new trivia game! First to **$game_state->{win_score}** points wins. Good luck!");
        } else {
            debug("-> Continuing existing game session for channel $channel_id.");
        }

        $self->db->set('trivia', $data); # Save updated game state

        $self->discord->send_message($channel_id, "Fetching a new trivia question...");
        debug("-> Calling trivia API: $api_url");
        return $self->discord->rest->ua->get_p($api_url);

    })->then(sub {
        my $tx = shift;
        delete $active_channels{$channel_id}{is_fetching};

        # If stop_game was called while fetching, the channel state will be gone. Abort.
        return unless exists $data->{active_game}{$channel_id}; # Re-check if game is still active

        unless ($tx->res->is_success) {
            debug("-> API call failed: " . $tx->res->message);
            return $self->discord->send_message($channel_id, "Sorry, API call failed: " . $tx->res->message);
        }
        my $api_data = $tx->res->json;

        # Error handling for API response codes
        if ($api_data->{response_code} != 0) {
            my $error_message = "Sorry, I couldn't get a valid trivia question. ";
            if ($api_data->{response_code} == 1) { $error_message .= "There are no questions for your selected criteria." }
            elsif ($api_data->{response_code} == 2) { $error_message .= "The query was invalid (this is a bug!)." }
            elsif ($api_data->{response_code} == 3 || $api_data->{response_code} == 4) {
                $error_message .= "The session token is invalid or exhausted. Trying to get a new one for the next question...";
                # Attempt to refresh token; no need to block the current flow
                $self->_reset_session_token($channel_id, $active_channels{$channel_id}{session_token} || '')->catch(sub{ debug("Failed to refresh token: $_[0]") });
            }
            return $self->discord->send_message($channel_id, $error_message);
        }

        unless (ref $api_data->{results} eq 'ARRAY' && @{$api_data->{results}}) {
             debug("-> API response was valid but contained no questions.");
             return $self->discord->send_message($channel_id, "Sorry, I received an empty response for a trivia question. Please try again later.");
        }


        my $question_data = $api_data->{results}[0];
        my $question = decode_entities($question_data->{question});
        my $correct_answer = decode_entities($question_data->{correct_answer});
        my @all_answers = shuffle($correct_answer, map { decode_entities($_) } @{$question_data->{incorrect_answers}});

        my @buttons;
        for my $answer (@all_answers) {
            my $label = (length $answer > 80) ? substr($answer, 0, 77) . '...' : $answer;
            push @buttons, { type => 2, style => 1, label => $label, custom_id => "trivia_answer_" . uri_escape_utf8($answer) }; # URI escape answers
        }
        my $footer_text = "Category: " . decode_entities($question_data->{category});
        my $win_score = $data->{active_game}{$channel_id}{win_score};
        $footer_text .= " | Difficulty: " . ucfirst($question_data->{difficulty}) if $question_data->{difficulty};
        $footer_text .= " | First to $win_score points wins!";

        my $payload = {
            embeds => [{ color => 3447003, title => "Trivia Time!", description => "**$question**", footer => { text => $footer_text } }],
            components => [{ type => 1, components => \@buttons }],
        };

        $self->discord->send_message($channel_id, $payload, sub {
            my $sent_msg = shift;
            unless (ref $sent_msg eq 'HASH' && $sent_msg->{id}) {
                debug("-> Failed to send question message: " . Dumper($sent_msg));
                return;
            }
            my $game_data = $self->get_trivia_data();
            $game_data->{active_game}{$channel_id}{question}       = $question;
            $game_data->{active_game}{$channel_id}{correct_answer} = $correct_answer;
            $game_data->{active_game}{$channel_id}{message_id}     = $sent_msg->{id};
            $game_data->{active_game}{$channel_id}{answered}       = 0; # Reset for new question
            # Update category and other game state based on what was actually sent
            $game_data->{active_game}{$channel_id}{difficulty}     = $question_data->{difficulty};
            $game_data->{active_game}{$channel_id}{category_name}  = decode_entities($question_data->{category});
            $game_data->{active_game}{$channel_id}{win_score}      = $win_score; # Ensure win_score is persisted

            $self->db->set('trivia', $game_data);

            # Set question timer using the consolidated state hash
            $active_channels{$channel_id}{timer_id} = Mojo::IOLoop->timer(15 => sub {
                my $current_data = $self->get_trivia_data();
                my $current_game = $current_data->{active_game}{$channel_id};
                if (defined $current_game && !$current_game->{answered}) {
                    $self->discord->send_message($channel_id, "Time's up! The correct answer was **$current_game->{correct_answer}**.");
                    $self->_disable_buttons($channel_id, $current_game->{message_id});
                    # Pass existing options to the next start_game call
                    Mojo::IOLoop->timer(2 => sub {
                        # Ensure game is still active before starting next question
                        if (exists $current_data->{active_game}{$channel_id}) {
                            $self->start_game({ channel_id => $channel_id, content => '' }, {
                                difficulty => $current_game->{difficulty},
                                win_score => $current_game->{win_score},
                                category_id => $current_game->{category_id},
                                category_name => $current_game->{category_name},
                            });
                        } else {
                            debug("Game stopped before timer triggered next question for channel $channel_id.");
                        }
                    });
                }
                delete $active_channels{$channel_id}{timer_id};
            });
        });
    })->catch(sub {
        my $err = shift;
        debug("-> Error during start_game promise chain: $err");
        delete $active_channels{$channel_id}{is_fetching};
    });
}


sub handle_answer {
    my ($self, $interaction, $submitted_answer) = @_;
    my $channel_id = $interaction->{channel_id};
    my $user = $interaction->{member}{user};
    my $interaction_msg_id = $interaction->{message}{id};

    my $data = $self->get_trivia_data();
    my $game = $data->{active_game}{$channel_id};

    return unless (ref $game eq 'HASH' && %$game && $game->{message_id} eq $interaction_msg_id);

    # Prevent user from answering the same question twice.
    if ($active_channels{$channel_id}{answered_users}{$user->{id}}) {
        debug("-> User $user->{id} already answered this question. Ignoring.");
        return;
    }
    $active_channels{$channel_id}{answered_users}{$user->{id}} = 1;

    if ($game->{answered}) {
        debug("-> Question was already answered correctly. Ignoring subsequent answers.");
        return;
    }

    # URI unescape submitted answer for comparison
    $submitted_answer = uri_unescape($submitted_answer);

    if ($submitted_answer eq $game->{correct_answer}) {
        $self->_process_correct_answer($channel_id, $user, $game);
    } else {
        $self->_process_incorrect_answer($channel_id, $user);
    }
}

# Correct answer logic.
sub _process_correct_answer {
    my ($self, $channel_id, $user, $game) = @_;
    my $user_id = $user->{id};
    my $data = $self->get_trivia_data();

    # Increment scores for current session
    $data->{scores}{$channel_id}{$user_id} //= 0;
    $data->{scores}{$channel_id}{$user_id}++;

    # Increment global scores
    $data->{global_scores}{$user_id} //= 0;
    $data->{global_scores}{$user_id}++;

    $game->{answered} = 1; # Mark question as answered
    $data->{active_game}{$channel_id} = $game;

    $self->db->set('trivia', $data);

    # Clean up the question message by disabling buttons
    $self->_disable_buttons($channel_id, $game->{message_id});
    Mojo::IOLoop->remove($active_channels{$channel_id}{timer_id}) if $active_channels{$channel_id}{timer_id};
    delete $active_channels{$channel_id}{timer_id};

    my $current_score = $data->{scores}{$channel_id}{$user_id};
    my $win_score = $game->{win_score} || 10;

    if ($current_score >= $win_score) {
        my $final_msg = "🎉 <\@$user_id> got it right and has reached **$win_score** points to win the game! Congratulations!";
        $self->discord->send_message($channel_id, $final_msg, sub {
            $self->stop_game({ channel_id => $channel_id }); # Stop game and show final leaderboard
        });
    } else {
        my $next_q_payload = {
            content => "🎉 <\@$user_id> got it right! The answer was **$game->{correct_answer}**. Their score: **$current_score**.\n\nNext question in 5 seconds!",
            components => [{ type => 1, components => [{ type => 2, style => 4, label => "Stop Game", custom_id => "trivia_end_session" }] }]
        };
        $self->discord->send_message($channel_id, $next_q_payload, sub {
            $active_channels{$channel_id}{timer_id} = Mojo::IOLoop->timer(5 => sub {
                # Ensure the game state is still active before starting the next question
                my $next_game_data = $self->get_trivia_data();
                if (exists $next_game_data->{active_game}{$channel_id}) {
                    $self->start_game({ channel_id => $channel_id, content => '' }, { # Pass existing options
                        difficulty => $game->{difficulty},
                        win_score => $game->{win_score},
                        category_id => $game->{category_id},
                        category_name => $game->{category_name},
                    });
                } else {
                    debug("Game stopped before next question could start for channel $channel_id.");
                }
            });
        });
    }
}

# Incorrect answer logic.
sub _process_incorrect_answer {
    my ($self, $channel_id, $user) = @_;
    my $user_id = $user->{id};
    my $data = $self->get_trivia_data();
    my $score = $data->{scores}{$channel_id}{$user_id} // 0;

    if ($score > 0) {
        $data->{scores}{$channel_id}{$user_id}--;
        $self->discord->send_message($channel_id, "❌ Sorry, <\@$user_id>, that's not correct. Your score is now: **$data->{scores}{$channel_id}{$user_id}**.");
    } else {
        $data->{scores}{$channel_id}{$user_id} = 0; # Ensure it's 0
        $self->discord->send_message($channel_id, "❌ Sorry, <\@$user_id>, that's not correct. Your score remains **0**.");
    }

    $self->db->set('trivia', $data);
}


sub stop_game {
    my ($self, $msg) = @_;
    my $channel_id = $msg->{'channel_id'};
    debug("Attempting to stop game in channel $channel_id.");
    my $data = $self->get_trivia_data();

    # Clean up all in-memory state for the channel
    if (my $chan_state = $active_channels{$channel_id}) {
        Mojo::IOLoop->remove($chan_state->{timer_id}) if $chan_state->{timer_id};
        delete $active_channels{$channel_id};
    }

    unless (exists $data->{active_game}{$channel_id}) {
        return $self->discord->send_message($channel_id, "There's no trivia game to stop in this channel.");
    }

    my $game = $data->{active_game}{$channel_id};
    my $stop_message = "Trivia game stopped. Thanks for playing!";

    if (defined $game->{correct_answer} && !$game->{answered}) {
        $stop_message = "Trivia game stopped. The correct answer was **$game->{correct_answer}**.\n\nThanks for playing!";
    }

    $self->discord->send_message($channel_id, $stop_message);
    $self->_disable_buttons($channel_id, $game->{message_id}); # Ensure buttons are disabled
    delete $data->{active_game}{$channel_id};
    $self->db->set('trivia', $data);
    $self->show_leaderboard($msg); # Show final session scores
}

# Helper to disable buttons on a message
sub _disable_buttons {
    my ($self, $channel_id, $message_id) = @_;

    return unless ($channel_id && $message_id);

    debug("-> Disabling buttons on message ID $message_id.");

    $self->discord->get_message($channel_id, $message_id, sub {
        my $original_msg = shift;
        return unless ref $original_msg eq 'HASH';
        
        # Remove all components (buttons/select menus)
        $original_msg->{components} = [];
        $self->discord->edit_message($channel_id, $message_id, $original_msg);
    });
}

# Helper to display a leaderboard
sub _display_leaderboard {
    my ($self, $channel_id, $scores, $title, $color, $empty_msg) = @_;

    unless (ref $scores eq 'HASH' && %$scores) {
        return $self->discord->send_message($channel_id, $empty_msg);
    }

    my @sorted_user_ids = sort { $scores->{$b} <=> $scores->{$a} } keys %$scores;
    my @lines;
    my $limit = @sorted_user_ids > 20 ? 20 : @sorted_user_ids; # Show top 20

    for my $i (0 .. $limit - 1) {
        my $user_id = $sorted_user_ids[$i];
        my $points = $scores->{$user_id};
        push @lines, "**" . ($i + 1) . ".** <\@$user_id> - $points points";
    }

    my $embed = {
        embeds => [{
            title       => $title,
            color       => $color,
            description => join("\n", @lines),
        }]
    };
    $self->discord->send_message($channel_id, $embed);
}

# Shows session leaderboard
sub show_leaderboard {
    my ($self, $msg) = @_;
    my $channel_id = $msg->{'channel_id'};
    my $data = $self->get_trivia_data();

    $self->_display_leaderboard(
        $channel_id,
        $data->{scores}{$channel_id}, # Scoped to channel
        "🏆 Trivia Leaderboard (This Session)",
        16776960, # Gold-ish color
        "Nobody has any points in this session. Start a game with `!trivia start`!"
    );
}

# Shows global leaderboard
sub show_global_leaderboard {
    my ($self, $msg) = @_;
    my $channel_id = $msg->{'channel_id'};
    my $data = $self->get_trivia_data();

    $self->_display_leaderboard(
        $channel_id,
        $data->{global_scores},
        "🌍 Global Trivia Leaderboard (All Time)",
        5814783, # Blue-ish color
        "There are no global scores yet!"
    );
}

# List categories
sub list_categories {
    my ($self, $msg) = @_;
    my $channel_id = $msg->{'channel_id'};
    $self->discord->send_message($channel_id, "Fetching available trivia categories...");
    $self->_fetch_categories()->then(sub {
        unless (%categories_cache) {
            return $self->discord->send_message($channel_id, "Sorry, I couldn't fetch any trivia categories.");
        }
        my @sorted_names = sort { $categories_cache{$a}{original_name} cmp $categories_cache{$b}{original_name} } keys %categories_cache;
        my @formatted_categories = map { "- " . $categories_cache{$_}{original_name} } @sorted_names;
        my $embed = { embeds => [{ title => "📚 Available Trivia Categories", color => 5793266, description => "Use one with `!trivia start <category>`:\n\n" . join("\n", @formatted_categories) }]};
        $self->discord->send_message($channel_id, $embed);
    })->catch(sub {
        my $err = shift;
        $self->discord->send_message($channel_id, "Sorry, I couldn't list trivia categories: $err");
    });
}


sub show_buttons_menu {
    my ($self, $msg) = @_;
    my $channel_id = $msg->{'channel_id'};
    debug("show_buttons_menu: Displaying trivia options menu in channel $channel_id.");

    # Initialize pending options for this channel
    $active_channels{$channel_id}{pending_options} = {
        difficulty => undef,
        win_score => 10, # Default win score
        category_id => undef,
        category_name => undef,
    };

    # Define the initial payload for the message
    my $initial_payload = {
        content => "Let's set up your trivia game! Please select a difficulty and win score, then choose your categories.",
        components => [
            {   # Row 1: Difficulty
                type => 1,
                components => [
                    { type => 2, style => 1, label => "Easy", custom_id => "trivia_set_difficulty_easy" },
                    { type => 2, style => 1, label => "Medium", custom_id => "trivia_set_difficulty_medium" },
                    { type => 2, style => 1, label => "Hard", custom_id => "trivia_set_difficulty_hard" },
                ]
            },
            {   # Row 2: Win Score
                type => 1,
                components => [
                    { type => 2, style => 1, label => "Win Score: 5", custom_id => "trivia_set_winscore_5" },
                    { type => 2, style => 1, label => "Win Score: 10", custom_id => "trivia_set_winscore_10" },
                    { type => 2, style => 1, label => "Win Score: 20", custom_id => "trivia_set_winscore_20" },
                ]
            },
            {   # Row 3: Categories & Start/Cancel
                type => 1,
                components => [
                    { type => 2, style => 3, label => "Select Category", custom_id => "trivia_select_category" },
                    { type => 2, style => 3, label => "Start Game", custom_id => "trivia_start_with_buttons" },
                    { type => 2, style => 4, label => "Cancel", custom_id => "trivia_cancel_buttons_setup" },
                ]
            }
        ]
    };

    # Send the initial message with the buttons
    $self->discord->send_message($channel_id, $initial_payload, sub {
        my $sent_msg = shift;
        if (ref $sent_msg eq 'HASH' && $sent_msg->{id}) {
            debug("Initial buttons message sent with ID: " . $sent_msg->{id});
            # Store the message ID so _update_buttons_menu knows which message to edit
            $active_channels{$channel_id}{buttons_message_id} = $sent_msg->{id};
            # Immediately update the message to reflect initial (default) selections, if any.
            # This will also ensure the content message displays correctly from the start.
            $self->_update_buttons_menu($channel_id, $sent_msg->{id});
        } else {
            debug("Failed to send initial buttons message: " . Dumper($sent_msg));
            $self->discord->send_message($channel_id, "Error: Could not display trivia setup menu.");
            $self->bot->react_error($channel_id, $msg->{'id'});
        }
    });

    $self->bot->react_robot($channel_id, $msg->{'id'});
}


sub _update_buttons_menu {
    my ($self, $channel_id, $message_id) = @_;
    debug("Updating buttons menu for message $message_id in channel $channel_id.");

    my $current_options = $active_channels{$channel_id}{pending_options} || {};

    my $difficulty_label = $current_options->{difficulty} ? ucfirst($current_options->{difficulty}) : 'Difficulty';
    my $win_score_label = $current_options->{win_score} ? "Win Score: $current_options->{win_score}" : 'Win Score';
    my $category_label = $current_options->{category_name} ? "Category: $current_options->{category_name}" : 'Select Category';

    my $content_message = "Let's set up your trivia game! Current selections:\n"
                          . "Difficulty: **" . ($current_options->{difficulty} ? ucfirst($current_options->{difficulty}) : "Any") . "**\n"
                          . "Win Score: **" . ($current_options->{win_score} || 10) . "**\n"
                          . "Category: **" . ($current_options->{category_name} || "Any") . "**";

    my $payload = {
        content => $content_message,
        components => [
            {   # Row 1: Difficulty
                type => 1,
                components => [
                    { type => 2, style => (lc($current_options->{difficulty} || '') eq 'easy' ? 3 : 1), label => "Easy", custom_id => "trivia_set_difficulty_easy" },
                    { type => 2, style => (lc($current_options->{difficulty} || '') eq 'medium' ? 3 : 1), label => "Medium", custom_id => "trivia_set_difficulty_medium" },
                    { type => 2, style => (lc($current_options->{difficulty} || '') eq 'hard' ? 3 : 1), label => "Hard", custom_id => "trivia_set_difficulty_hard" },
                ]
            },
            {   # Row 2: Win Score
                type => 1,
                components => [
                    { type => 2, style => ($current_options->{win_score} == 5 ? 3 : 1), label => "Win Score: 5", custom_id => "trivia_set_winscore_5" },
                    { type => 2, style => ($current_options->{win_score} == 10 ? 3 : 1), label => "Win Score: 10", custom_id => "trivia_set_winscore_10" },
                    { type => 2, style => ($current_options->{win_score} == 20 ? 3 : 1), label => "Win Score: 20", custom_id => "trivia_set_winscore_20" },
                ]
            },
            {   # Row 3: Categories & Start/Cancel
                type => 1,
                components => [
                    { type => 2, style => 3, label => $category_label, custom_id => "trivia_select_category" },
                    { type => 2, style => 3, label => "Start Game", custom_id => "trivia_start_with_buttons" },
                    { type => 2, style => 4, label => "Cancel", custom_id => "trivia_cancel_buttons_setup" },
                ]
            }
        ]
    };

    $self->discord->edit_message($channel_id, $message_id, $payload);
}


sub show_category_selection {
    my ($self, $channel_id, $message_id) = @_;
    debug("show_category_selection: Displaying category selection menu for message $message_id in channel $channel_id.");

    # Ensure categories are fetched before trying to display them
    $self->_fetch_categories()->then(sub {
        unless (%categories_cache) {
            $self->discord->send_message($channel_id, "Sorry, I couldn't fetch any trivia categories right now.");
            return Mojo::Promise->reject("No categories fetched.");
        }

        my @sorted_categories = sort { # Sort by original_name
            ($a->{original_name} // '') cmp ($b->{original_name} // '')
        } values %categories_cache;

        # Discord select menus have a limit of 25 options.
        # We will split categories into pages if there are more than 25.
        my $page_size = 25;
        my $total_pages = ceil(scalar(@sorted_categories) / $page_size);
        my $current_page = 0; # Start with the first page

        # Store category navigation state in active_channels
        $active_channels{$channel_id}{category_menu} = {
            current_page => $current_page,
            total_pages => $total_pages,
            categories => \@sorted_categories,
            message_id => $message_id, # Store the ID of the message to update
        };

        $self->_send_category_page($channel_id, $message_id, $current_page);

    })->catch(sub {
        my $err = shift;
        debug("Error fetching categories for selection menu: $err");
        $self->discord->send_message($channel_id, "Sorry, I couldn't load categories: $err");
        # Re-enable the main trivia setup buttons if an error occurs here
        $self->_update_buttons_menu($channel_id, $message_id);
    });
}

# Helper to send a specific page of categories using a select menu
sub _send_category_page {
    my ($self, $channel_id, $original_message_id, $page_index) = @_;
    debug("_send_category_page: Sending page $page_index for channel $channel_id.");

    my $cat_menu_state = $active_channels{$channel_id}{category_menu};
    unless ($cat_menu_state && $cat_menu_state->{categories}) {
        debug("No category menu state found for channel $channel_id.");
        return;
    }

    my @categories = @{$cat_menu_state->{categories}};
    my $page_size = 25;
    my $start_index = $page_index * $page_size;
    my $end_index = $start_index + $page_size - 1;
    $end_index = $#categories if $end_index > $#categories;

    my @options;
    for my $i ($start_index .. $end_index) {
        my $cat = $categories[$i];
        push @options, {
            label => (length $cat->{original_name} > 100) ? substr($cat->{original_name}, 0, 97) . '...' : $cat->{original_name},
            value => "cat_" . $cat->{id},
        };
    }

    my @components = (
        {   # Select menu for categories
            type => 1,
            components => [
                {
                    type        => 3, # Select Menu
                    custom_id   => "trivia_category_select_$page_index",
                    placeholder => "Select a category (Page " . ($page_index + 1) . "/" . $cat_menu_state->{total_pages} . ")",
                    options     => \@options,
                    min_values  => 1,
                    max_values  => 1,
                }
            ]
        }
    );

    # Add navigation buttons if there are multiple pages
    if ($cat_menu_state->{total_pages} > 1) {
        my @nav_buttons;
        push @nav_buttons, { type => 2, style => 1, label => "<< Prev", custom_id => "trivia_cat_nav_prev", disabled => ($page_index == 0) } if $page_index > 0;
        push @nav_buttons, { type => 2, style => 1, label => "Next >>", custom_id => "trivia_cat_nav_next", disabled => ($page_index == $cat_menu_state->{total_pages} - 1) } if $page_index < $cat_menu_state->{total_pages} - 1;
        push @nav_buttons, { type => 2, style => 4, label => "Back to Main Menu", custom_id => "trivia_back_to_main" };
        push @components, { type => 1, components => \@nav_buttons };
    } else {
        # If only one page, still provide a way back to main menu
        push @components, { type => 1, components => [{ type => 2, style => 4, label => "Back to Main Menu", custom_id => "trivia_back_to_main" }] };
    }

    my $content_message = "Please select a category:";
    if ($cat_menu_state->{total_pages} > 1) {
        $content_message .= " (Page " . ($page_index + 1) . " of " . $cat_menu_state->{total_pages} . ")";
    }

    my $payload = {
        content => $content_message,
        components => \@components
    };

    # Edit the original message to show the category selection menu
    $self->discord->edit_message($channel_id, $original_message_id, $payload);
}

1;