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
use URI::Escape;

has bot           => ( is => 'ro' );
has discord       => ( is => 'lazy', builder => sub { shift->bot->discord } );
has log           => ( is => 'lazy', builder => sub { shift->bot->bot->log } );
has name          => ( is => 'ro', default => 'Trivia' );
has access        => ( is => 'ro', default => 0 );
has description   => ( is => 'ro', default => 'Starts a trivia game.' );
has pattern       => ( is => 'ro', default => sub { qr/^triv(ia)?\b/i } );
has function      => ( is => 'ro', default => sub { \&cmd_trivia } );
has db            => ( is => 'ro', required => 1 );
has usage         => ( is => 'ro', default => <<~'EOF'
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
EOF
);

# This hash holds all temporary state for active games, keyed by channel ID.
my %active_channels;
# {
#   channel_id => {
#     is_fetching    => (0|1),
#     timer_id       => Mojo::IOLoop timer ID,
#     session_token  => OpenTDB session token,
#     answered_users => { user_id => 1, ... }
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

        if ($custom_id =~ /^trivia_answer_(.+)/s) {
            my $answer = $1;
            $self->handle_answer($interaction, $answer);
        }
        elsif ($custom_id eq 'trivia_end_session') {
            my $payload = { type => 6 }; # ACK the button press
            $self->discord->interaction_response($interaction->{id}, $interaction->{token}, $payload);
            my $mock_msg = { channel_id => $interaction->{channel_id} };
            $self->stop_game($mock_msg);
        }
    });
});


my $debug = 0;
sub debug { my $msg = shift; say "[Trivia DEBUG] $msg" if $debug }


# Helper to initialize data structures from DB
sub get_trivia_data {
    my $self = shift;
    my $data = $self->db->get('trivia') || {};
    $data->{scores} //= {};
    $data->{global_scores} //= {};
    $data->{active_game} //= {};
    return $data;
}

# Get (or reset) an OpenTDB session token
sub _get_session_token {
    my ($self, $channel_id) = @_;
    my $api_url = 'https://opentdb.com/api_token.php?command=request';
    debug("-> Requesting new session token.");
    return $self->discord->rest->ua->get_p($api_url)->then(sub {
        my $tx = shift;
        my $json = $tx->res->json;
        if ($json && $json->{response_code} == 0 && $json->{token}) {
            debug("-> Got token: $json->{token}");
            $active_channels{$channel_id}{session_token} = $json->{token};
            return Mojo::Promise->resolve($json->{token});
        }
        return Mojo::Promise->reject("Failed to get session token.");
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
                $cleaned_name =~ s/[^a-z0-9\s]//g;
                $categories_cache{$cleaned_name} = { id => $cat->{id}, original_name => $original_name };
            }
            $categories_last_fetched = time;
            debug("-> Successfully cached " . scalar(keys %categories_cache) . " categories.");
            return Mojo::Promise->resolve(1);
        });
    }
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
    }
    elsif ($subcommand eq 'stop') { $self->stop_game($msg) }
    elsif ($subcommand eq 'top') { $self->show_leaderboard($msg) }
    elsif ($subcommand eq 'globaltop') { $self->show_global_leaderboard($msg) }
    elsif ($subcommand =~ /cat(egories)?/) { $self->list_categories($msg) }
    else { $self->discord->send_message($msg->{'channel_id'}, $self->usage) }
}


