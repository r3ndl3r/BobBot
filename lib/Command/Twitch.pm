package Command::Twitch;
use feature 'say';
use utf8;

use Moo;
use strictures 2;
use namespace::clean;

use Component::DBI;
use LWP::UserAgent;
use JSON;
use Data::Dumper;

use Exporter qw(import);
our @EXPORT_OK = qw(cmd_twitch);

has bot                 => ( is => 'ro' );
has discord             => ( is => 'lazy', builder => sub { shift->bot->discord } );
has log                 => ( is => 'lazy', builder => sub { shift->bot->log } );
has name                => ( is => 'ro',    default => 'Twitch' );
has access              => ( is => 'ro',    default => 0 );
has timer_seconds       => ( is => 'ro',    default => 60 );
has description         => ( is => 'ro',    default => 'Twitch notification system.' );
has pattern             => ( is => 'ro',    default => '^t(witch)? ?' );
has function            => ( is => 'ro',    default => sub { \&cmd_twitch } );
has usage               => ( is => 'ro',    default => 'https://bob.rendler.org/en/commands/twitch');
has timer_sub           => ( is => 'ro',    default => sub 
    { 
        my $self = shift;
        Mojo::IOLoop->recurring( $self->timer_seconds => sub {$self->twitch; }
        ) 
    }
);

my $start = 1;
my %online;
my $agent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/58.0.3029.110 Safari/537.3';

sub cmd_twitch { 
    my ($self, $msg) = @_;

    my $discord = $self->discord;
    my $pattern = $self->pattern;

    my $channel = $msg->{'channel_id'};
    my $author  = $msg->{'author'};
    my $args    = lc $msg->{'content'}; # Lowercase everything for arg parsing.
       $args    =~ s/$pattern//i;
    my @args    = split /\s+/, $args;
    my $replyto = '<@' . $author->{'id'} . '>';

    my $config  = $self->{'bot'}{'config'}{'twitch'};
    

    my ($arg, $streamer) = @args;
    my @cmd = ($discord, $channel, $msg, $streamer);

    if ($arg =~ /^a(dd)?$/ && $streamer)           { addT(@cmd);  return }
    if ($arg =~ /^d(el(ete)?)?$/ and $streamer)    { delT(@cmd);  return }
    if ($arg =~ /^l(ist)?$/)                       { listT(@cmd); return }
    if ($arg =~ /^t(ag)?$/ && $streamer)           { tagT(@cmd);  return }
    if ($args =~ /^refresh/) { twitch(@_) }
}


sub twitch {
    my $self = shift;
    my $discord = $self->discord;
    my $config  = $self->{'bot'}{'config'}{'twitch'};
    my $channel;

    my @streams = getStreams();
    
    for my $streamer (@streams) {
        my $topic = getStream($streamer);
        
        # Streamer is online;
        if ($topic) {



            my $message = getMessage($streamer);

            # Update title if needed.
            my $gt = getTopic($streamer);
            if (defined $gt && $topic ne $gt) {
                setTopic($streamer, $topic);
                        
                $discord->get_message($config->{'channel'}, $message,
                    sub {
                            my $oldmsg = shift;
                            if ($topic ne $oldmsg->{'embeds'}[0]{'fields'}[0]{'value'}) {
                                $oldmsg->{'embeds'}[0]{'fields'}[0]{'value'} = $topic;
                                $discord->edit_message($config->{'channel'}, $message, $oldmsg);
                            }
                    }
                );
            }

            # If last online record exists and it's less than 10 mins ago then probably stream crashed.
            my $msg;
            my $laston = getLaston($streamer);

            if (defined $laston && $laston > 0 && (time() - $laston) < 600) {
                $msg = "**$streamer** is back online (from probable stream crash).";
            } else {
                $msg = "**$streamer** is online.";

            }    

            # Check if they already have a message on discord. 
            setLaston($streamer);
            # If yes update Last update: field
            if ($message) {
                $discord->get_message($config->{'channel'}, $message,
                    sub {
                        my $oldmsg = shift;
                        $oldmsg->{'embeds'}[0]{'fields'}[2]{'value'} = localtime;
                        $discord->edit_message($config->{'channel'}, $message, $oldmsg);
                    }
                );
                
                next;
            }

                        
            my $time = localtime;
            my $embed = {   
                            'embeds' => [ 
                                {   
                                    'author' => {
                                        'name'     => $streamer,
                                        'url'      => "https://www.twitch.tv/$streamer",
                                        'icon_url' => 'https://pbs.twimg.com/profile_images/1450901581876973568/0bHBmqXe_400x400.png',
                                    },
                                    'thumbnail' => {
                                        'url'   => getProfile($streamer),
                                    },
                                    'title'       => 'Twitch Alert',
                                    'description' => "$msg\n",
                                    'color'       => 48491,
                                    'url'         => "https://www.twitch.tv/$streamer",

                                    'fields' => [
                                        {
                                            'name'  => 'Title:',
                                            'value' => $topic,
                                        },
                                        {
                                            'name'  => 'Online since:',
                                            'value' => $time,
                                        },
                                                                                {
                                            'name'  => 'Last update:',
                                            'value' => $time,
                                        },
                                    ],
                                } 
                            ]
                        };

            
            my $tag = getTag($streamer);
            my @tags;
            if ($tag) {
                @tags = split ',', $tag;
                @tags = map { '<@' . $_ . '>' } @tags;
                push @{ $embed->{'embeds'}[0]{'fields'} }, { 'name'  => 'Alerting:', 'value' => join ' ', @tags };

                for (@tags) {
                    s/\D//g;
                    $discord->send_dm($_, $embed);
                }
            }        

            $discord->send_message($config->{'channel'}, $embed,
                sub {
                    my $id = shift->{'id'};
                    my $db = Component::DBI->new();

                    $db->dbh->do("UPDATE twitch SET message = ? WHERE streamer = ?", undef, $id, $streamer);
                }
            );

            setLaston($streamer);
            setTopic($streamer, $topic);
                    
        } else {
            # Stream offline. Delete message.

            my $laston = getLaston($streamer);

            # Make sure they have been offline for at least 5 mins before deleting message.
            if (defined $laston && $laston > 0 && (time() - $laston) > 300) {
                my $message = getMessage($streamer);
                if ($message) {
                    $discord->delete_message($config->{'channel'}, $message);
                    setMessage($streamer, 0);
                }
            } 


        }
    }
    
    cleanup_dead_messages($self);
}

