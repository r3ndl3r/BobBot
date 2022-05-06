#!/usr/bin/env perl

use v5.10;
use strict;
use warnings;
use utf8;
use POSIX qw(strftime);
use Term::ANSIColor;

binmode STDOUT, ":utf8";

use FindBin 1.51 qw( $RealBin );
use lib "$RealBin/lib";

use Config::Tiny;
use Bot::Bobbot;
use Command::Help;
use Command::Avatar;
use Command::Info;
use Command::Uptime;
use Command::Card;
use Command::Say;
use Command::Hadi;
use Command::Alec;
use Command::Test;
use Command::ATs;
use Command::Alert;
use Command::Dump;
use Command::Bob;
use Command::Restart;
use Command::Eval;
use Command::Forecast;
use Command::Meme;
use Command::Fun;
use Command::Cursed;
use Command::Del;
use Command::Chuck;
use Command::Catch;

print "\n" . strftime("%a %b %d %H:%M:%S %Y", localtime) . color('green') . " STARTING MOFO\n" . color('reset');
# Fallback to "config.ini" if the user does not pass in a config file.
my $config_file = $ARGV[0] // 'config.ini';
my $config = Config::Tiny->read($config_file, 'utf8');
say localtime(time) . " Loaded Config: $config_file";

# Initialize the bot
my $bot = Bot::Bobbot->new('config' => $config);

# Register the commands
# The new() function in each command will register with the bot.
$bot->add_command( Command::Help->new           ('bot' => $bot) );
$bot->add_command( Command::Say->new            ('bot' => $bot) );
$bot->add_command( Command::Avatar->new         ('bot' => $bot) );
$bot->add_command( Command::Info->new           ('bot' => $bot) );
$bot->add_command( Command::Uptime->new         ('bot' => $bot) );
$bot->add_command( Command::Card->new           ('bot' => $bot) );
$bot->add_command( Command::Hadi->new           ('bot' => $bot) );
$bot->add_command( Command::Alec->new           ('bot' => $bot) );
$bot->add_command( Command::Test->new           ('bot' => $bot) );
$bot->add_command( Command::ATs->new            ('bot' => $bot) );
$bot->add_command( Command::Alert->new          ('bot' => $bot) );
$bot->add_command( Command::Dump->new           ('bot' => $bot) );
$bot->add_command( Command::Bob->new            ('bot' => $bot) );
$bot->add_command( Command::Restart->new        ('bot' => $bot) );
$bot->add_command( Command::Eval->new           ('bot' => $bot) );
$bot->add_command( Command::Forecast->new       ('bot' => $bot) );
$bot->add_command( Command::Meme->new           ('bot' => $bot) );
$bot->add_command( Command::Fun->new            ('bot' => $bot) );
$bot->add_command( Command::Cursed->new         ('bot' => $bot) );
$bot->add_command( Command::Del->new            ('bot' => $bot) );
$bot->add_command( Command::Chuck->new          ('bot' => $bot) );
$bot->add_command( Command::Catch->new          ('bot' => $bot) );

# Start the bot
$bot->start();
