package Command::Connect4;
use feature 'say';
use utf8;

use Moo;
use strictures 2;
use namespace::clean;

use Data::Dumper;

# Emojis for the game pieces and the empty board.
use constant {
    PLAYER_1_PIECE => '🔴',
    PLAYER_2_PIECE => '🔵',
    EMPTY_SLOT     => '⚪',
    BOARD_WIDTH    => 7,
    BOARD_HEIGHT   => 6,
};

# This hash will hold all active game states, keyed by channel ID.
my %active_games;
# %active_games = {
#   channel_id => {
#     board       => [ [ 7x6 array of pieces ] ],
#     players     => { player1_id => 'P1', player2_id => 'P2' },
#     player_map  => { P1 => player1_id, P2 => player2_id },
#     current_turn => 'P1', # or 'P2'
#     game_message => message_id,
#     winner      => undef,
#   }
# }

has bot         => ( is => 'ro' );
has discord     => ( is => 'lazy', builder => sub { shift->bot->discord } );
has log         => ( is => 'lazy', builder => sub { shift->bot->log } );
has name        => ( is => 'ro', default => 'Connect4' );
has access      => ( is => 'ro', default => 0 );
has description => ( is => 'ro', default => 'Play a game of Connect Four with another user.' );
has pattern     => ( is => 'ro', default => sub { '^c(onnect)?4 ?' } );
has function    => ( is => 'ro', default => sub { \&cmd_connect4_router } );
has usage       => ( is => 'ro', default => <<~'EOF'
    **Connect Four Command Help**

    Play a game of Connect Four against another user in this channel.

    `!c4 start <@opponent>`
    Challenges the mentioned user to a game of Connect Four. Players use the buttons to drop pieces.

    `!c4 stop`
    Ends the current game in this channel. Can be used by either player or by clicking the "Stop Game" button.
    EOF
);


has on_message => ( is => 'ro', default => sub {
    my $self = shift;
    $self->discord->gw->on('INTERACTION_CREATE' => sub {
        my ($gw, $interaction) = @_;
        # Ensure it's a button click interaction
        return unless (ref $interaction->{data} eq 'HASH' && $interaction->{data}{custom_id});

        my $custom_id  = $interaction->{data}{custom_id};
        my $channel_id = $interaction->{channel_id};
        my $user_id    = $interaction->{member}{user}{id};

        # Acknowledge the click immediately to prevent the "interaction failed" error
        $self->discord->interaction_response($interaction->{id}, $interaction->{token}, { type => 6 });

        # Route based on the custom_id of the button
        if ($custom_id =~ /^c4_drop_col_(\d)$/) {
            my $column = $1;
            # We pass a mock $msg hash to the handler function
            $self->handle_button_move({ author => { id => $user_id }, channel_id => $channel_id }, $column);
        } elsif ($custom_id eq 'c4_stop_game') {
            # Pass a mock $msg hash to the stop function
            $self->stop_game({ author => { id => $user_id }, channel_id => $channel_id });
        }
    });
});


sub cmd_connect4_router {
    my ($self, $msg) = @_;
    my $args_str = $msg->{'content'};
    $args_str =~ s/^(c4|connect4)\s*//i;

    my ($subcommand, @params) = split /\s+/, $args_str;
    $subcommand //= ''; # Avoids 'uninitialized variable' warning
    $self->debug("Routing subcommand: '$subcommand' with params: @params");

    if ($subcommand eq 'start') {
        $self->start_game($msg, \@params);
    } elsif ($subcommand eq 'stop') {
        $self->stop_game($msg);
    } else {
        $self->discord->send_message($msg->{'channel_id'}, $self->usage);
    }
}


