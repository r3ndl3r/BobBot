package Command::Trivia;
use feature 'say';
use utf8;

use Moo;
use strictures 2;
use namespace::clean;

use Component::DBI;
use List::Util qw(shuffle);
use HTML::Entities qw(decode_entities);
use Mojo::Promise;
use Mojo::IOLoop;
use URI::Escape; # For escaping category names in URLs

has bot                 => ( is => 'ro' );
has discord             => ( is => 'lazy', builder => sub { shift->bot->discord } );
has log                 => ( is => 'lazy', builder => sub { shift->bot->log } );
has name                => ( is => 'ro', default => 'Trivia' );
has access              => ( is => 'ro', default => 0 );
has description         => ( is => 'ro', default => 'Starts a trivia game.' );
has usage               => ( is => 'ro', default => 'Usage: !trivia <start [category]|stop|top|category list>' ); # Updated usage
has pattern             => ( is => 'ro', default => sub { qr/^trivia\b/i } );
has function            => ( is => 'ro', default => sub { \&cmd_trivia } );

# In-memory hash to track if a channel is currently fetching a question
my %is_fetching_question;
# Added to track active timers for each channel
my %question_timers;
# In-memory hash to store categories: { 'cleaned_name' => { id => ID, original_name => 'Original Name' } }
my %categories_cache;
my $categories_last_fetched = 0; # Timestamp to control fetching frequency

has on_message => ( is => 'ro', default => sub {
        my $self = shift;
        $self->discord->gw->on('INTERACTION_CREATE' => sub {
            my ($gw, $interaction) = @_;
            return unless (ref $interaction->{data} eq 'HASH' && $interaction->{data}{custom_id});
            my $custom_id = $interaction->{data}{custom_id};

            if ($custom_id =~ /^trivia_answer_(.+)/s) {
                my $answer = $1;
                $self->handle_answer($interaction, $answer);
            }
            elsif ($custom_id eq 'trivia_end_session') {
                my $payload = { type => 6 };
                $self->discord->interaction_response($interaction->{id}, $interaction->{token}, $payload);

                my $mock_msg = { channel_id => $interaction->{channel_id} };
                $self->stop_game($mock_msg);
            }
        });
    }
);

my $debug = 1;
sub debug { my $msg = shift; say "[Trivia DEBUG] $msg" if $debug }

sub get_trivia_data {
    my $db = Component::DBI->new();
    my $data = $db->get('trivia') || {};
    $data->{scores} //= {};
    $data->{active_game} //= {};
    debug("Data initialized.");
    return $data;
}

# New sub to fetch categories from OpenTDB API
sub _fetch_categories {
    my $self = shift;

    # Only fetch if cache is empty or older than 1 hour (3600 seconds)
    if (!%categories_cache || (time - $categories_last_fetched) > 3600) {
        my $api_url = 'https://opentdb.com/api_category.php';
        debug("-> Fetching trivia categories from API: $api_url");

        return $self->discord->rest->ua->get_p($api_url)->then(sub {
            my $tx = shift;
            unless ($tx->res->is_success) {
                $self->log->warn("-> Failed to fetch trivia categories: " . $tx->res->message);
                return Mojo::Promise->reject("Failed to fetch categories");
            }

            my $api_data = $tx->res->json;
            unless (ref $api_data eq 'HASH' && ref $api_data->{trivia_categories} eq 'ARRAY') {
                $self->log->warn("-> Invalid API response for categories.");
                return Mojo::Promise->reject("Invalid categories response");
            }

            %categories_cache = (); # Clear old cache
            for my $cat (@{$api_data->{trivia_categories}}) {
                my $original_name = decode_entities($cat->{name});
                my $cleaned_name = lc $original_name;
                $cleaned_name =~ s/[^a-z0-9]//g; # Remove non-alphanumeric for matching
                $categories_cache{$cleaned_name} = {
                    id => $cat->{id},
                    original_name => $original_name
                };
            }
            $categories_last_fetched = time;
            debug("-> Successfully fetched and cached " . scalar(keys %categories_cache) . " categories.");
            return Mojo::Promise->resolve(1); # Indicate success
        })->catch(sub {
            my $err = shift;
            $self->log->error("Error fetching categories: $err");
            return Mojo::Promise->reject("Error fetching categories: $err");
        });
    } else {
        debug("-> Using cached trivia categories.");
        return Mojo::Promise->resolve(1); # Already cached
    }
}


