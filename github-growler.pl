#!/usr/bin/perl
use strict;
use warnings;
use 5.008001;

use FindBin;
use lib "$FindBin::Bin/extlib/lib/perl5";

use Config::IniFiles;
use Encode;
use AnyEvent;
use Cocoa::Growl;
use Cocoa::EventLoop;
use AnyEvent::HTTP;
use File::Copy;
use File::Path;
use XML::LibXML;
use Storable;
use JSON;
use Net::SSLeay;
use HTML::TreeBuilder;

use version; our $VERSION = qv("v2.1.4");

my %events = (
    "New Commits" => qr/(?:pushed to|committed to)/,
    "New Repository" => qr/created repository/,
    "Opened Pull Request" => qr/opened pull request/,
    "Merged Pull Request" => qr/merged pull request/,
    "Closed Pull Request" => qr/closed pull request/,
    "New Tags" => qr/created tag/,
    "Comments on commits" => qr/commented on/,
    "Wiki Edits", qr/ edited .* wiki/,
    "New Commiter", qr/ added .* to /,
    "New File Uploads", qr/uploaded a file to/,
    "Forked Repository" => qr/forked (?!gist:)/,
    "New Branch" => qr/created branch/,
    "New Gist" => qr/created gist:/,
    "Updated Gist" => qr/updated gist:/,
    "Forked Gist" => qr/forked gist:/,
    "Watching Project" => qr/started watching/,
    "Following People" => qr/started following/,
    "New Issue" => qr/opened issue/,
    "Closed Issue" => qr/closed issue/,
);

my $AppDomain = "net.bulknews.GitHubGrowler";

my $AppName = "Github Growler";
my $TempDir = "$ENV{HOME}/Library/Caches/$AppDomain";
mkdir $TempDir, 0777 unless -e $TempDir;

my $AppIcon = "$TempDir/octocat.png";
copy "$FindBin::Bin/data/octocat.png", $AppIcon;

my @events  = ((keys %events), "Misc");
Cocoa::Growl::growl_register(
    app  => $AppName,
    icon => $AppIcon,
    notifications => [ @events, 'Fatal Error', 'Error' ],
    defaults => [ @events, 'Fatal Error' ],
);

my $Cache = sub {
    my($key, $code, $cb) = @_;
    $key = lc $key;
    $key =~ s/[^a-z0-9]+/_/g;
    my $path = "$TempDir/$key";

    if (-f $path) {
        my $age = time - (stat($path))[10];
        if ($age < 60*60*24) {
            my $value = Storable::retrieve($path);
            $cb->($value->{value});
            return;
        } else {
            unlink $path;
        }
    }

    $code->(sub {
        my $data = shift;
        Storable::nstore({ value => $data }, $path);
        $cb->($data);
    });
};

my %Seen;
my %Etags;

my %options = (interval => 300, maxGrowls => 10);
get_preferences(\%options, "interval", "maxGrowls");
my @args = @ARGV == 2 ? @ARGV : get_github_token();

my $t = AE::timer 0, $options{interval}, sub {
    growl_feed(@args, \%options);
};

AE::cv->recv;

sub get_preferences {
    my($opts, @keys) = @_;

    for my $key (@keys) {
        my $value = read_preference($key);
        $opts->{$key} = $value if defined $value;
    }
}

sub read_preference {
    my $key = shift;

    no warnings 'once';
    open OLDERR, ">&STDERR";
    open STDERR, ">/dev/null";
    my $value = `defaults read $AppDomain $key`;
    open STDERR, ">&OLDERR";

    return if $value eq '';
    chomp $value;
    return $value;
}

sub die_notice {
    my $msg = shift;
    Cocoa::Growl::growl_notify(
        name => "Fatal Error",
        title => $AppName,
        description => $msg,
        icon => $AppIcon,
        sticky => 1,
    );
    die $msg;
}

