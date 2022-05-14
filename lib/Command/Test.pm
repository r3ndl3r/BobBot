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

sub cmd_test
{
    my ($self, $msg) = @_;

    my $discord = $self->discord;
    my $pattern = $self->pattern;

    my $channel = $msg->{'channel_id'};
    my $author  = $msg->{'author'};
    my $args    = $msg->{'content'};
       $args    =~ s/$pattern//i;

  
    my $time = localtime;

    $discord->send_message($channel, 
        {   
            'components' => [
                {
                    'type' => 1,
                    'components' => [
                        {
                            'style'     => 1,
                            'label'     => 'Test',
                            'custom_id' => 'delete.all',
                            'disabled'  => 'false',
                            'type'      => 2
                        },
                        {
                            'style'   => 5,
                            'label'   => 'CVE@CVE Details',
                            'url'     => 'https://www.google.com',
                            'disabled'=> 'false',
                            'type'    => 2
                        }
                    ]
                }
            ],
            'embeds' => [ 
                {   
                    author => {
                        'name'     => 'CDawgVA',
                        'url'      => 'https://www.twitch.tv/cdawgva',
                        'icon_url' => 'https://static-cdn.jtvnw.net/jtv_user_pictures/49110706-4c6c-4da5-8037-0fbd429405f5-profile_image-300x300.png',
                    },
                    'title'       => 'Twitch Alert',
                    'description' =>  'CDawgVA just went online.',
                    'url'         => 'https://www.twitch.tv/cdawgva',

                    fields => [
                        {
                            'name'  => 'Title:',
                            'value'  => 'Gaming With The BoxBox',
                        },
                        {
                            'name'  => 'Online since:',
                            'value' => $time,
                        },
                        {
                            'name'  => 'Alerting:',
                            'value' => "<@497218154586701834>",
                            
                        },

                    ],
                } 
            ]
        },
        #sub {
        #    print Data::Dumper::Dumper(\@_);
        #}
    );

}

1;