sub cmd_trivia {
    my ($self, $msg) = @_;
    my $args_str = $msg->{'content'};

    $args_str =~ s/^trivia\s*//i;

    my @args = split /\s+/, $args_str;
    my $subcommand = lc(shift @args || 'start');

    debug("Routing subcommand: '$subcommand'");

    if ($subcommand eq 'start') {
        my $category_name = join ' ', @args; # Capture the rest as category name
        $self->start_game($msg, $category_name);
    } elsif ($subcommand eq 'stop') {
        $self->stop_game($msg);
    } elsif ($subcommand eq 'top') {
        $self->show_leaderboard($msg);
    } elsif ($subcommand eq 'category' && lc(shift @args) eq 'list') {
        $self->list_categories($msg);
    } else {
        $self->discord->send_message($msg->{'channel_id'}, $self->usage);
    }
}

sub start_game {
    my ($self, $msg, $category_name) = @_; # Added category_name parameter
    my $channel_id = $msg->{'channel_id'};
    my $db = Component::DBI->new();
    my $data = get_trivia_data();

    # Check if a question is already being fetched for this channel
    if ($is_fetching_question{$channel_id}) {
        debug("-> Already fetching a question for channel $channel_id. Aborting redundant fetch.");
        return;
    }

    # Set the fetching flag immediately to prevent re-entry
    $is_fetching_question{$channel_id} = 1;

    # Clear any existing question timer for this channel
    if (defined $question_timers{$channel_id}) {
        Mojo::IOLoop->remove($question_timers{$channel_id});
        delete $question_timers{$channel_id};
        debug("-> Cleared existing timer for channel $channel_id.");
    }

    # Check if this call is initiated by the "!trivia start" command
    my $is_initial_start_command = ($msg->{'content'} =~ /^trivia\s*start/i || ($msg->{'content'} eq 'trivia' && !defined $category_name));

    # Handle explicit '!trivia start' command when a game is already active
    if ($is_initial_start_command && exists $data->{active_game}{$channel_id}) {
        debug("-> User tried to start new game, but one is already in progress for channel $channel_id.");
        delete $is_fetching_question{$channel_id}; # Clear flag as we're not fetching
        return $self->discord->send_message($channel_id, "A trivia game is already in progress in this channel! Use `!trivia stop` to end it.");
    }

    # Clear the active game state from previous round if it exists
    # This ensures that a new question can be properly registered.
    if (exists $data->{active_game}{$channel_id}) {
        debug("-> Clearing previous active game state for channel $channel_id.");
        delete $data->{active_game}{$channel_id};
        $db->set('trivia', $data); # Save updated state without active_game
    }

    # If no active game, and it's explicitly the !trivia start command, reset scores.
    # This ensures scores are only reset when a *new* game session explicitly begins.
    if ($is_initial_start_command) {
        debug("-> Resetting scores for new game session.");
        $data->{scores} = {}; # Reset scores only when explicitly starting a new game session
        $db->set('trivia', $data); # Save the reset scores
        $self->discord->send_message($channel_id, "Starting a new trivia game! Good luck!");
    } else {
        debug("-> Continuing existing game session for channel $channel_id.");
    }

    $self->discord->send_message($channel_id, "Fetching a new trivia question...");

    # Fetch categories if not cached, then proceed to get question
    $self->_fetch_categories()->then(sub {
        my $api_url = 'https://opentdb.com/api.php?amount=1&type=multiple';
        my $category_id;

        if (defined $category_name && $category_name ne '') {
            my $cleaned_category_name = lc $category_name;
            $cleaned_category_name =~ s/[^a-z0-9]//g;
            # Look up in the new categories_cache structure
            if (exists $categories_cache{$cleaned_category_name}) {
                $category_id = $categories_cache{$cleaned_category_name}{id};
            }

            if (defined $category_id) {
                $api_url .= "&category=$category_id";
                debug("-> Using category '$category_name' (ID: $category_id)");
            } else {
                $self->discord->send_message($channel_id, "Unknown category: `$category_name`. Using a random category instead. Type `!trivia category list` for available categories.");
            }
        }

        debug("-> Calling trivia API: $api_url");
        return $self->discord->rest->ua->get_p($api_url);
    })->then(sub {
        my $tx = shift;
        # Always clear the fetching flag once the promise resolves/rejects
        delete $is_fetching_question{$channel_id};

        unless ($tx->res->is_success) {
            debug("-> API call failed: " . $tx->res->message);
            return $self->discord->send_message($channel_id, "Sorry, I couldn't fetch a trivia question right now.");
        }

        my $api_data = $tx->res->json;
        unless (ref $api_data eq 'HASH' && $api_data->{response_code} == 0 && ref $api_data->{results} eq 'ARRAY' && @{$api_data->{results}}) {
            debug("-> API response was invalid or contained no questions.");
            return $self->discord->send_message($channel_id, "Sorry, I couldn't get a valid trivia question from the database. Please try again later. It might be due to no questions in the selected category.");
        }

        my $question_data = $api_data->{results}[0];
        my @incorrect_answers;
        if (ref $question_data->{incorrect_answers} eq 'ARRAY') {
            @incorrect_answers = @{ $question_data->{incorrect_answers} };
        } else {
            debug("-> FATAL: API response had malformed 'incorrect_answers'. Not an ARRAY ref.");
            return $self->discord->send_message($channel_id, "Sorry, the trivia question I received was malformed. Please try again.");
        }

        my $question = decode_entities($question_data->{question});
        my $correct_answer = decode_entities($question_data->{correct_answer});
        my @all_answers = shuffle($correct_answer, map { decode_entities($_) } @incorrect_answers);
        debug("-> Parsed Question: '$question' | Correct Answer: '$correct_answer'");

        my @buttons;
        for my $answer (@all_answers) {
            my $label = (length $answer > 80) ? substr($answer, 0, 77) . '...' : $answer;
            push @buttons, { type => 2, style => 1, label => $label, custom_id => "trivia_answer_$answer" };
        }

        my $payload = {
            embeds => [{ color => 3447003, title => "Trivia Time!", description => "**$question**", footer => { text => "Category: " . decode_entities($question_data->{category}) } }],
            components => [{ type => 1, components => \@buttons }],
        };

        debug("-> Sending question message to Discord.");
        $self->discord->send_message($channel_id, $payload, sub {
            my $sent_msg = shift;
            return unless ref $sent_msg eq 'HASH' && $sent_msg->{id};
            my $game_data = get_trivia_data(); # Re-fetch to ensure we have the latest state
            $game_data->{active_game}{$channel_id} = {
                question       => $question,
                correct_answer => $correct_answer,
                message_id     => $sent_msg->{id},
                answered       => 0,
                category_name  => $category_name, # Save the requested category name
            };
            debug("-> Saving active game state to DB for channel $channel_id.");
            $db->set('trivia', $game_data);

            # Set a 15-second timer for the question
            $question_timers{$channel_id} = Mojo::IOLoop->timer(15 => sub {
                my $current_game_data = get_trivia_data();
                my $current_game = $current_game_data->{active_game}{$channel_id};

                if (defined $current_game && !$current_game->{answered}) {
                    # If the question hasn't been answered, announce the correct answer and move to the next question
                    $self->discord->send_message($channel_id, "Time's up! The correct answer was **$current_game->{correct_answer}**.");

                    # Also disable buttons on the timed-out message
                    $self->discord->get_message($channel_id, $current_game->{message_id}, sub {
                        my $original_msg = shift;
                        return unless ref $original_msg eq 'HASH';
                        $original_msg->{components} = [];
                        $self->discord->edit_message($channel_id, $current_game->{message_id}, $original_msg);
                    });

                    # Start the next question after a brief pause
                    Mojo::IOLoop->timer(2 => sub {
                        my $mock_msg = { channel_id => $channel_id, content => '' };
                        # Pass category for next question if available in game state
                        $self->start_game($mock_msg, $current_game->{category_name});
                    });
                }
                delete $question_timers{$channel_id};
            });
        });
    })->catch(sub {
        my $err = shift;
        debug("-> Error during question fetch or send: $err");
        delete $is_fetching_question{$channel_id}; # Ensure flag is cleared on error
        # No need to send another "Sorry" message here, as the .then() block already handles API errors.
    });
}