sub start_game {
    my ($self, $msg, $opts) = @_;
    $opts //= {}; # Ensure opts is a hashref
    my $channel_id = $msg->{'channel_id'};
    my $data = $self->get_trivia_data();

    return if $active_channels{$channel_id}{is_fetching};
    $active_channels{$channel_id}{is_fetching} = 1;

    Mojo::IOLoop->remove($active_channels{$channel_id}{timer_id}) if $active_channels{$channel_id}{timer_id};
    delete $active_channels{$channel_id}{timer_id};
    
    # Clear list of users who answered the previous question
    delete $active_channels{$channel_id}{answered_users};

    my $is_initial_start_command = ($msg->{'content'} =~ /^triv(ia)?\s*(start\b.*|$)/i);
    
    if ($is_initial_start_command && exists $data->{active_game}{$channel_id}) {
        debug("-> User tried to start new game, but one is already in progress.");
        delete $active_channels{$channel_id}{is_fetching};
        return $self->discord->send_message($channel_id, "A trivia game is already in progress! Use `!trivia stop` to end it.");
    }

    # If this is a brand new game, fetch a session token.
    my $token_promise = Mojo::Promise->resolve();
    if ($is_initial_start_command) {
        $token_promise = $self->_get_session_token($channel_id);
    }

    $token_promise->then(sub {
        # Continue if token is fetched or wasn't needed
        return $self->_fetch_categories();
    })->then(sub {
        my $api_url = 'https://opentdb.com/api.php?amount=1&type=multiple';
        my $game_state = $data->{active_game}{$channel_id} || {};

        # Persist options or use previous game's options
        $game_state->{difficulty}    = $opts->{difficulty}    // $game_state->{difficulty};
        $game_state->{category_name} = $opts->{category_name} // $game_state->{category_name};
        $game_state->{win_score}     = $opts->{win_score}     // $game_state->{win_score} // 10; # Default 10

        # Append options to API URL
        $api_url .= "&difficulty=$game_state->{difficulty}" if $game_state->{difficulty};
        $api_url .= "&token=" . $active_channels{$channel_id}{session_token} if $active_channels{$channel_id}{session_token};

        # Fuzzy logic for category selection
        if (defined $game_state->{category_name} && $game_state->{category_name} ne '') {
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
                $game_state->{category_name} = $found_cat->{original_name};
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
            $self->discord->send_message($channel_id, "Starting a new trivia game! First to **$game_state->{win_score}** points wins. Good luck!");
        }

        $self->db->set('trivia', $data);
        $self->discord->send_message($channel_id, "Fetching a new trivia question...");
        debug("-> Calling trivia API: $api_url");
        return $self->discord->rest->ua->get_p($api_url);

    })->then(sub {
        my $tx = shift;
        delete $active_channels{$channel_id}{is_fetching};

        # If stop_game was called while fetching, the channel state will be gone. Abort.
        return unless exists $active_channels{$channel_id};

        return $self->discord->send_message($channel_id, "Sorry, API call failed: " . $tx->res->message) unless $tx->res->is_success;
        my $api_data = $tx->res->json;

        # Error handling for API response codes
        if ($api_data->{response_code} != 0) {
            my $error_message = "Sorry, I couldn't get a valid trivia question. ";
            if ($api_data->{response_code} == 1) { $error_message .= "There are no questions for your selected criteria." }
            elsif ($api_data->{response_code} == 2) { $error_message .= "The query was invalid (this is a bug!)." }
            elsif ($api_data->{response_code} == 3 || $api_data->{response_code} == 4) {
                $error_message .= "The session token is invalid or exhausted. Trying to get a new one for the next question...";
                $self->_get_session_token($channel_id); # Attempt to refresh token
            }
            return $self->discord->send_message($channel_id, $error_message);
        }

        my $question_data = $api_data->{results}[0];
        my $question = decode_entities($question_data->{question});
        my $correct_answer = decode_entities($question_data->{correct_answer});
        my @all_answers = shuffle($correct_answer, map { decode_entities($_) } @{$question_data->{incorrect_answers}});
        
        my @buttons;
        for my $answer (@all_answers) {
            my $label = (length $answer > 80) ? substr($answer, 0, 77) . '...' : $answer;
            push @buttons, { type => 2, style => 1, label => $label, custom_id => "trivia_answer_$answer" };
        }
        my $footer_text = "Category: " . decode_entities($question_data->{category});
        my $win_score = $data->{active_game}{$channel_id}{win_score};
        $footer_text .= " | Difficulty: " . ucfirst($question_data->{difficulty}) if $question_data->{difficulty};
        $footer_text .= " | First to $win_score wins!";

        my $payload = {
            embeds => [{ color => 3447003, title => "Trivia Time!", description => "**$question**", footer => { text => $footer_text } }],
            components => [{ type => 1, components => \@buttons }],
        };

        $self->discord->send_message($channel_id, $payload, sub {
            my $sent_msg = shift;
            return unless ref $sent_msg eq 'HASH' && $sent_msg->{id};
            my $game_data = $self->get_trivia_data();
            $game_data->{active_game}{$channel_id}{question}       = $question;
            $game_data->{active_game}{$channel_id}{correct_answer} = $correct_answer;
            $game_data->{active_game}{$channel_id}{message_id}     = $sent_msg->{id};
            $game_data->{active_game}{$channel_id}{answered}       = 0;
            $self->db->set('trivia', $game_data);

            # Set question timer using the consolidated state hash
            $active_channels{$channel_id}{timer_id} = Mojo::IOLoop->timer(15 => sub {
                my $current_data = $self->get_trivia_data();
                my $current_game = $current_data->{active_game}{$channel_id};
                if (defined $current_game && !$current_game->{answered}) {
                    $self->discord->send_message($channel_id, "Time's up! The correct answer was **$current_game->{correct_answer}**.");
                    $self->_disable_buttons($channel_id, $current_game->{message_id});
                    Mojo::IOLoop->timer(2 => sub { $self->start_game({ channel_id => $channel_id, content => '' }) });
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

    # Acknowledge the interaction immediately
    $self->discord->interaction_response($interaction->{id}, $interaction->{token}, { type => 6 });

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
    
    # Increment scores
    $data->{scores}{$channel_id}{$user_id} //= 0;
    $data->{scores}{$channel_id}{$user_id}++;

    $data->{global_scores}{$user_id} //= 0;
    $data->{global_scores}{$user_id}++;

    $game->{answered} = 1; # Mark question as answered
    $data->{active_game}{$channel_id} = $game;
    
    $self->db->set('trivia', $data);

    # Clean up the question
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
                $self->start_game({ channel_id => $channel_id, content => '' });
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
    
    $self->_disable_buttons($channel_id, $game->{message_id});
    
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
        $data->{scores}{$channel_id},
        "🏆 Trivia Leaderboard (This Session)",
        16776960,
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
        5814783,
        "There are no global scores yet!"
    );
}

# List categories
sub list_categories {
    my ($self, $msg) = @_;
    my $channel_id = $msg->{'channel_id'};
    $self->discord->send_message($channel_id, "Fetching available trivia categories...");
    $self->_fetch_categories()->then(sub {
        return $self->discord->send_message($channel_id, "Sorry, I couldn't fetch any trivia categories.") unless %categories_cache;
        my @sorted_names = sort { $categories_cache{$a}{original_name} cmp $categories_cache{$b}{original_name} } keys %categories_cache;
        my @formatted_categories = map { "- " . $categories_cache{$_}{original_name} } @sorted_names;
        my $embed = { embeds => [{ title => "📚 Available Trivia Categories", color => 5793266, description => "Use one with `!trivia start <category>`:\n\n" . join("\n", @formatted_categories) }]};
        $self->discord->send_message($channel_id, $embed);
    })->catch(sub {
        my $err = shift;
        $self->discord->send_message($channel_id, "Sorry, I couldn't list trivia categories: $err");
    });
}

1;