sub addT {
    my ($discord, $channel, $msg, $streamer) = @_;

    unless ($streamer =~ /^\w+$/i) {
        $discord->send_message($channel, "$streamer is not valid channel.");
        return;            
    }

    # Check to see if stream already exists.
    my @streams = getStreams();

    for my $s (@streams) {
        if ($streamer eq $s) {
            $discord->send_message($channel, "$streamer is already in Twitch alerts list.");
            return;
        }
    }

    # Make sure the streamer is valid.
    unless ( validChannel($streamer) ) {
        $discord->send_message($channel, "$streamer is not valid channel.");
        return;
    }

    addStreamer($streamer);

    # Confirm is has been added successfully.
    @streams = getStreams();
    for my $s (@streams) {
        if ($streamer eq $s) {
        $discord->send_message($channel, "Added $streamer to Twitch alerts list.");
        $discord->create_reaction($msg->{'channel_id'}, $msg->{'id'}, "🤖");
        
        return;
        }
    }

    $discord->send_message($channel, "Couldn't add $streamer.");
}


sub delT {
    my ($discord, $channel, $msg, $streamer) = @_;
        
    unless ($streamer =~ /^\w+$/i) {
        $discord->send_message($channel, "$streamer is not valid channel.");
        return;            
    }

    my @streams = getStreams();

    for my $s (@streams) {
        if ($streamer eq $s) {
            delStreamer($streamer);
            $discord->send_message($channel, "Deleted $streamer from Twitch alerts list.");

            return;
        }
    }

    $discord->send_message($channel, "$streamer is not in Twitch alerts list."); 
}


sub listT {
    my ($discord, $channel, $msg, $streamer) = @_;
    my @streams  = getStreams();

    if (!@streams) {
        $discord->send_message($channel, "No streams in Twitch alerts list.");
        return;
    }

    # Join all the streamers we have tagging enabled for.
    $discord->send_message($channel, "Twitch alerts enabled for: " . join ', ', sort @streams);
    $discord->create_reaction($msg->{'channel_id'}, $msg->{'id'}, "🤖");
}


sub tagT {
    my ($discord, $channel, $msg, $streamer) = @_;       
    my $userid = $msg->{'author'}->{'id'}; 
    my @streams = getStreams();
    my %streamers = map { $_ => 1 } @streams;

    if (exists $streamers{$streamer}) {
        my $tag = getTag($streamer);
        my @tags;
        if ($tag) {
            @tags = split ',', $tag;
        }
        my %tags = map { $_ => 1 } @tags;

        if (exists $tags{$userid}) {
            delete $tags{$userid};
            setTag($streamer, join ',', map { $_ } keys %tags);
            $discord->send_message($channel, "<\@$userid> Twitch tagging removed for '**$streamer**'.");
        } else {
            push @tags, $userid;
            setTag($streamer, join ',', @tags);
    
            $discord->send_message($channel, "<\@$userid> Twitch tagging added for '**$streamer**'.");

        }

        return;
    } else {
        $discord->send_message($channel, "<\@$userid> '**$streamer**' is not a vlid streamer.");
    }


    if ($streamer =~ /^l(ist)?$/) {
        $discord->send_message($channel, "$userid you have tagging enabled for: $streamer");
        $discord->send_message($channel, "$userid you don't have tagging enabled for anybody.");
    }
}


