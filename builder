#!/bin/sh
VERSION=v2.0.0

rm -rf "Github Growler.app"

# bundle extra libraries into extlib
/usr/bin/perl -S cpanm -L extlib --no-man-pages --notest --installdeps .

# Build .app
platypus -a 'Github Growler' -o None -u "Tatsuhiko Miyagawa" -p /usr/bin/perl -s '????' -i appIcon.icns -I net.bulknews.GithubGrowler -N "APP_BUNDLER=Platypus-4.0" -f data/octocat.png -f extlib -c github-growler.pl -V $VERSION ./Github\ Growler.app