sub start_game {
    my ($self, $msg, $params) = @_;
    my $channel_id = $msg->{'channel_id'};
    my $author_id = $msg->{'author'}{'id'};

    if (exists $active_games{$channel_id}) {
        $self->discord->send_message($channel_id, "A game is already in progress in this channel! Use `!c4 stop` to end it.");
        return;
    }

    my $opponent_id;
    if ($params->[0] && $params->[0] =~ /<@!?(\d+)>/) {
        $opponent_id = $1;
    } else {
        $self->discord->send_message($channel_id, "You must mention another user to challenge them! Usage: `!c4 start <\@opponent>`");
        return;
    }
    
    if ($author_id eq $opponent_id) {
        $self->discord->send_message($channel_id, "You can't challenge yourself to a game!");
        return;
    }

    $self->debug("Starting new game in channel $channel_id between $author_id and $opponent_id");

    $active_games{$channel_id} = {
        board        => [ map { [ (EMPTY_SLOT) x BOARD_WIDTH ] } 1..BOARD_HEIGHT ],
        players      => { $author_id => 'P1', $opponent_id => 'P2' },
        player_map   => { P1 => $author_id, P2 => $opponent_id },
        current_turn => 'P1',
        game_message => undef,
        winner       => undef,
    };

    my $payload = $self->build_game_payload($channel_id);

    $self->debug("Constructed initial payload: " . Dumper($payload));

    $self->discord->send_message($channel_id, $payload, sub {
        my $sent_msg = shift;

        $self->debug("Received response from send_message: " . Dumper($sent_msg));

        if (ref $sent_msg eq 'HASH' && $sent_msg->{id}) {
            $active_games{$channel_id}{game_message} = $sent_msg->{id};
            $self->debug("Stored game message ID: " . $sent_msg->{id});
        }
    });
}


sub handle_button_move {
    my ($self, $msg, $column) = @_;
    my $channel_id = $msg->{channel_id};
    my $player_id = $msg->{author}{id};

    my $game = $active_games{$channel_id};
    unless ($game) {
        # Game might have just ended, ignore the click.
        return;
    }

    # Check if it's the player's turn
    my $player_label = $game->{players}{$player_id};
    unless ($player_label && $player_label eq $game->{current_turn}) {
        # Silently ignore clicks from the wrong player
        return;
    }
    
    my $col_index = $column - 1; # Convert to 0-based index

    # Attempt to drop the piece
    my $piece = ($game->{current_turn} eq 'P1') ? PLAYER_1_PIECE : PLAYER_2_PIECE;
    my $move_made = 0;
    for (my $row = BOARD_HEIGHT - 1; $row >= 0; $row--) {
        if ($game->{board}[$row][$col_index] eq EMPTY_SLOT) {
            $game->{board}[$row][$col_index] = $piece;
            $move_made = 1;
            last;
        }
    }

    # This shouldn't happen if buttons are disabled correctly, but as a safeguard:
    unless ($move_made) {
        $self->log->warn("[Connect4.pm] User $player_id tried to drop in full column $column.");
        return;
    }

    # After a successful move, update the game
    $self->update_game_state($channel_id);
}


sub update_game_state {
    my ($self, $channel_id) = @_;
    my $game = $active_games{$channel_id};

    my $winner = $self->check_for_winner($channel_id);
    
    if ($winner) {
        my $payload = $self->build_game_payload($channel_id, $winner); # Pass winner to builder
        $self->discord->edit_message($channel_id, $game->{game_message}, $payload);
        delete $active_games{$channel_id}; # End the game
        return;
    }

    if (0 == grep { $_ eq EMPTY_SLOT } map { @$_ } @{$game->{board}}) {
        my $payload = $self->build_game_payload($channel_id, 'DRAW'); # Pass 'DRAW' status
        $self->discord->edit_message($channel_id, $game->{game_message}, $payload);
        delete $active_games{$channel_id}; # End the game
        return;
    }

    # Switch turns and update the message
    $game->{current_turn} = ($game->{current_turn} eq 'P1') ? 'P2' : 'P1';
    my $payload = $self->build_game_payload($channel_id);
    $self->discord->edit_message($channel_id, $game->{game_message}, $payload);
}


sub stop_game {
    my ($self, $msg) = @_;
    my $channel_id = $msg->{'channel_id'};
    my $player_id = $msg->{'author'}{'id'};

    my $game = $active_games{$channel_id};
    unless ($game) {
        return; # No game to stop, do nothing.
    }

    # Ensure the person stopping the game is one of the players
    if (exists $game->{players}{$player_id}) {
        # This check prevents the crash.
        # Only edit the message if we have successfully stored its ID.
        if (defined $game->{game_message}) {
            my $final_payload = $self->build_game_payload($channel_id);
            # Remove buttons from the final message
            $final_payload->{components} = [];
            $final_payload->{content} = "This game was stopped by <\@$player_id>.\n\n" . $self->render_board($channel_id);

            $self->discord->edit_message($channel_id, $game->{game_message}, $final_payload);
        } else {
            # If the ID doesn't exist yet, the game was stopped instantly.
            # Just send a simple confirmation message instead of trying to edit.
            $self->discord->send_message($channel_id, "The game of Connect Four has been stopped.");
        }
        
        # This line is crucial and must happen after the message is handled.
        delete $active_games{$channel_id};
    }
}


