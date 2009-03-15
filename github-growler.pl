#!/usr/bin/perl
use strict;
use warnings;
use 5.008001;
use App::Cache;
use Mac::Growl;
use File::Copy;
use Getopt::Long;
use LWP::Simple;
use URI;
use XML::Feed;

my %events = (
    "New Commits" => qr/(?:pushed to|committed to)/,
    "New Repository" => qr/created repository/,
    "Forked Repository" => qr/forked (?!gist:)/,
    "New Branch" => qr/created branch/,
    "New Gist" => qr/created gist:/,
    "Updated Gist" => qr/updated gist:/,
    "Forked Gist" => qr/forked gist:/,
    "Watching Project" => qr/started watching/,
    "Following People" => qr/started following/,
);

my $AppName = "Github Growler";
my @events  = ((keys %events), "Misc");
Mac::Growl::RegisterNotifications($AppName, [ @events, 'Error' ], \@events);

my $TempDir = "$ENV{HOME}/Library/Caches/com.github.Growler";
mkdir $TempDir, 0777 unless -e $TempDir;

my $AppIcon = "$TempDir/miyagawa.png";
copy "octocat.png", $AppIcon;

my $Cache = App::Cache->new({ ttl => 60*60*24, application => $AppName });
my %Seen;

my %options = (interval => 300, max => 10);
GetOptions(\%options, "interval=i", "max=i");
my @args = @ARGV == 2 ? @ARGV : get_github_token();

while (1) {
    growl_feed(@args);
    sleep $options{interval};
}

sub get_github_token {
    chomp(my $user  = `git config github.user`);
    chomp(my $token = `git config github.token`);

    unless ($user && $token) {
        die "Can't find .gitconfig entries for github.user and github.token\n";
    }

    return ($user, $token);
}

sub growl_feed {
    my($user, $token) = @_;

    for my $uri ("http://github.com/$user.private.atom?token=$token",
                 "http://github.com/$user.private.actor.atom?token=$token") {
        my $feed = eval { XML::Feed->parse(URI->new($uri)) };
        unless ($feed) {
            Mac::Growl::PostNotification($AppName, "Error", $AppName, "Can't parse the feed $uri", 0, 0, $AppIcon);
            next;
        }

        my @to_growl;
        for my $entry ($feed->entries) {
            next if $Seen{$entry->id}++;
            my $user = get_user($entry->author);
            push @to_growl, { entry => $entry, user => $user };
        }

        my $i;
        for my $stuff (@to_growl) {
            my($event, $title, $description, $icon, $last);
            if ($i++ >= $options{max}) {
                my %uniq;
                $event = "Misc";
                $title = (@to_growl - $options{max}) . " more updates";
                my @who = grep !$uniq{$_}++, map $_->{user}{name}, @to_growl[$i..$#to_growl];
                $description = "From ";
                if (@who > 1) {
                    $description .= join ", ", @who[0..$#who-1];
                    $description .= " and " . $who[-1];
                } else {
                    $description .= "$who[0]";
                }
                $icon = $AppIcon;
                $last = 1;
            } else {
                $event = get_event_type($stuff->{entry}->title);
                $title = $stuff->{user}{name};
                $description = $stuff->{entry}->title;
                $icon = "$stuff->{user}{avatar}";
            }
            Mac::Growl::PostNotification($AppName, $event, $title, $description, 0, 0, $icon);
            last if $last;
        }
    }
}

sub get_event_type {
    my $title = shift;

    for my $type (keys %events) {
        my $re = $events{$type};
        return $type if $title =~ $re;
    }

    return "Misc";
}

sub get_user {
    my $name = shift;
    $Cache->get_code("user:$name", sub {
        use Web::Scraper;
        my $res = scraper {
            process "#profile_name", name => 'TEXT';
            process ".identity img", avatar => [ '@src', sub {
                my $path = "$TempDir/$name.jpg";
                LWP::Simple::mirror($_, $path);
                return $path;
            } ];
        }->scrape(URI->new("http://github.com/$name"));
        $res->{name} ||= $name;
        $res;
    });
}

__END__

=head1 NAME

github-growler

=head1 AUTHOR

Tatsuhiko Miyagawa

=head1 LICENSE

This program is licensed under the same terms as Perl itself.

=cut