sub handle_answer {
    my ($self, $interaction, $answer) = @_;
    my $channel_id = $interaction->{channel_id};
    my $user = $interaction->{member}{user};
    my $interaction_message_id = $interaction->{message}{id}; # Get the message ID of the interaction

    my $ack_payload = { type => 6 };
    $self->discord->interaction_response($interaction->{id}, $interaction->{token}, $ack_payload);

    my $db = Component::DBI->new();
    my $data = get_trivia_data();

    return unless (ref $data->{active_game} eq 'HASH');
    my $game = $data->{active_game}{$channel_id};
    return unless (ref $game eq 'HASH' && %$game);

    # Ensure the interaction is for the currently active question
    # This prevents processing answers for old questions if multiple are lingering
    unless (defined $game->{message_id} && $game->{message_id} eq $interaction_message_id) {
        debug("-> Received answer for a non-active or outdated question. Ignoring.");
        return;
    }

    # Check if this question has already been answered correctly
    if ($game->{answered}) {
        debug("-> Question already answered. Ignoring subsequent correct answers.");
        #$self->discord->send_message($channel_id, "This question has already been answered!");
        return;
    }

    if ($answer eq $game->{correct_answer}) {
        my $user_id = $user->{id};
        $data->{scores}{$user_id}++;
        $game->{answered} = 1; # Set flag: this question is now answered

        my $original_message_id = $game->{message_id};
        $db->set('trivia', $data); # Save updated scores and answered flag

        # Disable buttons on the original question message.
        $self->discord->get_message($channel_id, $original_message_id, sub {
            my $original_msg = shift;
            return unless ref $original_msg eq 'HASH';
            $original_msg->{components} = [];
            $self->discord->edit_message($channel_id, $original_message_id, $original_msg);
        });

        # Clear the question timer immediately if answered correctly
        if (defined $question_timers{$channel_id}) {
            Mojo::IOLoop->remove($question_timers{$channel_id});
            delete $question_timers{$channel_id};
            debug("-> Cleared timer for channel $channel_id (answered correctly).");
        }

        # Check if the winning score has been reached
        if ($data->{scores}{$user_id} >= 10) {
            debug("-> Player $user_id reached 10 points. Stopping game.");
            my $final_message_payload = {
                content => "🎉 <\@$user_id> has reached 10 points and won the game! Congratulations!",
            };
            $self->discord->send_message($channel_id, $final_message_payload, sub {
                my $mock_msg = { channel_id => $channel_id };
                $self->stop_game($mock_msg); # Call stop_game to clean up and show final leaderboard
            });
        } else {
            # Send message with "Stop" button and start timer for next question
            my @buttons = (
                { type => 2, style => 4, label => "Stop Game", custom_id => "trivia_end_session" } # Red "Stop Game" button
            );
            my $next_question_payload = {
                content => "🎉 <\@$user_id> got it right! The correct answer was **$game->{correct_answer}**.\n\nNext question in 5 seconds!",
                components => [{ type => 1, components => \@buttons }]
            };
            $self->discord->send_message($channel_id, $next_question_payload);

            # Start a timer to get the next question
            Mojo::IOLoop->timer(5 => sub {
                my $mock_msg = { channel_id => $channel_id, content => '' };
                # Pass category for next question if available in game state
                $self->start_game($mock_msg, $data->{active_game}{$channel_id}{category_name});
            });
        }

    } else {
        # Wrong answer logic: Deduct a point, but not below zero
        my $user_id = $user->{id};
        if (defined $data->{scores}{$user_id} && $data->{scores}{$user_id} > 0) { # Only deduct if score is positive
            $data->{scores}{$user_id}--;
            $self->discord->send_message($channel_id, "❌ Sorry, <\@$user_id>, that's not correct! Your score is now: $data->{scores}{$user_id}.");
        } else {
            # Optional: Message if score is already 0 or undef
            $self->discord->send_message($channel_id, "❌ Sorry, <\@$user_id>, that's not correct! Your score remains 0.");
            $data->{scores}{$user_id} //= 0; # Ensure it's explicitly 0 if it was undef
        }
        $db->set('trivia', $data); # Save updated scores
    }
}

