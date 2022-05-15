package Command::Test;
use feature 'say';
use utf8;

use Moo;
use strictures 2;
use namespace::clean;

use Exporter qw(import);
our @EXPORT_OK = qw(cmd_test);

has bot                 => ( is => 'ro' );
has discord             => ( is => 'lazy', builder => sub { shift->bot->discord } );
has log                 => ( is => 'lazy', builder => sub { shift->bot->log } );
has name                => ( is => 'ro', default => 'Test' );
has access              => ( is => 'ro', default => 1 );
has description         => ( is => 'ro', default => '' );
has pattern             => ( is => 'ro', default => '^test ?' );
has function            => ( is => 'ro', default => sub { \&cmd_test } );
has usage               => ( is => 'ro', default => '' );


has on_message => ( is => 'ro', default =>
    sub {
        my $self = shift;
        $self->discord->gw->on('INTERACTION_CREATE' =>     
            sub {
                    my ($gw, $msg) = @_;

                    my $id     = $msg->{'id'};
                    my $token  = $msg->{'token'};
                    my $data   = $msg->{'data'};
                    my $custom = $data->{'custom_id'};
                    
                    if (my ($say) = $custom =~ /say\.(.+)/) {
                        $self->discord->delete_message($msg->{'channel_id'}, $msg->{'message'}{'id'});
                        $self->discord->interaction_response($id, $token, $data->{'custom_id'}, "OK", sub { $self->discord->send_message($msg->{'channel_id'}, $say) });
                    }
                }    
        )
    }
);


sub cmd_test
{
    my ($self, $msg) = @_;

    my $discord = $self->discord;
    my $pattern = $self->pattern;

    my $channel = $msg->{'channel_id'};
    my $msgid   = $msg->{'id'};
    my $author  = $msg->{'author'};
    my $args    = $msg->{'content'};
       $args    =~ s/$pattern//i;

    print "$args\n";
    # "<a:NODDERS:779986982804783155>"
    $discord->create_reaction($msg->{'channel_id'}, $msg->{'id'}, "🤖", sub{print Data::Dumper::Dumper(\@_);});

    return;
    #$discord->delete_message($channel, $msg->{'id'});
    my $time = localtime;

    $discord->send_message($channel, 
        {   
            content => 'Stuff for me to say:',
            'components' => [
                {
                    'type' => 1,
                    'components' => [
                        {
                            'style'     => 1,
                            'label'     => 'Poo',
                            'custom_id' => 'say.poo',
                            'disabled'  => 'false',
                            'type'      => 2
                        },
                                                {
                            'style'     => 1,
                            'label'     => 'Hello',
                            'custom_id' => 'say.hello',
                            'disabled'  => 'false',
                            'type'      => 2
                        },
                                                {
                            'style'     => 1,
                            'label'     => 'Shit!',
                            'custom_id' => 'say.shit',
                            'disabled'  => 'false',
                            'type'      => 2
                        },
                    ]
                }
            ],
            # 'embeds' => [ 
            #     {   
            #         author => {
            #             'name'     => 'CDawgVA',
            #             'url'      => 'https://www.twitch.tv/cdawgva',
            #             'icon_url' => 'https://static-cdn.jtvnw.net/jtv_user_pictures/49110706-4c6c-4da5-8037-0fbd429405f5-profile_image-300x300.png',
            #         },
            #         'title'       => 'Twitch Alert',
            #         'description' =>  'CDawgVA just went online.',
            #         'url'         => 'https://www.twitch.tv/cdawgva',

            #         fields => [
            #             {
            #                 'name'  => 'Title:',
            #                 'value'  => 'Gaming With The BoxBox',
            #             },
            #             {
            #                 'name'  => 'Online since:',
            #                 'value' => $time,
            #             },
            #             {
            #                 'name'  => 'Alerting:',
            #                 'value' => "<@497218154586701834>",
                            
            #             },

            #         ],
            #     } 
            # ]
        },
        #sub {
        #    print Data::Dumper::Dumper(\@_);
        #}
    );

    #print "$channel $msgid\n";
    $self->discord->send_ack($channel, $msgid);
}

1;