sub build_game_payload {
    my ($self, $channel_id, $game_status) = @_;
    $game_status //= 'ONGOING'; # Default to ongoing
    my $game = $active_games{$channel_id};

    my $board_string = $self->render_board($channel_id);
    my $content = "";

    # Determine the message content based on game status
    if ($game_status eq 'ONGOING') {
        my $next_player_id = $game->{player_map}{$game->{current_turn}};
        my $piece = ($game->{current_turn} eq 'P1') ? PLAYER_1_PIECE : PLAYER_2_PIECE;
        $content = "It's your turn, <\@$next_player_id> ($piece).\n\n$board_string\nUse the buttons below to make your move.";
    } elsif ($game_status eq 'DRAW') {
        $content = "🤝 **It's a Draw!** 🤝\n\n$board_string\n\nGood game!";
    } else { # A winner was found ('P1' or 'P2')
        my $winner_id = $game->{player_map}{$game_status};
        $content = "🎉 **Game Over!** 🎉\n\n$board_string\n\nCongratulations <\@$winner_id>, you win!";
    }

    my @components;
    # Disable all buttons if the game is over
    if ($game_status eq 'ONGOING') {
        my @row_of_buttons;
        
        for my $i (1..BOARD_WIDTH) {
            my $is_disabled = ($game->{board}[0][$i-1] ne EMPTY_SLOT) ? 1 : 0;
            
            push @row_of_buttons, {
                type => 2, style => 2, label => $i, custom_id => "c4_drop_col_$i", disabled => $is_disabled
            };

            # When the row is full (5 buttons) or we're at the last button...
            if (@row_of_buttons == 5 || $i == BOARD_WIDTH) {
                # Create a new anonymous array reference with the contents of @row_of_buttons
                push @components, { type => 1, components => [ @row_of_buttons ] };
                
                @row_of_buttons = (); # Reset for the next row
            }
        }
        # Add the "Stop Game" button in its own separate row.
        push @components, { type => 1, components => [{ type => 2, style => 4, label => "Stop Game", custom_id => "c4_stop_game" }] };
    }

    return { content => $content, components => \@components };
}


sub render_board {
    my ($self, $channel_id) = @_;
    my $board = $active_games{$channel_id}{board};
    my $board_string = "";
    $board_string .= ":one: :two: :three: :four: :five: :six: :seven:\n";
    for my $row (@$board) {
        $board_string .= join(" ", @$row) . "\n";
    }
    return $board_string;
}


sub check_for_winner {
    my ($self, $channel_id) = @_;
    my $board = $active_games{$channel_id}{board};
    my @directions = ( [0, 1], [1, 0], [1, 1], [1, -1] );
    for my $row (0 .. BOARD_HEIGHT - 1) {
        for my $col (0 .. BOARD_WIDTH - 1) {
            my $piece = $board->[$row][$col];
            next if $piece eq EMPTY_SLOT;
            for my $dir (@directions) {
                my ($dr, $dc) = @$dir;
                my $count = 0;
                for my $i (0..3) {
                    my $r = $row + $i * $dr;
                    my $c = $col + $i * $dc;
                    if ($r >= 0 && $r < BOARD_HEIGHT && $c >= 0 && $c < BOARD_WIDTH) {
                        if ($board->[$r][$c] eq $piece) { $count++; } else { last; }
                    } else { last; }
                }
                if ($count == 4) {
                    my $winner_id = $self->get_player_id_by_piece($channel_id, $piece);
                    return $active_games{$channel_id}{players}{$winner_id};
                }
            }
        }
    }
    return undef;
}


sub get_player_id_by_piece {
    my ($self, $channel_id, $piece_to_find) = @_;
    my $players = $active_games{$channel_id}{players};
    my $piece_map = { P1 => PLAYER_1_PIECE, P2 => PLAYER_2_PIECE, };
    for my $player_id (keys %$players) {
        my $player_label = $players->{$player_id};
        if ($piece_map->{$player_label} eq $piece_to_find) {
            return $player_id;
        }
    }
    return;
}


1;