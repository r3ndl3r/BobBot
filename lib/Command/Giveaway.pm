package Command::Giveaway;
use feature 'say';
use utf8;

use Moo;
use strictures 2;
use XML::Simple;
use LWP::UserAgent;

use Exporter qw(import);
our @EXPORT_OK = qw(cmd_giveaway);

has bot                 => ( is => 'ro' );
has discord             => ( is => 'lazy', builder => sub { shift->bot->discord } );
has log                 => ( is => 'lazy', builder => sub { shift->bot->log } );
has db                  => ( is => 'ro', required => 1 );
has name                => ( is => 'ro', default => 'giveaway' );
has access              => ( is => 'ro', default => 0 );
has description         => ( is => 'ro', default => 'Free game giveaways' );
has pattern             => ( is => 'ro', default => '^g(iveaway)? ?' );
has function            => ( is => 'ro', default => sub { \&cmd_giveaway } );
has usage               => ( is => 'ro', default => 'Usage: `!giveaway on | off | list | update`' );
has timer_seconds       => ( is => 'ro', default => 6000 );

has timer_sub => ( is => 'ro', default => sub {
    my $self = shift;
    Mojo::IOLoop->recurring($self->timer_seconds => sub { $self->giveaway });
});


sub cmd_giveaway {
    my ($self, $msg) = @_;

    my $discord = $self->discord;
    my $pattern = $self->pattern;

    my $args = lc $msg->{'content'};
    $args =~ s/$pattern//i;
    my ($command) = split /\s+/, $args;

    if (!$command) {
        $self->discord->send_message($msg->{channel_id}, $self->usage);
        return;
    }

    if ($command eq 'on') {
        if ($args =~ /(\d+)$/ && $self->{'access'}) {
            $self->giveaway_on($msg, $1);
        } else {
            $self->giveaway_on($msg, $msg->{'author'}{'id'});
        }

        $self->bot->react_robot($msg->{'channel_id'}, $msg->{'id'});
        return;
    }

    if ($command eq 'off') {
        if ($args =~ /(\d+)$/ && $self->{'access'}) {
            $self->giveaway_off($msg, $1);
        } else {
            $self->giveaway_off($msg, $msg->{'author'}{'id'});
        }
        $self->bot->react_robot($msg->{'channel_id'}, $msg->{'id'});
        return;
    }


    if ($command =~ /^l(ist)?$/) {
        $self->giveaway_list($msg);
        $self->bot->react_robot($msg->{'channel_id'}, $msg->{'id'});

        return;
    }

    if ($command =~ /^u(pdate)?$/) {
        giveaway(@_);
        $self->bot->react_robot($msg->{'channel_id'}, $msg->{'id'});

        return;
    }

    $discord->send_message($msg->{'channel_id'}, "Usage: `!giveaway on | off | list | update`");
}


sub giveaway_on {
    my ($self, $msg, $user_id) = @_;

    my $tags = $self->db->get('giveaway') || {};
    $tags->{$user_id} = 1;
    $self->db->set('giveaway', $tags);

    $self->discord->send_message($msg->{'channel_id'}, "🎉 Giveaway tag enabled.");
}

sub giveaway_off {
    my ($self, $msg, $user_id) = @_;

    my $tags = $self->db->get('giveaway') || {};
    delete $tags->{$user_id};
    $self->db->set('giveaway', $tags);

    $self->discord->send_message($msg->{'channel_id'}, "🎉 Giveaway tag disabled.");
}


sub giveaway_list {
    my ($self, $msg) = @_;

    my $tags = $self->db->get('giveaway') || {};

    my $reply = %$tags
        ? "🎯 Tagged users: " . join(', ', map { "<\@$_>" } keys %$tags)
        : "⚠️ No users have the giveaway tag enabled.";

    $self->discord->send_message($msg->{'channel_id'}, $reply);
}


sub giveaway {
    my $self    = shift;
    my $config  = $self->{'bot'}{'config'}{'giveaway'};
    my $channel = $config->{'channel'};

    my $ua = LWP::UserAgent->new();
    $ua->agent('Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/58.0.3029.110 Safari/537.3');

    my $res = $ua->get($config->{'url'});
    return unless $res->is_success;

    my $xs = XML::Simple->new(
        ForceArray => ['item', 'media:content'],
        KeyAttr => []
    );

    my $data = $xs->XMLin($res->content);
    my $tags = $self->db->get('giveaway') || {};

   for my $item (@ { $data->{channel}{item} }) {
        my $sth = $self->db->dbh->prepare("SELECT link FROM giveaway WHERE link = ?");
        $sth->execute($item->{'link'});

        # Skip if link already exists
        next if $sth->fetchrow_array();

        my $url = getURL($item->{'link'});
        my $embed = {
            'embeds' => [
                {
                    'author' => {
                        'url'      => 'https://www.gamerpower.com/',
                        'icon_url' => $item->{'media:content'}[0]{'url'},
                    },
                    'title'       => $item->{'title'},
                    'description' => $item->{'description'},
                    'url'         => $url,
                    'thumbnail'   => {
                        'url' => $item->{'media:content'}[0]{'url'},
                    },
                }
            ]
        };

        my $insert = $self->db->dbh->prepare("INSERT INTO giveaway (link) VALUES(?)");
        $insert->execute($item->{'link'});

        if ($tags) {
            # Send to all tagged users
            for my $user_id (keys %$tags) {
                $self->discord->send_dm($user_id, $embed);
            }

            my @tags = map { '<@' . $_ . '>' } keys %$tags;
            push @{ $embed->{'embeds'}[0]{'fields'} }, { 'name'  => 'Alerting:', 'value' => join ' ', @tags }; 
        }

        $self->discord->send_message($channel, $embed);
    }
}


sub getURL {
    my $url      = shift;
    my $original = $url;
       $url      =~ s#https://www.gamerpower.com/#https://www.gamerpower.com/open/#;
    
    my $ua  = LWP::UserAgent->new(agent => 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/58.0.3029.110 Safari/537.3');
    my $res = $ua->get($url);

    if ($res->is_success && $res->content =~ /<link rel="canonical" href="([^"]+)/) {
        return $1;
    } else {
        return $original;
    }
}


1;