sub validChannel {
    my $streamer = shift;
    my $res = getTwitch($streamer);

    if ($res->is_success && $res->decoded_content =~ /meta property="og:type" content="video.other"/) {
        return 1;
    } else {

        return 0;
    }
}


sub getStream {
    my $streamer = shift;
    my $res = getTwitch($streamer);

    if ($res->is_success) {
        my $content = $res->decoded_content;
        if ($content =~ /"isLiveBroadcast":true/) {
            $content =~ /"description":"([^"]+)/;
            return $1;
        }
        return 0;
    } else {
        return 0;
    }
}


sub getProfile {
    my $streamer = shift;
    my $res = getTwitch($streamer);

    if ($res->is_success && $res->decoded_content =~ q!(https://\S+-profile_image-300x300.png)!) {
        return $1;
    }

    return 0
}


sub getTwitch {
    my $streamer = shift;
    my $url = "https://www.twitch.tv/$streamer";

    my $ua  = LWP::UserAgent->new(agent => $agent);
    my $res = $ua->get($url);

    return $res;
}


sub addStreamer {
    my $streamer = shift;
    my $db = Component::DBI->new();
    $db->dbh->do("INSERT INTO twitch (streamer) VALUES (?)", undef, $streamer);
}


sub delStreamer {
    my $streamer = shift;
    my $db = Component::DBI->new();
    $db->dbh->do("DELETE FROM twitch WHERE streamer = ?", undef, $streamer);
}


sub getStreams {
    my $db = Component::DBI->new();
    my $streamers = $db->dbh->selectcol_arrayref("SELECT streamer FROM twitch");

    return @{ $streamers };
}


sub getMessage {
    my $streamer = shift;
    my $db = Component::DBI->new();
    return $db->dbh->selectrow_array("SELECT message FROM twitch WHERE streamer = ?", undef, $streamer);
}


sub setMessage {
    my ($streamer, $message) = shift;
    my $db = Component::DBI->new();
    $db->dbh->do("UPDATE twitch SET message = ? WHERE streamer = ?", undef, $message, $streamer);
}


sub getLaston {
    my $streamer = shift;
    my $db = Component::DBI->new();
    return $db->dbh->selectrow_array("SELECT laston FROM twitch WHERE streamer = ?", undef, $streamer);
}


sub setLaston {
    my $streamer = shift;
    my $db = Component::DBI->new();
    my $time = time;
    $db->dbh->do("UPDATE twitch SET laston = ? WHERE streamer = ?", undef, $time, $streamer);
}


sub getTopic {
    my ($streamer) = @_;
    my $db = Component::DBI->new();
    return $db->dbh->selectrow_array("SELECT topic FROM twitch WHERE streamer = ?", undef, $streamer);
}


sub setTopic {
    my ($streamer, $topic) = @_;
    my $db = Component::DBI->new();
    $db->dbh->do("UPDATE twitch SET topic = ? WHERE streamer = ?", undef, $topic, $streamer);
}


sub getTag {
    my ($streamer) = @_;
    my $db = Component::DBI->new();
    return $db->dbh->selectrow_array("SELECT tag FROM twitch WHERE streamer = ?", undef, $streamer);
}


sub setTag {
    my ($streamer, $tag) = @_;
        print Dumper($tag);
    my $db = Component::DBI->new();
    $db->dbh->do("UPDATE twitch SET tag = ? WHERE streamer = ?", undef, $tag, $streamer);
    print Dumper($tag);
    #setT((@_, 'tag'));
}


sub setT {
    my $db = Component::DBI->new();
    my @sql = reverse @_;
    print Dumper(@sql);
    $db->dbh->do("UPDATE twitch SET ? = ? WHERE streamer = ?", undef, @sql);   
}

sub getT {
    my $db = Component::DBI->new();
    return $db->dbh->selectrow_array("SELECT tag FROM twitch WHERE streamer = ?", undef, shift);
}

sub cleanup_dead_messages {
    my $self = shift;
    my $discord = $self->discord;
    my $config  = $self->{'bot'}{'config'}{'twitch'};
    my $channel = $config->{'channel'};
    my $timeout = 300; # Timeout in seconds (5 minutes)

    my @streams = getStreams();

    for my $streamer (@streams) {
        my $laston = getLaston($streamer);

        if (defined $laston && $laston > 0 && (time() - $laston) > $timeout) {
            # Streamer has been offline for longer than the timeout period, delete message
            my $message_id = getMessage($streamer);
            if ($message_id) {
                $discord->delete_message($channel, $message_id);
                setMessage($streamer, 0); # Update database to indicate message has been deleted
            }
        }
    }
}

1;