sub stop_game {
    my ($self, $msg) = @_;
    my $channel_id = $msg->{'channel_id'};
    debug("Attempting to stop game in channel $channel_id.");
    my $db = Component::DBI->new();
    my $data = get_trivia_data();

    # Clear any active question timer when the game is stopped
    if (defined $question_timers{$channel_id}) {
        Mojo::IOLoop->remove($question_timers{$channel_id});
        delete $question_timers{$channel_id};
        debug("-> Cleared timer for channel $channel_id (game stopped).");
    }

    # Check if there is an active game for this channel
    unless (ref $data->{active_game} eq 'HASH' && exists $data->{active_game}{$channel_id}) {
        debug("-> No active game found to stop.");
        return $self->discord->send_message($channel_id, "There's no trivia game to stop in this channel.");
    }

    my $game = $data->{active_game}{$channel_id}; # Get game data before deleting

    $self->discord->send_message($channel_id, "Trivia game stopped. The correct answer was **$game->{correct_answer}**.\n\nThanks for playing!");

    my $original_message_id = $game->{message_id};
    debug("-> Disabling buttons on original message ID $original_message_id.");
    $self->discord->get_message($channel_id, $original_message_id, sub {
        my $original_msg = shift;
        return unless ref $original_msg eq 'HASH';
        $original_msg->{components} = [];
        $self->discord->edit_message($channel_id, $original_message_id, $original_msg);
    });

    delete $data->{active_game}{$channel_id}; # Now delete the active game entry
    debug("-> Active game deleted. Saving state to DB.");
    $db->set('trivia', $data);

    # Also ensure the fetching flag is cleared if the game is manually stopped
    delete $is_fetching_question{$channel_id};

    # Display all scores at the end of the game
    $self->show_leaderboard($msg);
}