sub get_github_token {
    my($user, $token);

    eval {
        my $config = Config::IniFiles->new(-file => "$ENV{HOME}/.gitconfig");
        $user  = $config->val('github', 'user');
        $token = $config->val('github', 'token');
    };

    unless ($user && $token) {
        die_notice("GitHub config not found: See http://github.com/guides/local-github-config and set them");
    }

    return ($user, $token);
}

sub get_value {
    my($entry, $tag) = @_;
    my($node) = $entry->getElementsByTagName($tag);
    return $node ? $node->textContent : "";
}

sub growl_feed {
    my($user, $token, $options) = @_;

    my @feeds = (
        "https://github.com/$user.private.atom?token=$token",
        "https://github.com/$user.private.actor.atom?token=$token",
    );

    for my $uri (@feeds) {

        my $headers = {};
        $headers->{'If-None-Match'} = $Etags{$uri} if defined $Etags{$uri};

        http_get $uri, headers => $headers, persistent => 0, sub {
            return if $_[1]->{Status} == 304;
            my $doc = $_[1]->{Status} == 200
                ? eval { XML::LibXML->new->parse_string($_[0]) } : undef;

            $Etags{$uri} = $_[1]->{etag};

            unless ($doc) {
                Cocoa::Growl::growl_notify(
                    name => "Error",
                    title => $AppName,
                    description => "Can't parse the feed $uri",
                    icon => $AppIcon,
                );
                return;
            }

            my @to_growl;
            for my $entry ($doc->getElementsByTagName('entry')) {
                my $id = get_value($entry, 'id');
                next if $Seen{$id}++;
                next if @to_growl >= $options->{maxGrowls}; # not last, so that we can cache them in %Seen
                push @to_growl, $entry;
            }

            for my $entry (@to_growl) {
                my $author = get_value($entry, 'name');
                get_user($author, sub {
                    my $user = shift;
                    $user->{name} ||= $author;

                    my $body  = munge_update_body(get_value($entry, 'content'));
                    my $event = get_event_type(get_value($entry, 'title'));
                    my $title = $user->{name};
                    my $description = get_value($entry, 'title');
                    $description .= ": $body" if $body;
                    my $icon = $user->{avatar} ? "$user->{avatar}" : $AppIcon;

                    Cocoa::Growl::growl_notify(
                        name => $event,
                        title => encode_utf8($title),
                        description => encode_utf8($description),
                        icon => $icon,
                        on_click => sub {
                            my($node) = $entry->getElementsByTagName("link");
                            if ($node and my $link = $node->getAttribute("href")) {
                                system("open", $link);
                            }
                        },
                    );
                });
            }
        };
    }
}

sub munge_update_body {
    my $content = shift;

    my $tree = HTML::TreeBuilder->new;
    $tree->parse($content);
    $tree->eof;

    my $tag = $tree->look_down(_tag => "div", class => "message");
    if ($tag) {
        my $message = $tag->as_text;
        $message =~ s/^\s*[0-9a-f]{40}\s*//; # strip SHA1
        return $message;
    }

    return '';
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
    my($name, $cb) = @_;

    $Cache->("user:$name", sub {
        my $cb = shift;

        http_get "http://github.com/api/v2/json/user/show/$name", persistent => 0, sub {
            if ($_[1]->{Status} == 200) {
                my $content = JSON::decode_json($_[0]);
                $cb->({
                    name   => $content->{user}->{name},
                    avatar => "https://secure.gravatar.com/avatar/"
                      . $content->{user}->{gravatar_id}
                      . "?s=140&d=https://d3nwyuy0nl342s.cloudfront.net%2Fimages%2Fgravatars%2Fgravatar-140.png",
                });
            } else {
                $cb->({});
            }
        };
    }, $cb);
}

__END__

=head1 NAME

github-growler

=head1 AUTHOR

Tatsuhiko Miyagawa

=head1 LICENSE

This program is licensed under the same terms as Perl itself.

=cut