sub show_leaderboard {
    my ($self, $msg) = @_;
    my $channel_id = $msg->{'channel_id'};
    debug("Showing leaderboard for channel $channel_id.");
    my $data = get_trivia_data();

    my $scores = $data->{scores};
    unless (ref $scores eq 'HASH' && %$scores) {
        debug("-> No scores found.");
        return $self->discord->send_message($channel_id, "Nobody has any points yet. Start a game with `!trivia start`!");
    }

    my @sorted_user_ids = sort { $scores->{$b} <=> $scores->{$a} } keys %$scores;
    debug("-> Found " . scalar(@sorted_user_ids) . " users with scores.");

    my @leaderboard_lines;
    my $rank = 1;
    for my $user_id (@sorted_user_ids) {
        my $points = $scores->{$user_id};
        next unless defined $points;
        push @leaderboard_lines, "**$rank.** <\@$user_id> - $points points";
        $rank++;
    }

    my $embed = { embeds => [{
        title => "🏆 Trivia Leaderboard",
        color => 16776960,
        description => join("\n", @leaderboard_lines),
    }]};

    debug("-> Sending leaderboard embed.");
    $self->discord->send_message($channel_id, $embed);
}

# New sub to list available categories
sub list_categories {
    my ($self, $msg) = @_;
    my $channel_id = $msg->{'channel_id'};

    $self->discord->send_message($channel_id, "Fetching available trivia categories...");

    $self->_fetch_categories()->then(sub {
        unless (%categories_cache) {
            return $self->discord->send_message($channel_id, "Sorry, I couldn't fetch any trivia categories right now.");
        }

        # Sort categories by their original names for a cleaner list
        my @sorted_cleaned_names = sort { $categories_cache{$a}{original_name} cmp $categories_cache{$b}{original_name} } keys %categories_cache;

        my @formatted_categories;
        for my $cleaned_name (@sorted_cleaned_names) {
            push @formatted_categories, "- " . $categories_cache{$cleaned_name}{original_name};
        }

        my $embed = { embeds => [{
            title => "📚 Available Trivia Categories",
            color => 5793266,
            description => "You can use one of these categories with `!trivia start <category>`:\n\n" . join("\n", @formatted_categories),
        }]};

        $self->discord->send_message($channel_id, $embed);
    })->catch(sub {
        my $err = shift;
        $self->discord->send_message($channel_id, "Sorry, I couldn't list trivia categories right now: $err");
    });
}

1;